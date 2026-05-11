-- ============================================================================
-- V 1 23: User Preferences & Notification Engine
-- ============================================================================
-- Purpose
--   - Per-user preferences table (theme, currency, timezone, notification_prefs)
--   - RPCs: get_my_preferences, update_my_preferences, update_my_workspace_name,
--     get_workspace_members
--   - Notification engine: DB triggers for maintenance requests, ticket status
--     changes, and payment records that fan-out into app.user_notifications
--     while respecting per-user notification_prefs opt-outs.
-- ============================================================================

-- ─── 1. user_preferences ─────────────────────────────────────────────────────

create table if not exists app.user_preferences (
  user_id       uuid        primary key references auth.users(id) on delete cascade,
  theme         text        not null default 'system'
                            check (theme in ('light', 'dark', 'system')),
  currency      text        not null default 'KES',
  timezone      text        not null default 'Africa/Nairobi',
  locale        text        not null default 'en-KE',
  -- JSONB keyed by notification type; each value: { email, whatsapp, inApp } booleans
  notification_prefs jsonb  not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint chk_user_preferences_currency_len
    check (char_length(trim(currency)) between 2 and 10),
  constraint chk_user_preferences_timezone_len
    check (char_length(trim(timezone)) between 2 and 60)
);

drop trigger if exists trg_user_preferences_updated_at on app.user_preferences;
create trigger trg_user_preferences_updated_at
  before update on app.user_preferences
  for each row execute function app.set_updated_at();

-- RLS
alter table app.user_preferences enable row level security;

drop policy if exists "users_own_preferences" on app.user_preferences;
create policy "users_own_preferences"
  on app.user_preferences
  for all
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Auto-provision a row when a profile is created
create or replace function app.auto_provision_user_preferences()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  insert into app.user_preferences (user_id)
  values (new.id)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_auto_provision_preferences on app.profiles;
create trigger trg_auto_provision_preferences
  after insert on app.profiles
  for each row execute function app.auto_provision_user_preferences();

-- ─── 2. get_my_preferences RPC ───────────────────────────────────────────────

create or replace function app.get_my_preferences()
returns setof app.user_preferences
language plpgsql
security definer
set search_path = app, public
as $$
begin
  -- Ensure a row exists (lazy provision for existing users)
  insert into app.user_preferences (user_id)
  values (auth.uid())
  on conflict do nothing;

  return query
    select * from app.user_preferences where user_id = auth.uid();
end;
$$;

revoke all   on function app.get_my_preferences() from public, anon;
grant execute on function app.get_my_preferences() to authenticated;

-- ─── 3. update_my_preferences RPC ───────────────────────────────────────────

create or replace function app.update_my_preferences(
  p_theme              text    default null,
  p_currency           text    default null,
  p_timezone           text    default null,
  p_locale             text    default null,
  p_notification_prefs jsonb   default null
)
returns app.user_preferences
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_result app.user_preferences;
begin
  insert into app.user_preferences (user_id, theme, currency, timezone, locale, notification_prefs)
  values (
    auth.uid(),
    coalesce(p_theme,    'system'),
    coalesce(p_currency, 'KES'),
    coalesce(p_timezone, 'Africa/Nairobi'),
    coalesce(p_locale,   'en-KE'),
    coalesce(p_notification_prefs, '{}'::jsonb)
  )
  on conflict (user_id) do update
    set
      theme              = coalesce(p_theme,    user_preferences.theme),
      currency           = coalesce(p_currency, user_preferences.currency),
      timezone           = coalesce(p_timezone, user_preferences.timezone),
      locale             = coalesce(p_locale,   user_preferences.locale),
      -- Merge patch: supplied keys overwrite; omitted keys are kept
      notification_prefs = case
        when p_notification_prefs is not null
          then user_preferences.notification_prefs || p_notification_prefs
        else user_preferences.notification_prefs
      end,
      updated_at         = now()
  returning * into v_result;

  return v_result;
end;
$$;

revoke all    on function app.update_my_preferences(text,text,text,text,jsonb) from public, anon;
grant execute on function app.update_my_preferences(text,text,text,text,jsonb) to authenticated;

-- ─── 4. update_my_workspace_name RPC ─────────────────────────────────────────

create or replace function app.update_my_workspace_name(p_name text)
returns app.workspaces
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_result app.workspaces;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update app.workspaces
     set name = p_name
   where owner_user_id = auth.uid()
  returning * into v_result;

  if not found then
    raise exception 'Workspace not found or permission denied';
  end if;

  return v_result;
end;
$$;

revoke all    on function app.update_my_workspace_name(text) from public, anon;
grant execute on function app.update_my_workspace_name(text) to authenticated;

-- ─── 5. get_workspace_members RPC ────────────────────────────────────────────

create or replace function app.get_workspace_members()
returns table (
  member_id    uuid,
  user_id      uuid,
  email        text,
  first_name   text,
  last_name    text,
  phone        text,
  role_type    text,   -- 'admin' | 'fundi' | 'caretaker' | 'pac'
  role_label   text,
  status       text,
  joined_at    timestamptz,
  extra        jsonb    -- role-specific metadata (rating, specialty, etc.)
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_workspace_id
  from app.workspaces
  where owner_user_id = auth.uid()
  limit 1;

  if v_workspace_id is null then
    return;
  end if;

  -- ── Workspace admins & members ──────────────────────────────────────────────
  return query
    select
      wm.id                                              as member_id,
      wm.user_id                                         as user_id,
      coalesce(p.email, '')                              as email,
      coalesce(p.first_name, '')                         as first_name,
      coalesce(p.last_name, '')                          as last_name,
      null::text                                         as phone,
      case wm.role
        when 'workspace_admin'  then 'admin'
        else                         'admin'
      end                                                as role_type,
      case wm.role
        when 'workspace_admin'  then 'Admin'
        else                         'Member'
      end                                                as role_label,
      wm.status::text                                    as status,
      wm.created_at                                      as joined_at,
      '{}'::jsonb                                        as extra
    from app.workspace_memberships wm
    left join app.profiles p on p.id = wm.user_id
    where wm.workspace_id = v_workspace_id
      and wm.status = 'active'

  union all

  -- ── Fundi (contractor) profiles ─────────────────────────────────────────────
  select
    fp.id                                                as member_id,
    null::uuid                                           as user_id,
    coalesce(fp.phone, '')                               as email,
    fp.name                                              as first_name,
    ''                                                   as last_name,
    fp.phone                                             as phone,
    'fundi'::text                                        as role_type,
    'Fundi'::text                                        as role_label,
    case when fp.available then 'active' else 'inactive' end as status,
    fp.created_at                                        as joined_at,
    jsonb_build_object(
      'specialty',       coalesce(fp.specialty, ''),
      'rating',          fp.rating,
      'completed_jobs',  fp.completed_jobs,
      'available',       fp.available
    )                                                    as extra
  from app.fundi_profiles fp
  where fp.workspace_id = v_workspace_id

  union all

  -- ── Property-level collaborators (Caretaker, PAC, etc.) ─────────────────────
  select distinct on (pm.user_id, r.key)
    pm.id                                                as member_id,
    pm.user_id                                           as user_id,
    coalesce(p.email, '')                                as email,
    coalesce(p.first_name, '')                           as first_name,
    coalesce(p.last_name, '')                            as last_name,
    null::text                                           as phone,
    lower(r.key)                                         as role_type,
    r.name                                               as role_label,
    pm.status::text                                      as status,
    pm.starts_at                                         as joined_at,
    '{}'::jsonb                                          as extra
  from app.property_memberships pm
  join app.properties prop  on prop.id = pm.property_id
  join app.roles r           on r.id   = pm.role_id
  left join app.profiles p   on p.id   = pm.user_id
  where prop.workspace_id = v_workspace_id
    and pm.status = 'active'
    and pm.deleted_at is null
    and r.key in ('CARETAKER', 'PAC', 'PROPERTY_MANAGER')

  order by joined_at asc;
end;
$$;

revoke all    on function app.get_workspace_members() from public, anon;
grant execute on function app.get_workspace_members() to authenticated;

-- ─── 6. Notification engine helpers ──────────────────────────────────────────

-- Check if a given notification type + channel is enabled for a user.
-- Defaults to TRUE (opt-in by default; users can opt out).
create or replace function app.is_notification_enabled(
  p_user_id uuid,
  p_type    text,
  p_channel text default 'inApp'
)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select coalesce(
    (notification_prefs -> p_type ->> p_channel)::boolean,
    true
  )
  from app.user_preferences
  where user_id = p_user_id;
$$;

-- Convenience: get workspace owner UUID from a workspace_id
create or replace function app.workspace_owner(p_workspace_id uuid)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select owner_user_id from app.workspaces where id = p_workspace_id limit 1;
$$;

-- ─── 7. Notification trigger: maintenance request submitted ───────────────────

create or replace function app.notify_maintenance_request_submitted()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_owner_id uuid;
  v_category_label text;
begin
  v_owner_id := app.workspace_owner(new.workspace_id);
  if v_owner_id is null then return new; end if;

  -- Respect opt-out
  if not app.is_notification_enabled(v_owner_id, 'maintenance_new', 'inApp') then
    return new;
  end if;

  select label into v_category_label
  from app.maintenance_categories
  where id = new.category_id;

  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  ) values (
    v_owner_id,
    new.property_id,
    'maintenance_new',
    'New Maintenance Request',
    coalesce(v_category_label, 'Maintenance') || ' — ' || new.title,
    jsonb_build_object(
      'action_href',    '/owner/maintenance',
      'request_id',     new.id,
      'reference',      new.reference,
      'urgency',        new.urgency,
      'category',       coalesce(v_category_label, '')
    )
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_maintenance_request_submitted on app.maintenance_requests;
create trigger trg_notify_maintenance_request_submitted
  after insert on app.maintenance_requests
  for each row execute function app.notify_maintenance_request_submitted();

-- ─── 8. Notification trigger: maintenance ticket status changed ───────────────

create or replace function app.notify_maintenance_ticket_status_changed()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_owner_id     uuid;
  v_notif_type   text;
  v_title        text;
  v_message      text;
begin
  -- Only fire on meaningful status transitions
  if old.status = new.status then return new; end if;

  v_owner_id := app.workspace_owner(new.workspace_id);
  if v_owner_id is null then return new; end if;

  case new.status
    when 'completed' then
      v_notif_type := 'maintenance_completed';
      v_title      := 'Maintenance Job Completed';
      v_message    := 'Ticket ' || new.reference || ' has been marked as completed.';
    when 'assigned' then
      v_notif_type := 'maintenance_updated';
      v_title      := 'Maintenance Ticket Assigned';
      v_message    := 'Ticket ' || new.reference || ' has been assigned to a fundi.';
    when 'in_progress' then
      v_notif_type := 'maintenance_updated';
      v_title      := 'Maintenance In Progress';
      v_message    := 'Work has started on ticket ' || new.reference || '.';
    when 'paused' then
      v_notif_type := 'maintenance_updated';
      v_title      := 'Maintenance Paused';
      v_message    := 'Ticket ' || new.reference || ' has been paused.';
    when 'reassigning' then
      v_notif_type := 'maintenance_updated';
      v_title      := 'Maintenance Being Reassigned';
      v_message    := 'Ticket ' || new.reference || ' is being reassigned.';
    else
      return new; -- ignore other transitions
  end case;

  if not app.is_notification_enabled(v_owner_id, v_notif_type, 'inApp') then
    return new;
  end if;

  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  ) values (
    v_owner_id,
    new.property_id,
    v_notif_type,
    v_title,
    v_message,
    jsonb_build_object(
      'action_href',  '/owner/maintenance',
      'ticket_id',    new.id,
      'reference',    new.reference,
      'old_status',   old.status,
      'new_status',   new.status
    )
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_maintenance_ticket_status on app.maintenance_tickets;
create trigger trg_notify_maintenance_ticket_status
  after update on app.maintenance_tickets
  for each row execute function app.notify_maintenance_ticket_status_changed();

-- ─── 9. Notification trigger: payment record created ─────────────────────────

create or replace function app.notify_payment_received()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_owner_id uuid;
begin
  v_owner_id := app.workspace_owner(new.workspace_id);
  if v_owner_id is null then return new; end if;

  if not app.is_notification_enabled(v_owner_id, 'payment_received', 'inApp') then
    return new;
  end if;

  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  ) values (
    v_owner_id,
    new.property_id,
    'payment_received',
    'Rent Payment Received',
    'A payment of ' || new.currency_code || ' ' ||
      to_char(new.amount, 'FM999,999,999') ||
      coalesce(' from ' || new.payer_name, '') || ' has been recorded.',
    jsonb_build_object(
      'action_href',   '/owner/rent-payments',
      'payment_id',    new.id,
      'amount',        new.amount,
      'currency_code', new.currency_code,
      'payer_name',    coalesce(new.payer_name, ''),
      'payer_phone',   coalesce(new.payer_phone, '')
    )
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_payment_received on app.payment_records;
create trigger trg_notify_payment_received
  after insert on app.payment_records
  for each row execute function app.notify_payment_received();

-- ─── 10. Notification trigger: lease signed ───────────────────────────────────
-- Fires when a lease_agreement moves to 'active' status (tenant acceptance).

create or replace function app.notify_lease_signed()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_owner_id   uuid;
  v_workspace_id uuid;
begin
  -- Only fire when status transitions TO 'active'
  if old.status = 'active' or new.status <> 'active' then return new; end if;

  -- Resolve workspace from property
  select w.owner_user_id, prop.workspace_id
  into v_owner_id, v_workspace_id
  from app.properties prop
  join app.workspaces w on w.id = prop.workspace_id
  where prop.id = new.property_id
  limit 1;

  if v_owner_id is null then return new; end if;

  if not app.is_notification_enabled(v_owner_id, 'lease_signed', 'inApp') then
    return new;
  end if;

  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  ) values (
    v_owner_id,
    new.property_id,
    'lease_signed',
    'Lease Agreement Signed',
    'A lease agreement for unit has been accepted and is now active.',
    jsonb_build_object(
      'action_href', '/owner/documents',
      'lease_id',    new.id,
      'unit_id',     new.unit_id
    )
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_lease_signed on app.lease_agreements;
create trigger trg_notify_lease_signed
  after update on app.lease_agreements
  for each row execute function app.notify_lease_signed();

-- ─── 11. Notification trigger: community post published ──────────────────────

create or replace function app.notify_community_post_published()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_owner_id uuid;
begin
  v_owner_id := app.workspace_owner(new.workspace_id);
  if v_owner_id is null then return new; end if;

  -- Don't notify the owner if they posted it themselves
  if new.author_id = v_owner_id then return new; end if;

  if not app.is_notification_enabled(v_owner_id, 'community_post', 'inApp') then
    return new;
  end if;

  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  ) values (
    v_owner_id,
    null,
    'community_post',
    'New Community Post',
    coalesce(left(new.content, 80), 'A new post was published in your community.'),
    jsonb_build_object(
      'action_href', '/owner/community-hub',
      'post_id',     new.id,
      'author_id',   new.author_id
    )
  );

  return new;
exception
  -- community_posts may not have workspace_id; skip gracefully
  when undefined_column then return new;
end;
$$;

drop trigger if exists trg_notify_community_post on app.community_posts;
create trigger trg_notify_community_post
  after insert on app.community_posts
  for each row execute function app.notify_community_post_published();
