-- ============================================================================
-- V 1 06: Collaboration Accountability and Presence
-- ============================================================================
-- Purpose
--   - Add the collaboration runtime for property onboarding
--   - Support invite lifecycles, public invite onboarding, assignments, and
--     shared workspace presence
--   - Add scoped step locking and owner takeover tools
--   - Provide the PCA collaborator directory and assignment bridge
--   - Override onboarding RPCs from V 1 05 so collaboration access is enforced
--     through canonical step-aware helpers
-- ============================================================================

create schema if not exists app;
create schema if not exists public;

-- ============================================================================
-- Collaboration runtime tables
-- ============================================================================

create table if not exists app.property_collaboration_assignments (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  membership_id uuid not null references app.property_memberships(id) on delete cascade,
  invite_id uuid references app.collaboration_invites(id) on delete set null,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_step_key text not null,
  domain_scope_id uuid not null references app.lookup_domain_scopes(id) on delete restrict,
  role_id uuid not null references app.roles(id) on delete restrict,
  status text not null default 'active',
  access_mode app.invite_access_mode_enum not null default 'temporary',
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_property_collaboration_assignments_status
    check (status in ('active', 'completed', 'revoked', 'expired'))
);

drop trigger if exists trg_property_collaboration_assignments_updated_at
on app.property_collaboration_assignments;

create trigger trg_property_collaboration_assignments_updated_at
before update on app.property_collaboration_assignments
for each row execute function app.set_updated_at();

create index if not exists idx_property_collaboration_assignments_property
  on app.property_collaboration_assignments (property_id);

create index if not exists idx_property_collaboration_assignments_membership
  on app.property_collaboration_assignments (membership_id);

create index if not exists idx_property_collaboration_assignments_invite
  on app.property_collaboration_assignments (invite_id);

create index if not exists idx_property_collaboration_assignments_status
  on app.property_collaboration_assignments (status);

create index if not exists idx_property_collaboration_assignments_step
  on app.property_collaboration_assignments (assigned_step_key);

create index if not exists idx_property_collaboration_assignments_ends_at
  on app.property_collaboration_assignments (ends_at);

create unique index if not exists uq_property_collaboration_assignments_active_membership_step
  on app.property_collaboration_assignments (membership_id, assigned_step_key)
  where deleted_at is null
    and status = 'active';

create table if not exists app.property_collaboration_presence (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  membership_id uuid references app.property_memberships(id) on delete set null,
  assignment_id uuid references app.property_collaboration_assignments(id) on delete set null,
  current_step_key text,
  is_active boolean not null default true,
  entered_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  exited_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_property_collaboration_presence_updated_at
on app.property_collaboration_presence;

create trigger trg_property_collaboration_presence_updated_at
before update on app.property_collaboration_presence
for each row execute function app.set_updated_at();

create index if not exists idx_property_collaboration_presence_property
  on app.property_collaboration_presence (property_id);

create index if not exists idx_property_collaboration_presence_user
  on app.property_collaboration_presence (user_id);

create index if not exists idx_property_collaboration_presence_last_seen
  on app.property_collaboration_presence (last_seen_at);

create index if not exists idx_property_collaboration_presence_assignment
  on app.property_collaboration_presence (assignment_id);

create unique index if not exists uq_property_collaboration_presence_active_user
  on app.property_collaboration_presence (property_id, user_id)
  where is_active = true
    and exited_at is null;

-- ============================================================================
-- RLS and realtime
-- ============================================================================

alter table app.property_collaboration_assignments enable row level security;
alter table app.property_collaboration_presence enable row level security;

alter table app.property_collaboration_assignments force row level security;
alter table app.property_collaboration_presence force row level security;

drop policy if exists property_collaboration_assignments_select_scoped
on app.property_collaboration_assignments;

create policy property_collaboration_assignments_select_scoped
on app.property_collaboration_assignments
for select
to authenticated
using (
  deleted_at is null
  and (
    exists (
      select 1
      from app.property_memberships pm
      where pm.id = app.property_collaboration_assignments.membership_id
        and pm.user_id = auth.uid()
        and pm.deleted_at is null
    )
    or app.is_property_workspace_owner(app.property_collaboration_assignments.property_id)
    or app.has_domain_scope(app.property_collaboration_assignments.property_id, 'FULL_PROPERTY')
  )
);

drop policy if exists property_collaboration_presence_select_if_member
on app.property_collaboration_presence;

create policy property_collaboration_presence_select_if_member
on app.property_collaboration_presence
for select
to authenticated
using (
  app.is_property_member_or_owner(app.property_collaboration_presence.property_id)
);

do $$
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) then
    begin
      alter publication supabase_realtime add table app.property_collaboration_presence;
    exception
      when duplicate_object then null;
    end;

    begin
      alter publication supabase_realtime add table app.property_onboarding_step_states;
    exception
      when duplicate_object then null;
    end;
  end if;
end
$$;

-- ============================================================================
-- Collaboration helpers
-- ============================================================================

create or replace function app.normalize_onboarding_step_key(p_step_key text)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case lower(coalesce(trim(p_step_key), ''))
    when 'identity' then 'identity'
    when 'usage' then 'usage'
    when 'structure' then 'structure'
    when 'ownership' then 'ownership'
    when 'accountability' then 'accountability'
    when 'review' then 'review'
    when 'review-activate' then 'review'
    when 'review_activate' then 'review'
    when 'done' then 'done'
    else null
  end;
$$;

create or replace function app.get_profile_display_name(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = app, public
as $$
  select coalesce(
    nullif(trim(concat_ws(' ', p.first_name, p.last_name)), ''),
    nullif(trim(p.email), ''),
    p_user_id::text
  )
  from app.profiles p
  where p.id = p_user_id
  limit 1;
$$;

create or replace function app.get_default_assignment_step_for_scope(p_scope_code text)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case upper(coalesce(trim(p_scope_code), ''))
    when 'UNITS' then 'structure'
    when 'OWNERSHIP' then 'ownership'
    when 'DOCUMENTS' then 'ownership'
    when 'ACCOUNTABILITY' then 'accountability'
    else null
  end;
$$;

create or replace function app.is_scope_allowed_for_step(
  p_scope_code text,
  p_step_key text
)
returns boolean
language sql
immutable
security definer
set search_path = app, public
as $$
  select case
    when upper(coalesce(trim(p_scope_code), '')) = 'FULL_PROPERTY' then true
    when app.normalize_onboarding_step_key(p_step_key) = 'structure'
      then upper(coalesce(trim(p_scope_code), '')) in ('UNITS')
    when app.normalize_onboarding_step_key(p_step_key) = 'ownership'
      then upper(coalesce(trim(p_scope_code), '')) in ('OWNERSHIP', 'DOCUMENTS')
    when app.normalize_onboarding_step_key(p_step_key) = 'accountability'
      then upper(coalesce(trim(p_scope_code), '')) in ('ACCOUNTABILITY')
    else false
  end;
$$;

create or replace function app.upsert_property_collaboration_assignment(
  p_property_id uuid,
  p_membership_id uuid,
  p_invite_id uuid,
  p_assigned_by uuid,
  p_assigned_step_key text,
  p_access_mode app.invite_access_mode_enum,
  p_starts_at timestamptz default now(),
  p_ends_at timestamptz default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_assignment_id uuid;
  v_membership record;
  v_step_key text;
  v_scope_code text;
  v_assigned_by uuid;
begin
  if p_property_id is null or p_membership_id is null then
    raise exception 'Invalid collaboration assignment payload';
  end if;

  select
    pm.property_id,
    pm.user_id,
    pm.role_id,
    pm.domain_scope_id,
    pm.status,
    pm.ends_at,
    ds.code as scope_code
  into v_membership
  from app.property_memberships pm
  join app.lookup_domain_scopes ds
    on ds.id = pm.domain_scope_id
   and ds.deleted_at is null
  where pm.id = p_membership_id
    and pm.deleted_at is null
  limit 1;

  if v_membership.property_id is null then
    raise exception 'Membership not found';
  end if;

  if v_membership.property_id <> p_property_id then
    raise exception 'Membership does not belong to the requested property';
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_assigned_step_key);
  v_scope_code := upper(coalesce(v_membership.scope_code, ''));
  v_assigned_by := coalesce(p_assigned_by, v_membership.user_id);

  if v_step_key is null then
    raise exception 'Invalid assigned step key: %', p_assigned_step_key;
  end if;

  if not app.is_scope_allowed_for_step(v_scope_code, v_step_key) then
    raise exception 'Domain scope % is not allowed to edit step %', v_scope_code, v_step_key;
  end if;

  insert into app.property_collaboration_assignments (
    property_id,
    membership_id,
    invite_id,
    assigned_by,
    assigned_step_key,
    domain_scope_id,
    role_id,
    status,
    access_mode,
    starts_at,
    ends_at,
    notes
  )
  values (
    p_property_id,
    p_membership_id,
    p_invite_id,
    v_assigned_by,
    v_step_key,
    v_membership.domain_scope_id,
    v_membership.role_id,
    case
      when coalesce(p_ends_at, v_membership.ends_at) is not null
        and coalesce(p_ends_at, v_membership.ends_at) <= now()
        then 'expired'
      else 'active'
    end,
    coalesce(p_access_mode, 'temporary'),
    coalesce(p_starts_at, now()),
    coalesce(p_ends_at, v_membership.ends_at),
    nullif(trim(p_notes), '')
  )
  on conflict (membership_id, assigned_step_key)
    where deleted_at is null
      and status = 'active'
  do update set
    invite_id = excluded.invite_id,
    assigned_by = excluded.assigned_by,
    domain_scope_id = excluded.domain_scope_id,
    role_id = excluded.role_id,
    access_mode = excluded.access_mode,
    starts_at = excluded.starts_at,
    ends_at = excluded.ends_at,
    notes = excluded.notes,
    deleted_at = null,
    deleted_by = null,
    updated_at = now()
  returning id into v_assignment_id;

  return v_assignment_id;
end;
$$;

create table if not exists app.user_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  property_id uuid references app.properties(id) on delete cascade,
  notification_type text not null,
  title text not null,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists user_notifications_user_read_created_idx
  on app.user_notifications (user_id, is_read, created_at desc);

create index if not exists user_notifications_property_created_idx
  on app.user_notifications (property_id, created_at desc);

create unique index if not exists user_notifications_property_activation_unique_idx
  on app.user_notifications (user_id, property_id, notification_type)
  where notification_type = 'property_onboarding_completed';

revoke all on table app.user_notifications from public, anon, authenticated;

create or replace function app.enqueue_property_activation_notifications(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_name text;
  v_action_href text := '/owner/units';
begin
  select coalesce(nullif(trim(p.display_name), ''), 'Untitled Property')
    into v_property_name
  from app.properties p
  where p.id = p_property_id
    and p.deleted_at is null
  limit 1;

  if v_property_name is null then
    raise exception 'Property not found for activation notification: %', p_property_id;
  end if;

  with recipient_pool as (
    select p.created_by as user_id
    from app.properties p
    where p.id = p_property_id
      and p.deleted_at is null
    union
    select pm.user_id
    from app.property_memberships pm
    where pm.property_id = p_property_id
      and pm.deleted_at is null
      and pm.status = 'active'
  )
  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  )
  select
    rp.user_id,
    p_property_id,
    'property_onboarding_completed',
    'Property activated',
    format('%s has completed onboarding and is now live in your workspace.', v_property_name),
    jsonb_build_object(
      'action_href', v_action_href,
      'property_name', v_property_name,
      'actor_user_id', auth.uid(),
      'event', 'property_activated'
    )
  from recipient_pool rp
  where rp.user_id is not null
  on conflict do nothing;
end;
$$;

create or replace function app.get_my_notifications(
  p_limit integer default 10
)
returns table (
  id uuid,
  notification_type text,
  title text,
  message text,
  property_id uuid,
  is_read boolean,
  created_at timestamptz,
  action_href text,
  actor_user_id uuid
)
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    n.id,
    n.notification_type,
    n.title,
    n.message,
    n.property_id,
    n.is_read,
    n.created_at,
    coalesce(n.metadata ->> 'action_href', '/owner/units') as action_href,
    nullif(n.metadata ->> 'actor_user_id', '')::uuid as actor_user_id
  from app.user_notifications n
  where n.user_id = auth.uid()
  order by n.created_at desc
  limit greatest(coalesce(p_limit, 10), 1);
end;
$$;

create or replace function app.mark_my_notifications_read(
  p_notification_ids uuid[] default null
)
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_updated_rows integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update app.user_notifications
     set is_read = true,
         read_at = now()
   where user_id = auth.uid()
     and is_read = false
     and (p_notification_ids is null or id = any(p_notification_ids));

  get diagnostics v_updated_rows = row_count;
  return v_updated_rows;
end;
$$;

create or replace function app.expire_collaboration_invites()
returns int
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_count int;
begin
  update app.collaboration_invites
     set status = 'expired',
         updated_at = now()
   where deleted_at is null
     and status in ('pending', 'viewed')
     and expires_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function app.cleanup_dormant_properties(
  p_days int default 90
)
returns int
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_days int := greatest(coalesce(p_days, 90), 7);
  v_count int;
begin
  update app.properties
     set deleted_at = now(),
         deleted_by = null,
         last_activity_at = now()
   where deleted_at is null
     and status = 'draft'
     and last_activity_at < (now() - make_interval(days => v_days));

  get diagnostics v_count = row_count;

  update app.property_onboarding_sessions
     set status = 'abandoned',
         updated_at = now()
   where deleted_at is null
     and property_id in (
       select id
       from app.properties
       where deleted_at is not null
         and status = 'draft'
         and last_activity_at >= (now() - make_interval(days => 1))
     );

  return v_count;
end;
$$;

revoke all on function app.enqueue_property_activation_notifications(uuid) from public, anon, authenticated;
revoke all on function app.get_my_notifications(integer) from public, anon, authenticated;
revoke all on function app.mark_my_notifications_read(uuid[]) from public, anon, authenticated;
revoke all on function app.expire_collaboration_invites() from public, anon, authenticated;
revoke all on function app.cleanup_dormant_properties(int) from public, anon, authenticated;

grant execute on function app.enqueue_property_activation_notifications(uuid) to authenticated;
grant execute on function app.get_my_notifications(integer) to authenticated;
grant execute on function app.mark_my_notifications_read(uuid[]) to authenticated;
grant execute on function app.expire_collaboration_invites() to service_role;
grant execute on function app.cleanup_dormant_properties(int) to service_role;

create or replace function app.can_edit_onboarding_step(
  p_property_id uuid,
  p_step_key text
)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  with normalized as (
    select app.normalize_onboarding_step_key(p_step_key) as step_key
  )
  select case
    when auth.uid() is null then false
    when app.is_property_workspace_owner(p_property_id) then true
    when app.has_domain_scope(p_property_id, 'FULL_PROPERTY') then true
    else exists (
      select 1
      from normalized n
      join app.property_collaboration_assignments a
        on a.property_id = p_property_id
       and a.assigned_step_key = n.step_key
       and a.deleted_at is null
       and a.status = 'active'
       and (a.ends_at is null or a.ends_at > now())
      join app.property_memberships pm
        on pm.id = a.membership_id
       and pm.property_id = p_property_id
       and pm.user_id = auth.uid()
       and pm.status = 'active'
       and pm.deleted_at is null
       and (pm.ends_at is null or pm.ends_at > now())
      join app.lookup_domain_scopes ds
        on ds.id = a.domain_scope_id
       and ds.deleted_at is null
      where n.step_key is not null
        and app.is_scope_allowed_for_step(ds.code, n.step_key)
    )
  end;
$$;

create or replace function app.assert_can_edit_onboarding_step(
  p_property_id uuid,
  p_step_key text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_step_key text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_step_key);

  if v_step_key is null then
    raise exception 'Invalid onboarding step: %', p_step_key;
  end if;

  if not app.can_edit_onboarding_step(p_property_id, v_step_key) then
    raise exception 'Forbidden: you do not have edit access to step %', v_step_key;
  end if;
end;
$$;

create or replace function app.assert_can_lock_onboarding_step(
  p_property_id uuid,
  p_step_key text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_step_key text;
begin
  v_step_key := app.normalize_onboarding_step_key(p_step_key);

  if v_step_key is null then
    raise exception 'Invalid onboarding step: %', p_step_key;
  end if;

  perform app.assert_property_onboarding_open(p_property_id);
  perform app.assert_can_edit_onboarding_step(p_property_id, v_step_key);
end;
$$;

create or replace function app.get_primary_collaboration_assignment_for_user(
  p_property_id uuid,
  p_user_id uuid default auth.uid()
)
returns table (
  assignment_id uuid,
  membership_id uuid,
  role_id uuid,
  role_key text,
  role_name text,
  scope_id uuid,
  scope_code text,
  scope_label text,
  assigned_step_key text,
  access_mode app.invite_access_mode_enum,
  starts_at timestamptz,
  ends_at timestamptz,
  status text
)
language sql
stable
security definer
set search_path = app, public
as $$
  with property_context as (
    select p.current_step_key
    from app.properties p
    where p.id = p_property_id
      and p.deleted_at is null
  )
  select
    a.id as assignment_id,
    pm.id as membership_id,
    r.id as role_id,
    r.key as role_key,
    r.name as role_name,
    ds.id as scope_id,
    ds.code as scope_code,
    ds.label as scope_label,
    a.assigned_step_key,
    a.access_mode,
    a.starts_at,
    a.ends_at,
    case
      when a.ends_at is not null and a.ends_at <= now() then 'expired'
      else a.status
    end as status
  from app.property_collaboration_assignments a
  join app.property_memberships pm
    on pm.id = a.membership_id
   and pm.deleted_at is null
   and pm.status = 'active'
   and (pm.ends_at is null or pm.ends_at > now())
  join app.roles r
    on r.id = a.role_id
   and r.deleted_at is null
  join app.lookup_domain_scopes ds
    on ds.id = a.domain_scope_id
   and ds.deleted_at is null
  left join property_context pc
    on true
  where a.property_id = p_property_id
    and pm.user_id = p_user_id
    and a.deleted_at is null
    and a.status = 'active'
    and (a.ends_at is null or a.ends_at > now())
  order by
    case
      when a.assigned_step_key = app.normalize_onboarding_step_key(pc.current_step_key) then 0
      else 1
    end,
    a.starts_at desc,
    a.created_at desc
  limit 1;
$$;

revoke all on function app.normalize_onboarding_step_key(text)
from public, authenticated;

revoke all on function app.get_profile_display_name(uuid)
from public, authenticated;

revoke all on function app.get_default_assignment_step_for_scope(text)
from public, authenticated;

revoke all on function app.is_scope_allowed_for_step(text, text)
from public, authenticated;

revoke all on function app.upsert_property_collaboration_assignment(
  uuid, uuid, uuid, uuid, text, app.invite_access_mode_enum, timestamptz, timestamptz, text
)
from public, authenticated;

revoke all on function app.can_edit_onboarding_step(uuid, text)
from public;

grant execute on function app.can_edit_onboarding_step(uuid, text)
to authenticated;

revoke all on function app.assert_can_edit_onboarding_step(uuid, text)
from public, authenticated;

revoke all on function app.assert_can_lock_onboarding_step(uuid, text)
from public, authenticated;

revoke all on function app.get_primary_collaboration_assignment_for_user(uuid, uuid)
from public, authenticated;

-- ============================================================================
-- Invite lifecycle and public onboarding wrappers
-- ============================================================================

create or replace function app.send_collaboration_invite(
  p_property_id uuid,
  p_invited_email text,
  p_role_key text,
  p_domain_scope_code text,
  p_invited_phone text default null,
  p_access_mode app.invite_access_mode_enum default 'temporary',
  p_expires_in_days integer default 7,
  p_assigned_step_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_role_id uuid;
  v_scope_id uuid;
  v_token text;
  v_token_hash text;
  v_expires_at timestamptz;
  v_days integer;
  v_identity_done timestamptz;
  v_action_id uuid;
  v_step_key text;
  v_effective_access_mode app.invite_access_mode_enum;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);
  perform app.assert_property_onboarding_open(p_property_id);

  if p_invited_email is null or char_length(trim(p_invited_email)) < 3 then
    raise exception 'Invalid invited_email';
  end if;

  select p.identity_completed_at
    into v_identity_done
  from app.properties p
  where p.id = p_property_id
    and p.deleted_at is null;

  if v_identity_done is null then
    raise exception 'You can invite collaborators only after Step 1 (Identity) is completed';
  end if;

  v_role_id := app.get_role_id_by_key(trim(p_role_key));
  if v_role_id is null then
    raise exception 'Invalid role key: %', p_role_key;
  end if;

  v_scope_id := app.get_scope_id_by_code(trim(p_domain_scope_code));
  if v_scope_id is null then
    raise exception 'Invalid domain scope: %', p_domain_scope_code;
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_assigned_step_key);
  if p_assigned_step_key is not null and v_step_key is null then
    raise exception 'Invalid assigned step key: %', p_assigned_step_key;
  end if;

  if v_step_key is not null and not app.is_scope_allowed_for_step(p_domain_scope_code, v_step_key) then
    raise exception 'Assigned step % is not compatible with scope %', v_step_key, p_domain_scope_code;
  end if;

  v_effective_access_mode := case
    when upper(coalesce(trim(p_role_key), '')) = 'PROPERTY_MANAGER' then 'permanent'::app.invite_access_mode_enum
    when upper(coalesce(trim(p_domain_scope_code), '')) = 'FULL_PROPERTY' then 'permanent'::app.invite_access_mode_enum
    else coalesce(p_access_mode, 'temporary'::app.invite_access_mode_enum)
  end;

  v_days := coalesce(p_expires_in_days, 7);
  if v_days < 1 then v_days := 1; end if;
  if v_days > 30 then v_days := 30; end if;

  v_expires_at := now() + make_interval(days => v_days);
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_token_hash := app.hash_token(v_token);

  update app.collaboration_invites
     set status = 'revoked',
         updated_at = now()
   where property_id = p_property_id
     and lower(invited_email) = lower(trim(p_invited_email))
     and role_id = v_role_id
     and domain_scope_id = v_scope_id
     and deleted_at is null
     and status in ('pending', 'viewed');

  insert into app.collaboration_invites (
    property_id,
    invited_email,
    invited_phone,
    role_id,
    domain_scope_id,
    access_mode,
    status,
    token_hash,
    expires_at,
    invited_by,
    metadata
  )
  values (
    p_property_id,
    lower(trim(p_invited_email)),
    nullif(trim(p_invited_phone), ''),
    v_role_id,
    v_scope_id,
    v_effective_access_mode,
    'pending',
    v_token_hash,
    v_expires_at,
    auth.uid(),
    jsonb_strip_nulls(
      jsonb_build_object(
        'expires_in_days', v_days,
        'assigned_step_key', v_step_key
      )
    )
  );

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('INVITE_SENT');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'invited_email', lower(trim(p_invited_email)),
        'role', trim(p_role_key),
        'domain_scope', trim(p_domain_scope_code),
        'access_mode', v_effective_access_mode::text,
        'expires_at', v_expires_at,
        'assigned_step_key', v_step_key
      )
    );
  end if;

  return jsonb_build_object(
    'token', v_token,
    'expires_at', v_expires_at,
    'invited_email', lower(trim(p_invited_email)),
    'role_key', trim(p_role_key),
    'domain_scope', trim(p_domain_scope_code),
    'access_mode', v_effective_access_mode::text,
    'assigned_step_key', v_step_key
  );
end;
$$;

create or replace function app.revoke_collaboration_invite(
  p_invite_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select i.property_id
    into v_property_id
  from app.collaboration_invites i
  where i.id = p_invite_id
    and i.deleted_at is null;

  if v_property_id is null then
    raise exception 'Invite not found';
  end if;

  perform app.assert_property_full_access(v_property_id);

  update app.collaboration_invites
     set status = 'revoked',
         updated_at = now()
   where id = p_invite_id
     and deleted_at is null
     and status in ('pending', 'viewed');

  perform app.touch_property_activity(v_property_id);
end;
$$;

create or replace function app.mark_invite_viewed(
  p_token text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_token_hash text;
begin
  if p_token is null or char_length(trim(p_token)) < 10 then
    raise exception 'Invalid token';
  end if;

  v_token_hash := app.hash_token(p_token);

  update app.collaboration_invites
     set status = 'viewed',
         updated_at = now()
   where token_hash = v_token_hash
     and deleted_at is null
     and status = 'pending'
     and expires_at > now();
end;
$$;

create or replace function app.accept_collaboration_invite(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_token_hash text;
  v_invite record;
  v_profile_email text;
  v_membership_id uuid;
  v_membership_ends timestamptz;
  v_action_id uuid;
  v_assignment_id uuid;
  v_assigned_step_key text;
  v_scope_code text;
  v_role_key text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_token is null or char_length(trim(p_token)) < 10 then
    raise exception 'Invalid or expired invite token';
  end if;

  v_token_hash := app.hash_token(p_token);

  select p.email
    into v_profile_email
  from app.profiles p
  where p.id = auth.uid()
  limit 1;

  if v_profile_email is null then
    raise exception 'Profile missing email';
  end if;

  select *
    into v_invite
  from app.collaboration_invites i
  where i.token_hash = v_token_hash
    and i.deleted_at is null
    and i.status in ('pending', 'viewed')
    and i.expires_at > now()
  limit 1;

  if v_invite.id is null then
    raise exception 'Invalid or expired invite token';
  end if;

  if lower(v_profile_email) <> lower(v_invite.invited_email) then
    raise exception 'Invite email mismatch';
  end if;

  if v_invite.access_mode = 'temporary' then
    v_membership_ends := now() + make_interval(
      days => greatest(
        1,
        least(30, coalesce((v_invite.metadata->>'expires_in_days')::integer, 7))
      )
    );
  else
    v_membership_ends := null;
  end if;

  update app.collaboration_invites
     set status = 'accepted',
         accepted_by = auth.uid(),
         accepted_at = now(),
         updated_at = now()
   where id = v_invite.id;

  update app.collaboration_invites
     set status = 'revoked',
         updated_at = now()
   where property_id = v_invite.property_id
     and lower(invited_email) = lower(v_invite.invited_email)
     and role_id = v_invite.role_id
     and domain_scope_id = v_invite.domain_scope_id
     and id <> v_invite.id
     and deleted_at is null
     and status in ('pending', 'viewed');

  insert into app.property_memberships (
    property_id,
    user_id,
    role_id,
    domain_scope_id,
    status,
    starts_at,
    ends_at,
    created_from_invite_id,
    granted_by
  )
  values (
    v_invite.property_id,
    auth.uid(),
    v_invite.role_id,
    v_invite.domain_scope_id,
    'active',
    now(),
    v_membership_ends,
    v_invite.id,
    v_invite.invited_by
  )
  on conflict (property_id, user_id, domain_scope_id)
    where deleted_at is null
      and status = 'active'
  do update set
    role_id = excluded.role_id,
    status = 'active',
    starts_at = now(),
    ends_at = excluded.ends_at,
    created_from_invite_id = excluded.created_from_invite_id,
    granted_by = excluded.granted_by,
    deleted_at = null,
    deleted_by = null,
    updated_at = now()
  returning id into v_membership_id;

  select ds.code
    into v_scope_code
  from app.lookup_domain_scopes ds
  where ds.id = v_invite.domain_scope_id
    and ds.deleted_at is null
  limit 1;

  select r.key
    into v_role_key
  from app.roles r
  where r.id = v_invite.role_id
    and r.deleted_at is null
  limit 1;

  v_assigned_step_key := app.normalize_onboarding_step_key(v_invite.metadata->>'assigned_step_key');
  if v_assigned_step_key is null then
    v_assigned_step_key := app.get_default_assignment_step_for_scope(v_scope_code);
  end if;

  if v_assigned_step_key is not null then
    v_assignment_id := app.upsert_property_collaboration_assignment(
      v_invite.property_id,
      v_membership_id,
      v_invite.id,
      v_invite.invited_by,
      v_assigned_step_key,
      v_invite.access_mode,
      now(),
      v_membership_ends,
      null
    );
  end if;

  if upper(coalesce(v_role_key, '')) = 'PROPERTY_MANAGER'
     or upper(coalesce(v_scope_code, '')) = 'FULL_PROPERTY' then
    update app.property_admin_contacts
       set linked_user_id = auth.uid(),
           updated_at = now()
     where property_id = v_invite.property_id
       and deleted_at is null
       and lower(coalesce(contact_email, '')) = lower(v_invite.invited_email);
  end if;

  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('INVITE_ACCEPTED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      v_invite.property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'invite_id', v_invite.id,
        'membership_id', v_membership_id,
        'assignment_id', v_assignment_id,
        'access_mode', v_invite.access_mode::text,
        'assigned_step_key', v_assigned_step_key
      )
    );
  end if;

  return jsonb_build_object(
    'property_id', v_invite.property_id,
    'membership_id', v_membership_id,
    'assignment_id', v_assignment_id,
    'assigned_step_key', v_assigned_step_key,
    'ends_at', v_membership_ends
  );
end;
$$;

create or replace function app.get_collaboration_invite_public_details(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_token_hash text;
  v_invite record;
begin
  if p_token is null or char_length(trim(p_token)) < 10 then
    raise exception 'Invalid or expired invite token';
  end if;

  v_token_hash := app.hash_token(p_token);

  select
    i.id,
    i.property_id,
    p.display_name as property_name,
    i.invited_email,
    coalesce(i.invited_phone, pac.contact_phone) as invited_phone,
    i.access_mode,
    i.expires_at,
    r.key as role_key,
    r.name as role_name,
    pac.contact_name
  into v_invite
  from app.collaboration_invites i
  join app.properties p
    on p.id = i.property_id
   and p.deleted_at is null
  join app.roles r
    on r.id = i.role_id
   and r.deleted_at is null
   and r.is_active = true
  left join app.property_admin_contacts pac
    on pac.property_id = i.property_id
   and pac.deleted_at is null
   and lower(coalesce(pac.contact_email, '')) = lower(i.invited_email)
  where i.token_hash = v_token_hash
    and i.deleted_at is null
    and i.status in ('pending', 'viewed')
    and i.expires_at > now()
  limit 1;

  if v_invite.id is null then
    raise exception 'Invalid or expired invite token';
  end if;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'property_id', v_invite.property_id,
    'property_name', v_invite.property_name,
    'invited_email', v_invite.invited_email,
    'invited_phone', v_invite.invited_phone,
    'contact_name', v_invite.contact_name,
    'role_key', v_invite.role_key,
    'role_name', v_invite.role_name,
    'access_mode', v_invite.access_mode::text,
    'expires_at', v_invite.expires_at
  );
end;
$$;

create or replace function app.upsert_collaboration_invite_phone(
  p_token text,
  p_phone text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_token_hash text;
begin
  if p_token is null or char_length(trim(p_token)) < 10 then
    raise exception 'Invalid or expired invite token';
  end if;

  v_token_hash := app.hash_token(p_token);

  update app.collaboration_invites
     set invited_phone = nullif(trim(p_phone), ''),
         updated_at = now()
   where token_hash = v_token_hash
     and deleted_at is null
     and status in ('pending', 'viewed')
     and expires_at > now();

  if not found then
    raise exception 'Invalid or expired invite token';
  end if;
end;
$$;

create or replace function public.get_collaboration_invite_public_details(
  p_token text
)
returns jsonb
language sql
security definer
set search_path = app, public
as $$
  select app.get_collaboration_invite_public_details(p_token);
$$;

create or replace function public.upsert_collaboration_invite_phone(
  p_token text,
  p_phone text default null
)
returns void
language sql
security definer
set search_path = app, public
as $$
  select app.upsert_collaboration_invite_phone(p_token, p_phone);
$$;

revoke all on function app.send_collaboration_invite(
  uuid, text, text, text, text, app.invite_access_mode_enum, integer, text
)
from public;

grant execute on function app.send_collaboration_invite(
  uuid, text, text, text, text, app.invite_access_mode_enum, integer, text
)
to authenticated;

revoke all on function app.revoke_collaboration_invite(uuid)
from public;

grant execute on function app.revoke_collaboration_invite(uuid)
to authenticated;

revoke all on function app.mark_invite_viewed(text)
from public;

grant execute on function app.mark_invite_viewed(text)
to authenticated;

revoke all on function app.accept_collaboration_invite(text)
from public;

grant execute on function app.accept_collaboration_invite(text)
to authenticated;

revoke all on function app.get_collaboration_invite_public_details(text)
from public, authenticated, anon;

grant execute on function app.get_collaboration_invite_public_details(text)
to authenticated, anon;

revoke all on function app.upsert_collaboration_invite_phone(text, text)
from public, authenticated, anon;

grant execute on function app.upsert_collaboration_invite_phone(text, text)
to authenticated, anon;

revoke all on function public.get_collaboration_invite_public_details(text)
from public, authenticated, anon;

grant execute on function public.get_collaboration_invite_public_details(text)
to authenticated, anon;

revoke all on function public.upsert_collaboration_invite_phone(text, text)
from public, authenticated, anon;

grant execute on function public.upsert_collaboration_invite_phone(text, text)
to authenticated, anon;

-- ============================================================================
-- Collaboration dashboard and workspace context
-- ============================================================================

create or replace function app.get_my_collaboration_assignments()
returns table (
  assignment_id uuid,
  property_id uuid,
  property_name text,
  property_status text,
  property_type_code text,
  city_town text,
  area_neighborhood text,
  role_key text,
  role_name text,
  scope_code text,
  scope_label text,
  access_mode text,
  starts_at timestamptz,
  ends_at timestamptz,
  assigned_step_key text,
  assignment_status text,
  current_step_key text,
  unit_count integer,
  pending_work_count integer,
  is_expiring_soon boolean,
  last_activity_at timestamptz
)
language sql
stable
security definer
set search_path = app, public
as $$
  with ranked_assignments as (
    select
      a.id as assignment_id,
      a.property_id,
      p.display_name as property_name,
      p.status::text as property_status,
      pt.code as property_type_code,
      p.city_town,
      p.area_neighborhood,
      r.key as role_key,
      r.name as role_name,
      ds.code as scope_code,
      ds.label as scope_label,
      a.access_mode::text as access_mode,
      a.starts_at,
      coalesce(a.ends_at, pm.ends_at) as ends_at,
      a.assigned_step_key,
      case
        when coalesce(a.ends_at, pm.ends_at) is not null
          and coalesce(a.ends_at, pm.ends_at) <= now()
          then 'expired'
        else a.status
      end as assignment_status,
      p.current_step_key,
      p.last_activity_at,
      row_number() over (
        partition by a.property_id
        order by a.starts_at desc, a.created_at desc
      ) as assignment_rank
    from app.property_collaboration_assignments a
    join app.property_memberships pm
      on pm.id = a.membership_id
     and pm.user_id = auth.uid()
     and pm.deleted_at is null
    join app.properties p
      on p.id = a.property_id
     and p.deleted_at is null
    left join app.lookup_property_types pt
      on pt.id = p.property_type_id
     and pt.deleted_at is null
    join app.roles r
      on r.id = a.role_id
     and r.deleted_at is null
    join app.lookup_domain_scopes ds
      on ds.id = a.domain_scope_id
     and ds.deleted_at is null
    where a.deleted_at is null
      and a.status <> 'revoked'
  ),
  selected_assignments as (
    select *
    from ranked_assignments
    where assignment_rank = 1
  ),
  membership_only_rows as (
    select
      pm.id as assignment_id,
      pm.property_id,
      p.display_name as property_name,
      p.status::text as property_status,
      pt.code as property_type_code,
      p.city_town,
      p.area_neighborhood,
      r.key as role_key,
      r.name as role_name,
      ds.code as scope_code,
      ds.label as scope_label,
      case
        when pm.ends_at is null then 'permanent'
        else 'temporary'
      end as access_mode,
      pm.starts_at,
      pm.ends_at,
      p.current_step_key as assigned_step_key,
      case
        when pm.ends_at is not null and pm.ends_at <= now() then 'expired'
        else pm.status
      end as assignment_status,
      p.current_step_key,
      p.last_activity_at
    from app.property_memberships pm
    join app.properties p
      on p.id = pm.property_id
     and p.deleted_at is null
    left join app.lookup_property_types pt
      on pt.id = p.property_type_id
     and pt.deleted_at is null
    join app.roles r
      on r.id = pm.role_id
     and r.deleted_at is null
    join app.lookup_domain_scopes ds
      on ds.id = pm.domain_scope_id
     and ds.deleted_at is null
    where pm.user_id = auth.uid()
      and pm.deleted_at is null
      and pm.status = 'active'
      and ds.code = 'FULL_PROPERTY'
      and not exists (
        select 1
        from app.property_collaboration_assignments a
        where a.membership_id = pm.id
          and a.deleted_at is null
          and a.status <> 'revoked'
      )
  ),
  combined_assignments as (
    select
      sa.assignment_id,
      sa.property_id,
      sa.property_name,
      sa.property_status,
      sa.property_type_code,
      sa.city_town,
      sa.area_neighborhood,
      sa.role_key,
      sa.role_name,
      sa.scope_code,
      sa.scope_label,
      sa.access_mode,
      sa.starts_at,
      sa.ends_at,
      sa.assigned_step_key,
      sa.assignment_status,
      sa.current_step_key,
      sa.last_activity_at
    from selected_assignments sa
    union all
    select
      mor.assignment_id,
      mor.property_id,
      mor.property_name,
      mor.property_status,
      mor.property_type_code,
      mor.city_town,
      mor.area_neighborhood,
      mor.role_key,
      mor.role_name,
      mor.scope_code,
      mor.scope_label,
      mor.access_mode,
      mor.starts_at,
      mor.ends_at,
      mor.assigned_step_key,
      mor.assignment_status,
      mor.current_step_key,
      mor.last_activity_at
    from membership_only_rows mor
  ),
  session_map as (
    select s.property_id, s.id as session_id
    from app.property_onboarding_sessions s
    where s.deleted_at is null
  ),
  unit_counts as (
    select u.property_id, count(*)::integer as unit_count
    from app.units u
    where u.deleted_at is null
    group by u.property_id
  )
  select
    ca.assignment_id,
    ca.property_id,
    ca.property_name,
    ca.property_status,
    ca.property_type_code,
    ca.city_town,
    ca.area_neighborhood,
    ca.role_key,
    ca.role_name,
    ca.scope_code,
    ca.scope_label,
    ca.access_mode,
    ca.starts_at,
    ca.ends_at,
    ca.assigned_step_key,
    ca.assignment_status,
    ca.current_step_key,
    coalesce(uc.unit_count, 0) as unit_count,
    case
      when exists (
        select 1
        from session_map sm
        join app.property_onboarding_step_states ss
          on ss.session_id = sm.session_id
         and ss.deleted_at is null
         and ss.step_key = ca.assigned_step_key
        where sm.property_id = ca.property_id
          and ss.status <> 'completed'
      ) then 1
      when ca.property_status = 'draft' then 1
      else 0
    end as pending_work_count,
    (
      ca.ends_at is not null
      and ca.ends_at > now()
      and ca.ends_at <= now() + interval '3 days'
    ) as is_expiring_soon,
    ca.last_activity_at
  from combined_assignments ca
  left join unit_counts uc
    on uc.property_id = ca.property_id
  order by ca.last_activity_at desc nulls last, ca.starts_at desc;
$$;

create or replace function app.get_collaboration_workspace_context(
  p_property_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_assignment record;
  v_property record;
  v_can_manage boolean;
  v_visible_steps text[] := array['identity', 'usage', 'structure', 'ownership', 'accountability', 'review'];
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_can_manage := app.is_property_workspace_owner(p_property_id)
    or app.has_domain_scope(p_property_id, 'FULL_PROPERTY');

  select
    null::uuid as assignment_id,
    null::uuid as membership_id,
    null::uuid as role_id,
    null::text as role_key,
    null::text as role_name,
    null::uuid as scope_id,
    null::text as scope_code,
    null::text as scope_label,
    null::text as assigned_step_key,
    null::app.invite_access_mode_enum as access_mode,
    null::timestamptz as starts_at,
    null::timestamptz as ends_at,
    null::text as status
  into v_assignment;

  if not v_can_manage then
    select *
      into v_assignment
    from app.get_primary_collaboration_assignment_for_user(p_property_id);

    if v_assignment.assignment_id is null then
      raise exception 'Forbidden: no active collaboration access for this property';
    end if;
  end if;

  select
    p.id,
    p.display_name,
    p.status::text as property_status,
    p.current_step_key,
    p.last_activity_at,
    pt.code as property_type_code,
    p.city_town,
    p.area_neighborhood,
    (
      select count(*)::integer
      from app.units u
      where u.property_id = p.id
        and u.deleted_at is null
    ) as unit_count
  into v_property
  from app.properties p
  left join app.lookup_property_types pt
    on pt.id = p.property_type_id
   and pt.deleted_at is null
  where p.id = p_property_id
    and p.deleted_at is null
  limit 1;

  if v_property.id is null then
    raise exception 'Property not found or deleted';
  end if;

  return jsonb_build_object(
    'property', jsonb_build_object(
      'id', v_property.id,
      'name', v_property.display_name,
      'status', v_property.property_status,
      'property_type_code', v_property.property_type_code,
      'city_town', v_property.city_town,
      'area_neighborhood', v_property.area_neighborhood,
      'current_step_key', v_property.current_step_key,
      'last_activity_at', v_property.last_activity_at,
      'unit_count', coalesce(v_property.unit_count, 0)
    ),
    'assignment', case
      when v_can_manage then jsonb_build_object(
        'role_key', 'OWNER',
        'role_name', 'Owner',
        'scope_code', 'FULL_PROPERTY',
        'scope_label', 'Full Property',
        'access_mode', 'permanent',
        'assigned_step_key', null,
        'starts_at', null,
        'ends_at', null
      )
      else jsonb_build_object(
        'assignment_id', v_assignment.assignment_id,
        'membership_id', v_assignment.membership_id,
        'role_key', v_assignment.role_key,
        'role_name', v_assignment.role_name,
        'scope_code', v_assignment.scope_code,
        'scope_label', v_assignment.scope_label,
        'access_mode', v_assignment.access_mode,
        'assigned_step_key', v_assignment.assigned_step_key,
        'starts_at', v_assignment.starts_at,
        'ends_at', v_assignment.ends_at,
        'status', v_assignment.status
      )
    end,
    'editable_step_key', case
      when v_can_manage then null
      else v_assignment.assigned_step_key
    end,
    'visible_step_keys', to_jsonb(v_visible_steps),
    'locked_step_keys', case
      when v_can_manage then '[]'::jsonb
      else to_jsonb(
        array(
          select step_key
          from unnest(v_visible_steps) as step_key
          where step_key <> v_assignment.assigned_step_key
        )
      )
    end,
    'step_states', coalesce((
      select jsonb_agg(step_row.payload order by step_row.step_index)
      from (
        select
          app.get_step_index(ss.step_key) as step_index,
          jsonb_build_object(
            'step_key', ss.step_key,
            'status', ss.status,
            'locked_by', ss.locked_by,
            'locked_by_name', case
              when ss.locked_by is not null then app.get_profile_display_name(ss.locked_by)
              else null
            end,
            'locked_until', ss.lock_expires_at,
            'is_locked', ss.locked_by is not null
              and (ss.lock_expires_at is null or ss.lock_expires_at > now()),
            'is_editable', case
              when v_can_manage then true
              else ss.step_key = v_assignment.assigned_step_key
            end,
            'is_assigned', case
              when v_can_manage then false
              else ss.step_key = v_assignment.assigned_step_key
            end
          ) as payload
        from app.property_onboarding_sessions s
        join app.property_onboarding_step_states ss
          on ss.session_id = s.id
         and ss.deleted_at is null
        where s.property_id = p_property_id
          and s.deleted_at is null
      ) as step_row
    ), '[]'::jsonb),
    'active_collaborators', coalesce((
      select jsonb_agg(active_row.payload order by active_row.last_seen_at desc)
      from (
        select
          cp.last_seen_at,
          jsonb_build_object(
            'user_id', cp.user_id,
            'display_name', app.get_profile_display_name(cp.user_id),
            'email', pr.email,
            'current_step_key', cp.current_step_key,
            'assignment_step_key', a.assigned_step_key,
            'role_key', r.key,
            'role_name', r.name,
            'scope_code', ds.code,
            'scope_label', ds.label,
            'last_seen_at', cp.last_seen_at,
            'entered_at', cp.entered_at,
            'is_me', cp.user_id = auth.uid()
          ) as payload
        from app.property_collaboration_presence cp
        left join app.property_collaboration_assignments a
          on a.id = cp.assignment_id
        left join app.property_memberships pm
          on pm.id = coalesce(cp.membership_id, a.membership_id)
        left join app.roles r
          on r.id = coalesce(a.role_id, pm.role_id)
        left join app.lookup_domain_scopes ds
          on ds.id = coalesce(a.domain_scope_id, pm.domain_scope_id)
        left join app.profiles pr
          on pr.id = cp.user_id
        where cp.property_id = p_property_id
          and cp.is_active = true
          and cp.exited_at is null
      ) as active_row
    ), '[]'::jsonb),
    'active_locks', coalesce((
      select jsonb_agg(lock_row.payload order by lock_row.step_index)
      from (
        select
          app.get_step_index(ss.step_key) as step_index,
          jsonb_build_object(
            'step_key', ss.step_key,
            'locked_by', ss.locked_by,
            'locked_by_name', app.get_profile_display_name(ss.locked_by),
            'lock_expires_at', ss.lock_expires_at,
            'is_mine', ss.locked_by = auth.uid()
          ) as payload
        from app.property_onboarding_sessions s
        join app.property_onboarding_step_states ss
          on ss.session_id = s.id
         and ss.deleted_at is null
        where s.property_id = p_property_id
          and s.deleted_at is null
          and ss.locked_by is not null
          and (ss.lock_expires_at is null or ss.lock_expires_at > now())
      ) as lock_row
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.get_property_collaboration_summary(
  p_property_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not (
    app.is_property_workspace_owner(p_property_id)
    or app.has_domain_scope(p_property_id, 'FULL_PROPERTY')
  ) then
    raise exception 'Forbidden: requires owner or FULL_PROPERTY access';
  end if;

  return jsonb_build_object(
    'property_id', p_property_id,
    'active_collaborators', coalesce((
      select jsonb_agg(collab_row.payload order by collab_row.last_seen_at desc)
      from (
        select
          cp.last_seen_at,
          jsonb_build_object(
            'user_id', cp.user_id,
            'display_name', app.get_profile_display_name(cp.user_id),
            'email', pr.email,
            'current_step_key', cp.current_step_key,
            'assigned_step_key', a.assigned_step_key,
            'role_key', r.key,
            'role_name', r.name,
            'scope_code', ds.code,
            'scope_label', ds.label,
            'access_mode', a.access_mode,
            'ends_at', a.ends_at,
            'last_seen_at', cp.last_seen_at,
            'is_active', cp.is_active
          ) as payload
        from app.property_collaboration_presence cp
        left join app.property_collaboration_assignments a
          on a.id = cp.assignment_id
        left join app.property_memberships pm
          on pm.id = coalesce(cp.membership_id, a.membership_id)
        left join app.roles r
          on r.id = coalesce(a.role_id, pm.role_id)
        left join app.lookup_domain_scopes ds
          on ds.id = coalesce(a.domain_scope_id, pm.domain_scope_id)
        left join app.profiles pr
          on pr.id = cp.user_id
        where cp.property_id = p_property_id
          and cp.is_active = true
          and cp.exited_at is null
      ) as collab_row
    ), '[]'::jsonb),
    'assignments', coalesce((
      select jsonb_agg(assign_row.payload order by assign_row.starts_at desc)
      from (
        select
          a.starts_at,
          jsonb_build_object(
            'assignment_id', a.id,
            'user_id', pm.user_id,
            'display_name', app.get_profile_display_name(pm.user_id),
            'email', pr.email,
            'role_key', r.key,
            'role_name', r.name,
            'scope_code', ds.code,
            'scope_label', ds.label,
            'assigned_step_key', a.assigned_step_key,
            'status', case
              when a.ends_at is not null and a.ends_at <= now() then 'expired'
              else a.status
            end,
            'access_mode', a.access_mode,
            'starts_at', a.starts_at,
            'ends_at', a.ends_at
          ) as payload
        from app.property_collaboration_assignments a
        join app.property_memberships pm
          on pm.id = a.membership_id
         and pm.deleted_at is null
        left join app.roles r
          on r.id = a.role_id
        left join app.lookup_domain_scopes ds
          on ds.id = a.domain_scope_id
        left join app.profiles pr
          on pr.id = pm.user_id
        where a.property_id = p_property_id
          and a.deleted_at is null
          and a.status <> 'revoked'
      ) as assign_row
    ), '[]'::jsonb),
    'active_locks', coalesce((
      select jsonb_agg(lock_row.payload order by lock_row.step_index)
      from (
        select
          app.get_step_index(ss.step_key) as step_index,
          jsonb_build_object(
            'step_key', ss.step_key,
            'locked_by', ss.locked_by,
            'locked_by_name', app.get_profile_display_name(ss.locked_by),
            'lock_expires_at', ss.lock_expires_at
          ) as payload
        from app.property_onboarding_sessions s
        join app.property_onboarding_step_states ss
          on ss.session_id = s.id
         and ss.deleted_at is null
        where s.property_id = p_property_id
          and s.deleted_at is null
          and ss.locked_by is not null
          and (ss.lock_expires_at is null or ss.lock_expires_at > now())
      ) as lock_row
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_my_collaboration_assignments()
from public;

grant execute on function app.get_my_collaboration_assignments()
to authenticated;

revoke all on function app.get_collaboration_workspace_context(uuid)
from public;

grant execute on function app.get_collaboration_workspace_context(uuid)
to authenticated;

revoke all on function app.get_property_collaboration_summary(uuid)
from public;

grant execute on function app.get_property_collaboration_summary(uuid)
to authenticated;

-- ============================================================================
-- Presence lifecycle and step locking
-- ============================================================================

create or replace function app.release_my_property_step_locks(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  update app.property_onboarding_step_states ss
     set locked_by = null,
         locked_at = null,
         lock_expires_at = null,
         updated_at = now()
    from app.property_onboarding_sessions s
   where s.id = ss.session_id
     and s.property_id = p_property_id
     and s.deleted_at is null
     and ss.deleted_at is null
     and ss.locked_by = auth.uid();
end;
$$;

create or replace function app.acquire_onboarding_step_lock(
  p_property_id uuid,
  p_step_key text,
  p_lock_minutes integer default 15
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_step_key text;
  v_lock_minutes integer;
  v_existing record;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_step_key);
  if v_step_key is null then
    raise exception 'Invalid onboarding step: %', p_step_key;
  end if;

  perform app.assert_can_lock_onboarding_step(p_property_id, v_step_key);

  v_lock_minutes := greatest(1, least(coalesce(p_lock_minutes, 15), 60));

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found';
  end if;

  update app.property_onboarding_step_states
     set locked_by = auth.uid(),
         locked_at = now(),
         lock_expires_at = now() + make_interval(mins => v_lock_minutes),
         status = case
           when status = 'not_started' then 'in_progress'
           else status
         end,
         updated_at = now()
   where session_id = v_session_id
     and step_key = v_step_key
     and deleted_at is null
     and (
       locked_by is null
       or locked_by = auth.uid()
       or lock_expires_at is null
       or lock_expires_at <= now()
     );

  if found then
    return jsonb_build_object(
      'acquired', true,
      'step_key', v_step_key,
      'locked_by', auth.uid(),
      'locked_by_name', app.get_profile_display_name(auth.uid()),
      'lock_expires_at', now() + make_interval(mins => v_lock_minutes)
    );
  end if;

  select
    ss.locked_by,
    ss.lock_expires_at
    into v_existing
  from app.property_onboarding_sessions s
  join app.property_onboarding_step_states ss
    on ss.session_id = s.id
   and ss.deleted_at is null
  where s.property_id = p_property_id
    and s.deleted_at is null
    and ss.step_key = v_step_key
  limit 1;

  return jsonb_build_object(
    'acquired', false,
    'step_key', v_step_key,
    'locked_by', v_existing.locked_by,
    'locked_by_name', case
      when v_existing.locked_by is not null then app.get_profile_display_name(v_existing.locked_by)
      else null
    end,
    'lock_expires_at', v_existing.lock_expires_at
  );
end;
$$;

create or replace function app.release_onboarding_step_lock(
  p_property_id uuid,
  p_step_key text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_step_key text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_step_key);
  if v_step_key is null then
    raise exception 'Invalid onboarding step: %', p_step_key;
  end if;

  update app.property_onboarding_step_states ss
     set locked_by = null,
         locked_at = null,
         lock_expires_at = null,
         updated_at = now()
    from app.property_onboarding_sessions s
   where s.id = ss.session_id
     and s.property_id = p_property_id
     and s.deleted_at is null
     and ss.step_key = v_step_key
     and ss.deleted_at is null
     and ss.locked_by = auth.uid();
end;
$$;

create or replace function app.force_acquire_onboarding_step_lock(
  p_property_id uuid,
  p_step_key text,
  p_lock_minutes integer default 15
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_step_key text;
  v_lock_minutes integer;
  v_previous_locked_by uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not (
    app.is_property_workspace_owner(p_property_id)
    or app.has_domain_scope(p_property_id, 'FULL_PROPERTY')
  ) then
    raise exception 'Forbidden: requires owner or FULL_PROPERTY access';
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_step_key);
  if v_step_key is null then
    raise exception 'Invalid onboarding step: %', p_step_key;
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  v_lock_minutes := greatest(1, least(coalesce(p_lock_minutes, 15), 60));

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found';
  end if;

  select ss.locked_by
    into v_previous_locked_by
  from app.property_onboarding_step_states ss
  where ss.session_id = v_session_id
    and ss.step_key = v_step_key
    and ss.deleted_at is null
  limit 1;

  update app.property_onboarding_step_states
     set locked_by = auth.uid(),
         locked_at = now(),
         lock_expires_at = now() + make_interval(mins => v_lock_minutes),
         status = case
           when status = 'not_started' then 'in_progress'
           else status
         end,
         updated_at = now()
   where session_id = v_session_id
     and step_key = v_step_key
     and deleted_at is null;

  if v_previous_locked_by is not null and v_previous_locked_by <> auth.uid() then
    update app.property_collaboration_presence
       set current_step_key = null,
           metadata = coalesce(metadata, '{}'::jsonb)
             || jsonb_build_object(
               'paused_step_key', v_step_key,
               'paused_at', now(),
               'paused_by', auth.uid()
             ),
           updated_at = now()
     where property_id = p_property_id
       and user_id = v_previous_locked_by
       and is_active = true
       and exited_at is null
       and current_step_key = v_step_key;
  end if;

  return jsonb_build_object(
    'acquired', true,
    'step_key', v_step_key,
    'locked_by', auth.uid(),
    'locked_by_name', app.get_profile_display_name(auth.uid()),
    'lock_expires_at', now() + make_interval(mins => v_lock_minutes),
    'overrode_existing_lock', v_previous_locked_by is not null and v_previous_locked_by <> auth.uid(),
    'previous_locked_by', v_previous_locked_by,
    'previous_locked_by_name', case
      when v_previous_locked_by is not null and v_previous_locked_by <> auth.uid()
        then app.get_profile_display_name(v_previous_locked_by)
      else null
    end
  );
end;
$$;

create or replace function app.enter_collaboration_workspace(
  p_property_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_assignment record;
  v_current_step_key text;
  v_can_manage boolean;
  v_membership_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_can_manage := app.is_property_workspace_owner(p_property_id)
    or app.has_domain_scope(p_property_id, 'FULL_PROPERTY');

  select
    null::uuid as assignment_id,
    null::uuid as membership_id,
    null::uuid as role_id,
    null::text as role_key,
    null::text as role_name,
    null::uuid as scope_id,
    null::text as scope_code,
    null::text as scope_label,
    null::text as assigned_step_key,
    null::app.invite_access_mode_enum as access_mode,
    null::timestamptz as starts_at,
    null::timestamptz as ends_at,
    null::text as status
  into v_assignment;

  if not v_can_manage then
    select *
      into v_assignment
    from app.get_primary_collaboration_assignment_for_user(p_property_id);

    if v_assignment.assignment_id is null then
      raise exception 'Forbidden: no active collaboration access for this property';
    end if;

    v_membership_id := v_assignment.membership_id;
  else
    select pm.id
      into v_membership_id
    from app.property_memberships pm
    join app.lookup_domain_scopes ds
      on ds.id = pm.domain_scope_id
     and ds.deleted_at is null
    where pm.property_id = p_property_id
      and pm.user_id = auth.uid()
      and pm.status = 'active'
      and pm.deleted_at is null
      and ds.code = 'FULL_PROPERTY'
      and (pm.ends_at is null or pm.ends_at > now())
    order by pm.created_at desc
    limit 1;
  end if;

  select coalesce(
    case
      when not v_can_manage then v_assignment.assigned_step_key
      else null
    end,
    p.current_step_key,
    'identity'
  )
    into v_current_step_key
  from app.properties p
  where p.id = p_property_id
    and p.deleted_at is null
  limit 1;

  if v_current_step_key is null then
    raise exception 'Property not found or deleted';
  end if;

  insert into app.property_collaboration_presence (
    property_id,
    user_id,
    membership_id,
    assignment_id,
    current_step_key,
    is_active,
    entered_at,
    last_seen_at,
    exited_at,
    metadata
  )
  values (
    p_property_id,
    auth.uid(),
    v_membership_id,
    v_assignment.assignment_id,
    v_current_step_key,
    true,
    now(),
    now(),
    null,
    jsonb_build_object('source', 'workspace_enter')
  )
  on conflict (property_id, user_id)
    where is_active = true
      and exited_at is null
  do update set
    membership_id = excluded.membership_id,
    assignment_id = excluded.assignment_id,
    current_step_key = excluded.current_step_key,
    is_active = true,
    entered_at = excluded.entered_at,
    last_seen_at = excluded.last_seen_at,
    exited_at = null,
    metadata = coalesce(app.property_collaboration_presence.metadata, '{}'::jsonb) || excluded.metadata,
    updated_at = now();

  return app.get_collaboration_workspace_context(p_property_id);
end;
$$;

create or replace function app.touch_collaboration_presence(
  p_property_id uuid,
  p_step_key text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_step_key text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_step_key := app.normalize_onboarding_step_key(p_step_key);

  update app.property_collaboration_presence
     set last_seen_at = now(),
         current_step_key = coalesce(v_step_key, current_step_key),
         metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('source', 'heartbeat'),
         updated_at = now()
   where property_id = p_property_id
     and user_id = auth.uid()
     and is_active = true
     and exited_at is null;

  if not found then
    perform app.enter_collaboration_workspace(p_property_id);

    if v_step_key is not null then
      update app.property_collaboration_presence
         set current_step_key = v_step_key,
             updated_at = now()
       where property_id = p_property_id
         and user_id = auth.uid()
         and is_active = true
         and exited_at is null;
    end if;
  end if;
end;
$$;

create or replace function app.exit_collaboration_workspace(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update app.property_collaboration_presence
     set is_active = false,
         last_seen_at = now(),
         exited_at = now(),
         metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('source', 'workspace_exit'),
         updated_at = now()
   where property_id = p_property_id
     and user_id = auth.uid()
     and is_active = true
     and exited_at is null;

  perform app.release_my_property_step_locks(p_property_id);
end;
$$;

revoke all on function app.release_my_property_step_locks(uuid)
from public, authenticated;

revoke all on function app.acquire_onboarding_step_lock(uuid, text, integer)
from public;

grant execute on function app.acquire_onboarding_step_lock(uuid, text, integer)
to authenticated;

revoke all on function app.release_onboarding_step_lock(uuid, text)
from public;

grant execute on function app.release_onboarding_step_lock(uuid, text)
to authenticated;

revoke all on function app.force_acquire_onboarding_step_lock(uuid, text, integer)
from public;

grant execute on function app.force_acquire_onboarding_step_lock(uuid, text, integer)
to authenticated;

revoke all on function app.enter_collaboration_workspace(uuid)
from public;

grant execute on function app.enter_collaboration_workspace(uuid)
to authenticated;

revoke all on function app.touch_collaboration_presence(uuid, text)
from public;

grant execute on function app.touch_collaboration_presence(uuid, text)
to authenticated;

revoke all on function app.exit_collaboration_workspace(uuid)
from public;

grant execute on function app.exit_collaboration_workspace(uuid)
to authenticated;

-- ============================================================================
-- Collaboration maintenance and PCA directory
-- ============================================================================

create or replace function app.expire_temporary_memberships()
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_count integer := 0;
begin
  update app.property_memberships
     set status = 'expired',
         updated_at = now()
   where deleted_at is null
     and status = 'active'
     and ends_at is not null
     and ends_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function app.backfill_collaboration_assignments_from_memberships()
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_row record;
  v_total integer := 0;
begin
  for v_row in
    select
      pm.id as membership_id,
      pm.property_id,
      pm.created_from_invite_id,
      pm.granted_by,
      pm.starts_at,
      pm.ends_at,
      pm.user_id,
      ci.invited_by,
      ci.access_mode,
      ds.code as scope_code,
      coalesce(
        app.normalize_onboarding_step_key(ci.metadata->>'assigned_step_key'),
        app.get_default_assignment_step_for_scope(ds.code)
      ) as assigned_step_key
    from app.property_memberships pm
    join app.lookup_domain_scopes ds
      on ds.id = pm.domain_scope_id
     and ds.deleted_at is null
    left join app.collaboration_invites ci
      on ci.id = pm.created_from_invite_id
    where pm.deleted_at is null
      and pm.status = 'active'
      and not exists (
        select 1
        from app.property_collaboration_assignments a
        where a.membership_id = pm.id
          and a.deleted_at is null
          and a.status = 'active'
      )
  loop
    if v_row.assigned_step_key is not null then
      perform app.upsert_property_collaboration_assignment(
        v_row.property_id,
        v_row.membership_id,
        v_row.created_from_invite_id,
        coalesce(v_row.invited_by, v_row.granted_by, v_row.user_id),
        v_row.assigned_step_key,
        coalesce(
          v_row.access_mode,
          case
            when v_row.ends_at is null then 'permanent'::app.invite_access_mode_enum
            else 'temporary'::app.invite_access_mode_enum
          end
        ),
        v_row.starts_at,
        v_row.ends_at,
        null
      );

      v_total := v_total + 1;
    end if;
  end loop;

  return v_total;
end;
$$;

create or replace function app.expire_collaboration_assignments()
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_count integer := 0;
begin
  update app.property_collaboration_assignments
     set status = 'expired',
         updated_at = now()
   where deleted_at is null
     and status = 'active'
     and ends_at is not null
     and ends_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function app.cleanup_stale_collaboration_presence(
  p_minutes integer default 10
)
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_count integer := 0;
begin
  with stale_presence as (
    update app.property_collaboration_presence cp
       set is_active = false,
           exited_at = coalesce(cp.exited_at, cp.last_seen_at, now()),
           updated_at = now()
     where cp.is_active = true
       and cp.exited_at is null
       and cp.last_seen_at < now() - make_interval(mins => greatest(1, p_minutes))
     returning cp.property_id, cp.user_id
  ),
  released_locks as (
    update app.property_onboarding_step_states ss
       set locked_by = null,
           locked_at = null,
           lock_expires_at = null,
           updated_at = now()
      from app.property_onboarding_sessions s
      join stale_presence sp
        on sp.property_id = s.property_id
     where s.id = ss.session_id
       and s.deleted_at is null
       and ss.deleted_at is null
       and ss.locked_by = sp.user_id
     returning ss.id
  )
  select count(*)
    into v_count
  from stale_presence;

  return v_count;
end;
$$;

create or replace function app.assign_existing_collaborator_to_property(
  p_property_id uuid,
  p_user_email text,
  p_role_key text,
  p_domain_scope_code text,
  p_assigned_step_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_email text := lower(trim(coalesce(p_user_email, '')));
  v_user_id uuid;
  v_role_id uuid;
  v_scope_id uuid;
  v_scope_code text;
  v_membership_id uuid;
  v_assignment_id uuid;
  v_step_key text;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);
  perform app.assert_property_onboarding_open(p_property_id);

  if char_length(v_email) < 3 then
    raise exception 'Invalid user email';
  end if;

  select pr.id
    into v_user_id
  from app.profiles pr
  where lower(trim(coalesce(pr.email, ''))) = v_email
  limit 1;

  if v_user_id is null then
    return jsonb_build_object(
      'user_found', false,
      'invited_email', v_email
    );
  end if;

  v_role_id := app.get_role_id_by_key(p_role_key);
  if v_role_id is null then
    raise exception 'Invalid role key: %', p_role_key;
  end if;

  v_scope_id := app.get_scope_id_by_code(p_domain_scope_code);
  if v_scope_id is null then
    raise exception 'Invalid domain scope: %', p_domain_scope_code;
  end if;

  v_scope_code := upper(coalesce(trim(p_domain_scope_code), ''));
  v_step_key := app.normalize_onboarding_step_key(p_assigned_step_key);

  if v_step_key is null and v_scope_code <> 'FULL_PROPERTY' then
    v_step_key := app.get_default_assignment_step_for_scope(v_scope_code);
  end if;

  if v_step_key is not null and not app.is_scope_allowed_for_step(v_scope_code, v_step_key) then
    raise exception 'Assigned step % is not compatible with scope %', v_step_key, v_scope_code;
  end if;

  insert into app.property_memberships (
    property_id,
    user_id,
    role_id,
    domain_scope_id,
    status,
    starts_at,
    ends_at,
    granted_by
  )
  values (
    p_property_id,
    v_user_id,
    v_role_id,
    v_scope_id,
    'active',
    now(),
    null,
    auth.uid()
  )
  on conflict (property_id, user_id, domain_scope_id)
    where deleted_at is null
      and status = 'active'
  do update set
    role_id = excluded.role_id,
    status = 'active',
    starts_at = now(),
    ends_at = null,
    granted_by = excluded.granted_by,
    deleted_at = null,
    deleted_by = null,
    updated_at = now()
  returning id into v_membership_id;

  if v_step_key is not null then
    v_assignment_id := app.upsert_property_collaboration_assignment(
      p_property_id,
      v_membership_id,
      null,
      auth.uid(),
      v_step_key,
      'permanent',
      now(),
      null,
      null
    );
  end if;

  update app.collaboration_invites
     set status = 'revoked',
         updated_at = now()
   where property_id = p_property_id
     and lower(invited_email) = v_email
     and role_id = v_role_id
     and domain_scope_id = v_scope_id
     and deleted_at is null
     and status in ('pending', 'viewed');

  update app.property_admin_contacts
     set linked_user_id = v_user_id,
         updated_at = now()
   where property_id = p_property_id
     and deleted_at is null
     and lower(coalesce(contact_email, '')) = v_email;

  perform app.touch_property_activity(p_property_id);

  if upper(coalesce(trim(p_role_key), '')) = 'PROPERTY_MANAGER' then
    v_action_id := app.get_audit_action_id_by_code('PCA_SET');
    if v_action_id is not null then
      insert into app.audit_logs (
        property_id,
        actor_user_id,
        action_type_id,
        payload
      )
      values (
        p_property_id,
        auth.uid(),
        v_action_id,
        jsonb_build_object(
          'linked_user_id', v_user_id,
          'contact_email', v_email,
          'provisioning_mode', 'existing_account'
        )
      );
    end if;
  end if;

  return jsonb_build_object(
    'user_found', true,
    'user_id', v_user_id,
    'membership_id', v_membership_id,
    'assignment_id', v_assignment_id,
    'assigned_step_key', v_step_key,
    'access_mode', 'permanent'
  );
end;
$$;

create or replace function app.get_available_pca_accounts(
  p_property_id uuid default null
)
returns table (
  candidate_id text,
  user_id uuid,
  property_id uuid,
  email text,
  display_name text,
  phone text,
  role_key text,
  role_label text,
  scope_code text,
  scope_label text,
  relationship_role_code text,
  status_label text,
  source_label text,
  is_current_property boolean
)
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_property_id is not null then
    perform app.assert_property_full_access(p_property_id);
  end if;

  return query
  with pca_contact_candidates as (
    select
      concat('pac:', pac.property_id::text, ':', pac.linked_user_id::text) as candidate_id,
      pac.linked_user_id as user_id,
      pac.property_id,
      lower(trim(coalesce(pac.contact_email, pr.email, ''))) as email,
      coalesce(
        nullif(trim(pac.contact_name), ''),
        nullif(trim(app.get_profile_display_name(pac.linked_user_id)), ''),
        lower(trim(coalesce(pac.contact_email, pr.email, '')))
      ) as display_name,
      pac.contact_phone as phone,
      'PROPERTY_MANAGER'::text as role_key,
      'Property Manager / PCA'::text as role_label,
      'FULL_PROPERTY'::text as scope_code,
      'Full Property'::text as scope_label,
      rr.code as relationship_role_code,
      case
        when pac.property_id = p_property_id then 'Already active on this property'
        else 'Current PCA account'
      end as status_label,
      case
        when pac.property_id = p_property_id then 'Current property PCA'
        else 'Past accountability PCA'
      end as source_label,
      (pac.property_id = p_property_id) as is_current_property,
      pac.updated_at as sort_at,
      2 as source_rank
    from app.property_admin_contacts pac
    join app.properties p
      on p.id = pac.property_id
     and p.deleted_at is null
    left join app.profiles pr
      on pr.id = pac.linked_user_id
    left join app.lookup_relationship_roles rr
      on rr.id = pac.relationship_role_id
     and rr.deleted_at is null
    where pac.deleted_at is null
      and pac.mode = 'DELEGATED'
      and pac.linked_user_id is not null
      and (
        p.created_by = auth.uid()
        or pac.property_id = p_property_id
      )
  ),
  pca_membership_candidates as (
    select
      concat('membership:', pm.id::text) as candidate_id,
      pm.user_id,
      pm.property_id,
      lower(trim(coalesce(pr.email, ''))) as email,
      coalesce(
        nullif(trim(app.get_profile_display_name(pm.user_id)), ''),
        lower(trim(coalesce(pr.email, '')))
      ) as display_name,
      null::text as phone,
      r.key as role_key,
      coalesce(r.name, r.key) as role_label,
      ds.code as scope_code,
      coalesce(ds.label, ds.code) as scope_label,
      null::text as relationship_role_code,
      case
        when pm.property_id = p_property_id then 'Already active on this property'
        else 'Current PCA account'
      end as status_label,
      case
        when pm.property_id = p_property_id then 'Current property membership'
        else 'Existing PCA account'
      end as source_label,
      (pm.property_id = p_property_id) as is_current_property,
      coalesce(pm.updated_at, pm.created_at) as sort_at,
      1 as source_rank
    from app.property_memberships pm
    join app.roles r
      on r.id = pm.role_id
     and r.deleted_at is null
    join app.lookup_domain_scopes ds
      on ds.id = pm.domain_scope_id
     and ds.deleted_at is null
    join app.properties p
      on p.id = pm.property_id
     and p.deleted_at is null
    left join app.profiles pr
      on pr.id = pm.user_id
    where pm.deleted_at is null
      and pm.status = 'active'
      and pm.user_id <> auth.uid()
      and upper(coalesce(r.key, '')) = 'PROPERTY_MANAGER'
      and (
        pm.granted_by = auth.uid()
        or p.created_by = auth.uid()
        or pm.property_id = p_property_id
      )
  ),
  ranked_candidates as (
    select
      source.candidate_id,
      source.user_id,
      source.property_id,
      source.email,
      source.display_name,
      source.phone,
      source.role_key,
      source.role_label,
      source.scope_code,
      source.scope_label,
      source.relationship_role_code,
      source.status_label,
      source.source_label,
      source.is_current_property,
      row_number() over (
        partition by coalesce(source.user_id::text, source.email)
        order by source.is_current_property desc, source.source_rank desc, source.sort_at desc
      ) as rn
    from (
      select * from pca_contact_candidates
      union all
      select * from pca_membership_candidates
    ) source
    where source.email is not null
      and char_length(trim(source.email)) >= 3
  )
  select
    rc.candidate_id,
    rc.user_id,
    rc.property_id,
    rc.email,
    rc.display_name,
    rc.phone,
    rc.role_key,
    rc.role_label,
    rc.scope_code,
    rc.scope_label,
    rc.relationship_role_code,
    rc.status_label,
    rc.source_label,
    rc.is_current_property
  from ranked_candidates rc
  where rc.rn = 1
  order by rc.is_current_property desc, rc.display_name asc, rc.email asc;
end;
$$;

revoke all on function app.expire_temporary_memberships()
from public;

revoke all on function app.backfill_collaboration_assignments_from_memberships()
from public;

revoke all on function app.expire_collaboration_assignments()
from public;

revoke all on function app.cleanup_stale_collaboration_presence(integer)
from public;

grant execute on function app.expire_temporary_memberships()
to service_role;

grant execute on function app.backfill_collaboration_assignments_from_memberships()
to service_role;

grant execute on function app.expire_collaboration_assignments()
to service_role;

grant execute on function app.cleanup_stale_collaboration_presence(integer)
to service_role;

revoke all on function app.assign_existing_collaborator_to_property(
  uuid, text, text, text, text
)
from public;

grant execute on function app.assign_existing_collaborator_to_property(
  uuid, text, text, text, text
)
to authenticated;

revoke all on function app.get_available_pca_accounts(uuid)
from public;

grant execute on function app.get_available_pca_accounts(uuid)
to authenticated;

-- ============================================================================
-- Collaboration-aware overrides of onboarding workflow RPCs
-- ============================================================================

create or replace function app.update_property_identity(
  p_property_id uuid,
  p_internal_ref_code text default null,
  p_city_town text default null,
  p_area_neighborhood text default null,
  p_address_description text default null,
  p_map_source_code text default null,
  p_place_id text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_map_label text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_map_source_id uuid;
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'identity');
  perform app.assert_property_onboarding_open(p_property_id);

  if p_map_source_code is not null and char_length(trim(p_map_source_code)) > 0 then
    v_map_source_id := app.get_map_source_id_by_code(trim(p_map_source_code));

    if v_map_source_id is null then
      raise exception 'Invalid map source code: %', p_map_source_code;
    end if;
  end if;

  update app.properties
     set internal_ref_code = nullif(trim(p_internal_ref_code), ''),
         city_town = nullif(trim(p_city_town), ''),
         area_neighborhood = nullif(trim(p_area_neighborhood), ''),
         address_description = nullif(trim(p_address_description), ''),
         map_source_id = v_map_source_id,
         place_id = nullif(trim(p_place_id), ''),
         latitude = p_latitude,
         longitude = p_longitude,
         map_label = nullif(trim(p_map_label), ''),
         identity_completed_at = now(),
         current_step_key = 'usage',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or deleted';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = auth.uid(),
         completed_at = coalesce(completed_at, now()),
         data_snapshot = jsonb_build_object(
           'internalRefCode', nullif(trim(p_internal_ref_code), ''),
           'cityTown', nullif(trim(p_city_town), ''),
           'areaNeighborhood', nullif(trim(p_area_neighborhood), ''),
           'addressDescription', nullif(trim(p_address_description), ''),
           'mapSourceCode', nullif(trim(p_map_source_code), ''),
           'placeId', nullif(trim(p_place_id), ''),
           'latitude', p_latitude,
           'longitude', p_longitude,
           'mapLabel', nullif(trim(p_map_label), '')
         ),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'identity'
     and deleted_at is null;

  update app.property_onboarding_sessions
     set current_step_key = 'usage',
         last_activity_at = now()
   where id = v_session_id
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'usage'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'identity',
        'next_step', 'usage'
      )
    );
  end if;
end;
$$;

create or replace function app.update_property_usage(
  p_property_id uuid,
  p_usage_type_code text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_usage_type_id uuid;
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'usage');
  perform app.assert_property_onboarding_open(p_property_id);

  if p_usage_type_code is null or char_length(trim(p_usage_type_code)) = 0 then
    raise exception 'usage_type_code is required';
  end if;

  v_usage_type_id := app.get_usage_type_id_by_code(trim(p_usage_type_code));

  if v_usage_type_id is null then
    raise exception 'Invalid usage type code: %', p_usage_type_code;
  end if;

  update app.properties
     set usage_type_id = v_usage_type_id,
         current_step_key = 'structure',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or deleted';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'structure',
         last_activity_at = now()
   where id = v_session_id
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = auth.uid(),
         completed_at = coalesce(completed_at, now()),
         data_snapshot = jsonb_build_object(
           'usageTypeCode', trim(p_usage_type_code)
         ),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'usage'
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'structure'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'usage',
        'usage_type_code', trim(p_usage_type_code),
        'next_step', 'structure'
      )
    );
  end if;
end;
$$;

create or replace function app.create_unit(
  p_property_id uuid,
  p_label text default null,
  p_floor text default null,
  p_block text default null,
  p_preset_code text default null,
  p_home_type_code text default null,
  p_bedrooms integer default 0,
  p_bathrooms integer default 0,
  p_parking integer default 0,
  p_balconies integer default 0,
  p_lift_access_code text default null,
  p_garage_slots integer default 0,
  p_waste_disposal_code text default null,
  p_layout_code text default null,
  p_expected_rate numeric default null,
  p_notes text default null,
  p_water_meter_no text default null,
  p_electricity_meter_no text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_id uuid;
  v_preset_id uuid;
  v_home_type_id uuid;
  v_lift_access_type_id uuid;
  v_waste_disposal_type_id uuid;
  v_layout_type_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'structure');
  perform app.assert_property_onboarding_open(p_property_id);

  if p_preset_code is not null and char_length(trim(p_preset_code)) > 0 then
    v_preset_id := app.get_unit_preset_id_by_code(trim(p_preset_code));
    if v_preset_id is null then
      raise exception 'Invalid preset code: %', p_preset_code;
    end if;
  end if;

  if p_home_type_code is not null and char_length(trim(p_home_type_code)) > 0 then
    v_home_type_id := app.get_home_type_id_by_code(trim(p_home_type_code));
    if v_home_type_id is null then
      raise exception 'Invalid home type code: %', p_home_type_code;
    end if;
  end if;

  if p_lift_access_code is not null and char_length(trim(p_lift_access_code)) > 0 then
    v_lift_access_type_id := app.get_lift_access_type_id_by_code(trim(p_lift_access_code));
    if v_lift_access_type_id is null then
      raise exception 'Invalid lift access code: %', p_lift_access_code;
    end if;
  end if;

  if p_waste_disposal_code is not null and char_length(trim(p_waste_disposal_code)) > 0 then
    v_waste_disposal_type_id := app.get_waste_disposal_type_id_by_code(trim(p_waste_disposal_code));
    if v_waste_disposal_type_id is null then
      raise exception 'Invalid waste disposal code: %', p_waste_disposal_code;
    end if;
  end if;

  if p_layout_code is not null and char_length(trim(p_layout_code)) > 0 then
    v_layout_type_id := app.get_layout_type_id_by_code(trim(p_layout_code));
    if v_layout_type_id is null then
      raise exception 'Invalid layout code: %', p_layout_code;
    end if;
  end if;

  insert into app.units (
    property_id,
    label,
    floor,
    block,
    preset_id,
    home_type_id,
    bedrooms,
    bathrooms,
    parking,
    balconies,
    lift_access_type_id,
    garage_slots,
    waste_disposal_type_id,
    layout_type_id,
    expected_rate,
    notes,
    water_meter_number,
    electricity_meter_number
  )
  values (
    p_property_id,
    nullif(trim(p_label), ''),
    nullif(trim(p_floor), ''),
    nullif(trim(p_block), ''),
    v_preset_id,
    v_home_type_id,
    greatest(coalesce(p_bedrooms, 0), 0),
    greatest(coalesce(p_bathrooms, 0), 0),
    greatest(coalesce(p_parking, 0), 0),
    greatest(coalesce(p_balconies, 0), 0),
    v_lift_access_type_id,
    greatest(coalesce(p_garage_slots, 0), 0),
    v_waste_disposal_type_id,
    v_layout_type_id,
    p_expected_rate,
    nullif(trim(p_notes), ''),
    nullif(trim(p_water_meter_no), ''),
    nullif(trim(p_electricity_meter_no), '')
  )
  returning id into v_unit_id;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('UNIT_CREATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      unit_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      v_unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'label', nullif(trim(p_label), ''),
        'water_meter_number', nullif(trim(p_water_meter_no), ''),
        'electricity_meter_number', nullif(trim(p_electricity_meter_no), '')
      )
    );
  end if;

  return v_unit_id;
end;
$$;

create or replace function app.update_unit(
  p_unit_id uuid,
  p_label text default null,
  p_floor text default null,
  p_block text default null,
  p_preset_code text default null,
  p_home_type_code text default null,
  p_bedrooms integer default null,
  p_bathrooms integer default null,
  p_parking integer default null,
  p_balconies integer default null,
  p_lift_access_code text default null,
  p_garage_slots integer default null,
  p_waste_disposal_code text default null,
  p_layout_code text default null,
  p_expected_rate numeric default null,
  p_notes text default null,
  p_water_meter_no text default null,
  p_electricity_meter_no text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_preset_id uuid;
  v_home_type_id uuid;
  v_lift_access_type_id uuid;
  v_waste_disposal_type_id uuid;
  v_layout_type_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select u.property_id
    into v_property_id
  from app.units u
  where u.id = p_unit_id
    and u.deleted_at is null;

  if v_property_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  perform app.assert_can_edit_onboarding_step(v_property_id, 'structure');
  perform app.assert_property_onboarding_open(v_property_id);

  if p_preset_code is not null and char_length(trim(p_preset_code)) > 0 then
    v_preset_id := app.get_unit_preset_id_by_code(trim(p_preset_code));
    if v_preset_id is null then
      raise exception 'Invalid preset code: %', p_preset_code;
    end if;
  end if;

  if p_home_type_code is not null and char_length(trim(p_home_type_code)) > 0 then
    v_home_type_id := app.get_home_type_id_by_code(trim(p_home_type_code));
    if v_home_type_id is null then
      raise exception 'Invalid home type code: %', p_home_type_code;
    end if;
  end if;

  if p_lift_access_code is not null and char_length(trim(p_lift_access_code)) > 0 then
    v_lift_access_type_id := app.get_lift_access_type_id_by_code(trim(p_lift_access_code));
    if v_lift_access_type_id is null then
      raise exception 'Invalid lift access code: %', p_lift_access_code;
    end if;
  end if;

  if p_waste_disposal_code is not null and char_length(trim(p_waste_disposal_code)) > 0 then
    v_waste_disposal_type_id := app.get_waste_disposal_type_id_by_code(trim(p_waste_disposal_code));
    if v_waste_disposal_type_id is null then
      raise exception 'Invalid waste disposal code: %', p_waste_disposal_code;
    end if;
  end if;

  if p_layout_code is not null and char_length(trim(p_layout_code)) > 0 then
    v_layout_type_id := app.get_layout_type_id_by_code(trim(p_layout_code));
    if v_layout_type_id is null then
      raise exception 'Invalid layout code: %', p_layout_code;
    end if;
  end if;

  update app.units
     set label = case when p_label is null then label else nullif(trim(p_label), '') end,
         floor = case when p_floor is null then floor else nullif(trim(p_floor), '') end,
         block = case when p_block is null then block else nullif(trim(p_block), '') end,
         preset_id = case
           when p_preset_code is null then preset_id
           when char_length(trim(p_preset_code)) = 0 then null
           else v_preset_id
         end,
         home_type_id = case
           when p_home_type_code is null then home_type_id
           when char_length(trim(p_home_type_code)) = 0 then null
           else v_home_type_id
         end,
         bedrooms = case when p_bedrooms is null then bedrooms else greatest(p_bedrooms, 0) end,
         bathrooms = case when p_bathrooms is null then bathrooms else greatest(p_bathrooms, 0) end,
         parking = case when p_parking is null then parking else greatest(p_parking, 0) end,
         balconies = case when p_balconies is null then balconies else greatest(p_balconies, 0) end,
         lift_access_type_id = case
           when p_lift_access_code is null then lift_access_type_id
           when char_length(trim(p_lift_access_code)) = 0 then null
           else v_lift_access_type_id
         end,
         garage_slots = case when p_garage_slots is null then garage_slots else greatest(p_garage_slots, 0) end,
         waste_disposal_type_id = case
           when p_waste_disposal_code is null then waste_disposal_type_id
           when char_length(trim(p_waste_disposal_code)) = 0 then null
           else v_waste_disposal_type_id
         end,
         layout_type_id = case
           when p_layout_code is null then layout_type_id
           when char_length(trim(p_layout_code)) = 0 then null
           else v_layout_type_id
         end,
         expected_rate = case when p_expected_rate is null then expected_rate else p_expected_rate end,
         notes = case when p_notes is null then notes else nullif(trim(p_notes), '') end,
         water_meter_number = case
           when p_water_meter_no is null then water_meter_number
           else nullif(trim(p_water_meter_no), '')
         end,
         electricity_meter_number = case
           when p_electricity_meter_no is null then electricity_meter_number
           else nullif(trim(p_electricity_meter_no), '')
         end
   where id = p_unit_id
     and deleted_at is null;

  if not found then
    raise exception 'Unit not found or deleted';
  end if;

  perform app.touch_property_activity(v_property_id);

  v_action_id := app.get_audit_action_id_by_code('UNIT_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      unit_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      v_property_id,
      p_unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'action', 'update_unit',
        'label', p_label,
        'water_meter_number', p_water_meter_no,
        'electricity_meter_number', p_electricity_meter_no
      )
    );
  end if;
end;
$$;

create or replace function app.upsert_primary_structure_unit(
  p_property_id uuid,
  p_label text default 'MAIN',
  p_floor text default null,
  p_block text default null,
  p_preset_code text default null,
  p_home_type_code text default null,
  p_bedrooms integer default 0,
  p_bathrooms integer default 0,
  p_parking integer default 0,
  p_balconies integer default 0,
  p_lift_access_code text default null,
  p_garage_slots integer default 0,
  p_waste_disposal_code text default null,
  p_layout_code text default null,
  p_expected_rate numeric default null,
  p_notes text default null,
  p_water_meter_no text default null,
  p_electricity_meter_no text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_type_code text;
  v_existing_unit_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'structure');
  perform app.assert_property_onboarding_open(p_property_id);

  select pt.code
    into v_property_type_code
  from app.properties p
  join app.lookup_property_types pt
    on pt.id = p.property_type_id
   and pt.deleted_at is null
  where p.id = p_property_id
    and p.deleted_at is null
  limit 1;

  if v_property_type_code is null then
    raise exception 'Property not found or property type missing';
  end if;

  if v_property_type_code <> 'HOUSE' then
    raise exception 'upsert_primary_structure_unit is only valid for HOUSE properties';
  end if;

  select u.id
    into v_existing_unit_id
  from app.units u
  where u.property_id = p_property_id
    and u.deleted_at is null
  order by u.created_at asc
  limit 1;

  if v_existing_unit_id is null then
    return app.create_unit(
      p_property_id,
      coalesce(nullif(trim(p_label), ''), 'MAIN'),
      p_floor,
      p_block,
      p_preset_code,
      p_home_type_code,
      p_bedrooms,
      p_bathrooms,
      p_parking,
      p_balconies,
      p_lift_access_code,
      p_garage_slots,
      p_waste_disposal_code,
      p_layout_code,
      p_expected_rate,
      p_notes,
      p_water_meter_no,
      p_electricity_meter_no
    );
  end if;

  perform app.update_unit(
    v_existing_unit_id,
    coalesce(nullif(trim(p_label), ''), 'MAIN'),
    p_floor,
    p_block,
    p_preset_code,
    p_home_type_code,
    p_bedrooms,
    p_bathrooms,
    p_parking,
    p_balconies,
    p_lift_access_code,
    p_garage_slots,
    p_waste_disposal_code,
    p_layout_code,
    p_expected_rate,
    p_notes,
    p_water_meter_no,
    p_electricity_meter_no
  );

  return v_existing_unit_id;
end;
$$;

create or replace function app.complete_structure_step(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_type_code text;
  v_unit_count integer;
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'structure');
  perform app.assert_property_onboarding_open(p_property_id);

  select pt.code
    into v_property_type_code
  from app.properties p
  join app.lookup_property_types pt
    on pt.id = p.property_type_id
   and pt.deleted_at is null
  where p.id = p_property_id
    and p.deleted_at is null
  limit 1;

  if v_property_type_code is null then
    raise exception 'Property not found or property type missing';
  end if;

  select count(*)
    into v_unit_count
  from app.units u
  where u.property_id = p_property_id
    and u.deleted_at is null;

  if v_property_type_code in ('APARTMENT', 'HOUSE') and coalesce(v_unit_count, 0) < 1 then
    raise exception 'Add at least 1 structure unit before completing the Structure step';
  end if;

  update app.properties
     set current_step_key = 'ownership',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or deleted';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = auth.uid(),
         completed_at = coalesce(completed_at, now()),
         data_snapshot = jsonb_build_object(
           'unitCount', v_unit_count
         ),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'structure'
     and deleted_at is null;

  update app.property_onboarding_sessions
     set current_step_key = 'ownership',
         last_activity_at = now()
   where id = v_session_id
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'ownership'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'structure',
        'next_step', 'ownership',
        'unit_count', v_unit_count
      )
    );
  end if;
end;
$$;

create or replace function app.create_property_document(
  p_property_id uuid,
  p_document_type_code text,
  p_storage_path text,
  p_file_name text default null,
  p_mime_type text default null,
  p_size_bytes bigint default null,
  p_unit_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_document_id uuid;
  v_document_type_id uuid;
  v_session_id uuid;
  v_action_id uuid;
  v_now timestamptz := now();
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'ownership');
  perform app.assert_property_onboarding_open(p_property_id);

  if p_document_type_code is null or char_length(trim(p_document_type_code)) = 0 then
    raise exception 'document_type_code is required';
  end if;

  if p_storage_path is null or char_length(trim(p_storage_path)) < 5 then
    raise exception 'storage_path is required';
  end if;

  if not public.is_valid_property_path(trim(p_storage_path), p_property_id) then
    raise exception 'storage_path must begin with the property_id folder';
  end if;

  v_document_type_id := app.get_document_type_id_by_code(trim(p_document_type_code));

  if v_document_type_id is null then
    raise exception 'Invalid document type code: %', p_document_type_code;
  end if;

  if p_unit_id is not null then
    if not exists (
      select 1
      from app.units u
      where u.id = p_unit_id
        and u.property_id = p_property_id
        and u.deleted_at is null
    ) then
      raise exception 'Invalid unit_id for this property';
    end if;
  end if;

  insert into app.property_documents (
    property_id,
    unit_id,
    document_type_id,
    storage_path,
    file_name,
    mime_type,
    size_bytes,
    uploaded_by
  )
  values (
    p_property_id,
    p_unit_id,
    v_document_type_id,
    trim(p_storage_path),
    nullif(trim(p_file_name), ''),
    nullif(trim(p_mime_type), ''),
    p_size_bytes,
    auth.uid()
  )
  returning id into v_document_id;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = coalesce(completed_by, auth.uid()),
         completed_at = coalesce(completed_at, v_now),
         data_snapshot = case
           when coalesce(data_snapshot, '{}'::jsonb) = '{}'::jsonb then
             jsonb_build_object(
               'first_document_id', v_document_id,
               'last_document_id', v_document_id,
               'at', v_now
             )
           else
             data_snapshot || jsonb_build_object(
               'last_document_id', v_document_id,
               'at', v_now
             )
         end,
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'ownership'
     and deleted_at is null;

  update app.property_onboarding_sessions
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = v_session_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.properties
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = p_property_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'accountability'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('DOC_UPLOADED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'document_id', v_document_id,
        'document_type', trim(p_document_type_code),
        'storage_path', trim(p_storage_path),
        'unit_id', p_unit_id
      )
    );
  end if;

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'ownership',
        'next_step', 'accountability',
        'document_id', v_document_id
      )
    );
  end if;

  return v_document_id;
end;
$$;

create or replace function app.soft_delete_property_document(
  p_document_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select d.property_id
    into v_property_id
  from app.property_documents d
  where d.id = p_document_id
    and d.deleted_at is null;

  if v_property_id is null then
    raise exception 'Document not found or already deleted';
  end if;

  perform app.assert_can_edit_onboarding_step(v_property_id, 'ownership');
  perform app.assert_property_onboarding_open(v_property_id);

  update app.property_documents
     set deleted_at = now(),
         deleted_by = auth.uid()
   where id = p_document_id
     and deleted_at is null;

  if not found then
    raise exception 'Document not found or already deleted';
  end if;

  perform app.touch_property_activity(v_property_id);

  v_action_id := app.get_audit_action_id_by_code('DOCUMENT_DELETED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      v_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'document_id', p_document_id,
        'reason', nullif(trim(p_reason), '')
      )
    );
  end if;
end;
$$;

create or replace function app.complete_ownership_step(
  p_property_id uuid,
  p_snapshot jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_now timestamptz := now();
  v_step_rows integer := 0;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'ownership');
  perform app.assert_property_onboarding_open(p_property_id);

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = coalesce(completed_by, auth.uid()),
         completed_at = coalesce(completed_at, v_now),
         data_snapshot = coalesce(p_snapshot, '{}'::jsonb),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'ownership'
     and deleted_at is null;

  get diagnostics v_step_rows = row_count;
  if v_step_rows = 0 then
    raise exception 'Ownership step state not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = v_session_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.properties
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = p_property_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'accountability'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'ownership',
        'next_step', 'accountability'
      )
    );
  end if;
end;
$$;

create or replace function app.upsert_property_admin_contact(
  p_property_id uuid,
  p_mode text default 'SELF',
  p_relationship_role_code text default null,
  p_contact_name text default null,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_notes text default null,
  p_mark_step_completed boolean default true
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_mode text := upper(coalesce(nullif(trim(p_mode), ''), 'SELF'));
  v_relationship_role_id uuid;
  v_contact_name text;
  v_contact_email text;
  v_contact_phone text;
  v_notes text;
  v_session_id uuid;
  v_step_rows integer := 0;
  v_session_rows integer := 0;
  v_property_rows integer := 0;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'accountability');
  perform app.assert_property_onboarding_open(p_property_id);

  if v_mode not in ('SELF', 'DELEGATED') then
    raise exception 'Invalid accountability mode: %', p_mode;
  end if;

  if v_mode = 'DELEGATED' then
    v_contact_name := nullif(trim(p_contact_name), '');
    v_contact_email := nullif(lower(trim(p_contact_email)), '');
    v_contact_phone := nullif(trim(p_contact_phone), '');
    v_notes := nullif(trim(p_notes), '');

    if p_relationship_role_code is not null and char_length(trim(p_relationship_role_code)) > 0 then
      v_relationship_role_id := app.get_relationship_role_id_by_code(trim(p_relationship_role_code));

      if v_relationship_role_id is null then
        raise exception 'Invalid relationship role code: %', p_relationship_role_code;
      end if;
    end if;
  else
    v_relationship_role_id := null;
    v_contact_name := null;
    v_contact_email := null;
    v_contact_phone := null;
    v_notes := null;
  end if;

  insert into app.property_admin_contacts (
    property_id,
    mode,
    relationship_role_id,
    contact_name,
    contact_email,
    contact_phone,
    notes,
    created_by
  )
  values (
    p_property_id,
    v_mode,
    v_relationship_role_id,
    v_contact_name,
    v_contact_email,
    v_contact_phone,
    v_notes,
    auth.uid()
  )
  on conflict (property_id) do update
    set mode = excluded.mode,
        relationship_role_id = excluded.relationship_role_id,
        contact_name = excluded.contact_name,
        contact_email = excluded.contact_email,
        contact_phone = excluded.contact_phone,
        notes = excluded.notes,
        deleted_at = null,
        deleted_by = null,
        linked_user_id = case
          when excluded.mode = 'SELF' then null
          else property_admin_contacts.linked_user_id
        end;

  perform app.touch_property_activity(p_property_id);

  if coalesce(p_mark_step_completed, true) then
    select s.id
      into v_session_id
    from app.property_onboarding_sessions s
    where s.property_id = p_property_id
      and s.deleted_at is null
    limit 1;

    if v_session_id is null then
      raise exception 'Onboarding session not found for property %', p_property_id;
    end if;

    update app.property_onboarding_step_states
       set status = 'completed',
           completed_by = auth.uid(),
           completed_at = coalesce(completed_at, now()),
           data_snapshot = jsonb_build_object(
             'mode', v_mode,
             'relationshipRoleCode', nullif(trim(p_relationship_role_code), ''),
             'contactName', v_contact_name,
             'contactEmail', v_contact_email,
             'contactPhone', v_contact_phone,
             'notes', v_notes
           ),
           locked_by = null,
           locked_at = null,
           lock_expires_at = null
     where session_id = v_session_id
       and step_key = 'accountability'
       and deleted_at is null;

    get diagnostics v_step_rows = row_count;
    if v_step_rows = 0 then
      raise exception 'Accountability step state not found for property %', p_property_id;
    end if;

    update app.property_onboarding_sessions
       set current_step_key = 'review',
           last_activity_at = now()
     where id = v_session_id
       and deleted_at is null
       and current_step_key <> 'done';

    get diagnostics v_session_rows = row_count;
    if v_session_rows = 0 then
      raise exception 'Onboarding session could not advance to review for property %', p_property_id;
    end if;

    update app.properties
       set current_step_key = 'review',
           last_activity_at = now()
     where id = p_property_id
       and deleted_at is null
       and current_step_key <> 'done';

    get diagnostics v_property_rows = row_count;
    if v_property_rows = 0 then
      raise exception 'Property could not advance to review for property %', p_property_id;
    end if;

    update app.property_onboarding_step_states
       set status = 'in_progress'
     where session_id = v_session_id
       and step_key = 'review'
       and status = 'not_started'
       and deleted_at is null;
  end if;

  v_action_id := app.get_audit_action_id_by_code('PCA_SET');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'mode', v_mode,
        'relationshipRoleCode', nullif(trim(p_relationship_role_code), ''),
        'contactEmail', v_contact_email
      )
    );
  end if;

  if coalesce(p_mark_step_completed, true) then
    v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
    if v_action_id is not null then
      insert into app.audit_logs (
        property_id,
        actor_user_id,
        action_type_id,
        payload
      )
      values (
        p_property_id,
        auth.uid(),
        v_action_id,
        jsonb_build_object(
          'step', 'accountability',
          'next_step', 'review'
        )
      );
    end if;
  end if;
end;
$$;

create or replace function app.link_pca_to_user(
  p_property_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_user_id is null then
    raise exception 'user_id is required';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'accountability');
  perform app.assert_property_onboarding_open(p_property_id);

  update app.property_admin_contacts
     set linked_user_id = p_user_id
   where property_id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'PCA record not found for property';
  end if;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('PCA_SET');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'linked_user_id', p_user_id
      )
    );
  end if;
end;
$$;

create or replace function app.complete_accountability_step(
  p_property_id uuid,
  p_snapshot jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_now timestamptz := now();
  v_step_rows integer := 0;
  v_session_rows integer := 0;
  v_property_rows integer := 0;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_can_edit_onboarding_step(p_property_id, 'accountability');
  perform app.assert_property_onboarding_open(p_property_id);

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = coalesce(completed_by, auth.uid()),
         completed_at = coalesce(completed_at, v_now),
         data_snapshot = coalesce(p_snapshot, '{}'::jsonb),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'accountability'
     and deleted_at is null;

  get diagnostics v_step_rows = row_count;
  if v_step_rows = 0 then
    raise exception 'Accountability step state not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'review',
         last_activity_at = v_now
   where id = v_session_id
     and deleted_at is null
     and current_step_key <> 'done';

  get diagnostics v_session_rows = row_count;
  if v_session_rows = 0 then
    raise exception 'Onboarding session could not advance to review for property %', p_property_id;
  end if;

  update app.properties
     set current_step_key = 'review',
         last_activity_at = v_now
   where id = p_property_id
     and deleted_at is null
     and current_step_key <> 'done';

  get diagnostics v_property_rows = row_count;
  if v_property_rows = 0 then
    raise exception 'Property could not advance to review for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'review'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'accountability',
        'next_step', 'review'
      )
    );
  end if;
end;
$$;
