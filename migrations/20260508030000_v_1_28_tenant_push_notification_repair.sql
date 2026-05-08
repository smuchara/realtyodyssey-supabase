-- ============================================================================
-- V 1 28: Tenant push notification repair
-- ============================================================================
-- Production had v1.27 marked as applied before the push-token and
-- status-update pieces were present. This migration installs those missing
-- objects idempotently without replaying the already-recorded migration.
-- ============================================================================

create schema if not exists app;

alter table app.tenant_notifications
  add column if not exists event_key text not null default 'default';

alter table app.tenant_notifications
  drop constraint if exists tenant_notifications_type_check;

alter table app.tenant_notifications
  add constraint tenant_notifications_type_check
  check (
    type in (
      'maintenance_status_update',
      'maintenance_completion_review',
      'maintenance_delay_checkin'
    )
  );

alter table app.tenant_notifications
  drop constraint if exists uq_tenant_notifications_maintenance_prompt;

create unique index if not exists uq_tenant_notifications_maintenance_event
  on app.tenant_notifications (tenant_user_id, ticket_id, type, event_key);

create table if not exists app.tenant_push_tokens (
  id             uuid primary key default gen_random_uuid(),
  tenant_user_id uuid not null references auth.users(id) on delete cascade,
  platform       text not null check (platform in ('android', 'ios')),
  token          text not null unique,
  is_active      boolean not null default true,
  last_seen_at   timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

drop trigger if exists trg_tenant_push_tokens_updated_at
  on app.tenant_push_tokens;
create trigger trg_tenant_push_tokens_updated_at
  before update on app.tenant_push_tokens
  for each row execute function app.set_updated_at();

create index if not exists idx_tenant_push_tokens_user_active
  on app.tenant_push_tokens (tenant_user_id, is_active);

create table if not exists app.tenant_push_deliveries (
  id              uuid primary key default gen_random_uuid(),
  notification_id uuid not null unique
                    references app.tenant_notifications(id) on delete cascade,
  tenant_user_id  uuid not null references auth.users(id) on delete cascade,
  status          text not null default 'pending'
                    check (status in ('pending', 'sent', 'failed', 'skipped')),
  attempts        integer not null default 0,
  last_error      text,
  sent_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

drop trigger if exists trg_tenant_push_deliveries_updated_at
  on app.tenant_push_deliveries;
create trigger trg_tenant_push_deliveries_updated_at
  before update on app.tenant_push_deliveries
  for each row execute function app.set_updated_at();

create index if not exists idx_tenant_push_deliveries_status
  on app.tenant_push_deliveries (status, created_at);
create index if not exists idx_tenant_push_deliveries_tenant
  on app.tenant_push_deliveries (tenant_user_id, created_at desc);

alter table app.tenant_push_tokens enable row level security;
alter table app.tenant_push_deliveries enable row level security;

drop policy if exists "tenant_push_tokens_select" on app.tenant_push_tokens;
create policy "tenant_push_tokens_select"
  on app.tenant_push_tokens for select to authenticated
  using (tenant_user_id = auth.uid());

drop policy if exists "tenant_push_tokens_insert" on app.tenant_push_tokens;
create policy "tenant_push_tokens_insert"
  on app.tenant_push_tokens for insert to authenticated
  with check (tenant_user_id = auth.uid());

drop policy if exists "tenant_push_tokens_update" on app.tenant_push_tokens;
create policy "tenant_push_tokens_update"
  on app.tenant_push_tokens for update to authenticated
  using (tenant_user_id = auth.uid())
  with check (tenant_user_id = auth.uid());

drop policy if exists "tenant_push_deliveries_select"
  on app.tenant_push_deliveries;
create policy "tenant_push_deliveries_select"
  on app.tenant_push_deliveries for select to authenticated
  using (tenant_user_id = auth.uid());

grant select, insert, update on app.tenant_push_tokens to authenticated;
grant select on app.tenant_push_deliveries to authenticated;

create or replace function app.register_tenant_push_token(
  p_token text,
  p_platform text
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := nullif(trim(p_token), '');
  v_platform text := lower(nullif(trim(p_platform), ''));
  v_token_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if v_token is null then
    raise exception 'Push token is required' using errcode = 'P0400';
  end if;

  if v_platform not in ('android', 'ios') then
    raise exception 'Unsupported push platform' using errcode = 'P0400';
  end if;

  insert into app.tenant_push_tokens (
    tenant_user_id,
    platform,
    token,
    is_active,
    last_seen_at
  )
  values (
    v_uid,
    v_platform,
    v_token,
    true,
    now()
  )
  on conflict (token) do update
    set tenant_user_id = excluded.tenant_user_id,
        platform = excluded.platform,
        is_active = true,
        last_seen_at = now(),
        updated_at = now()
  returning id into v_token_id;

  return jsonb_build_object('token_id', v_token_id, 'status', 'registered');
end;
$$;

create or replace function app.on_tenant_notification_push_queued()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if new.status = 'pending'
     and new.type in (
       'maintenance_status_update',
       'maintenance_completion_review',
       'maintenance_delay_checkin'
     ) then
    insert into app.tenant_push_deliveries (notification_id, tenant_user_id)
    values (new.id, new.tenant_user_id)
    on conflict (notification_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_tenant_notification_push_queued
  on app.tenant_notifications;
create trigger trg_tenant_notification_push_queued
  after insert on app.tenant_notifications
  for each row execute function app.on_tenant_notification_push_queued();

create or replace function app.enqueue_maintenance_status_update_notification(
  p_ticket_id uuid,
  p_status text,
  p_old_status text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_notification_id uuid;
  v_row record;
  v_title text;
  v_body text;
  v_status_label text;
begin
  select
    t.id as ticket_id,
    t.reference as ticket_reference,
    t.workspace_id,
    t.property_id,
    t.unit_id,
    r.id as request_id,
    r.reference as request_reference,
    r.tenant_user_id,
    r.title as request_title,
    c.label as category,
    a.label as area,
    f.name as fundi_name
  into v_row
  from app.maintenance_tickets t
  join app.maintenance_requests r on r.id = t.request_id
  join app.maintenance_categories c on c.id = r.category_id
  join app.maintenance_areas a on a.id = r.area_id
  left join app.fundi_profiles f on f.id = t.assigned_fundi_id
  where t.id = p_ticket_id;

  if not found then
    return null;
  end if;

  v_status_label := case p_status
    when 'assigned' then 'Assigned'
    when 'in_progress' then 'In progress'
    when 'approval_needed' then 'Waiting for approval'
    when 'blocked' then 'Delayed'
    else initcap(replace(coalesce(p_status, 'updated'), '_', ' '))
  end;

  v_title := case p_status
    when 'assigned' then 'A fundi has been assigned'
    when 'in_progress' then 'Maintenance work has started'
    when 'approval_needed' then 'Your ticket needs approval'
    when 'blocked' then 'Your maintenance ticket is delayed'
    else 'Maintenance status updated'
  end;

  v_body := case p_status
    when 'assigned' then coalesce(v_row.fundi_name, 'A fundi')
      || ' has been assigned to your '
      || lower(v_row.category)
      || ' request.'
    when 'in_progress' then 'Your '
      || lower(v_row.category)
      || ' request is now in progress.'
    when 'approval_needed' then 'Your '
      || lower(v_row.category)
      || ' request is waiting for approval.'
    when 'blocked' then 'Your '
      || lower(v_row.category)
      || ' request has been delayed. Tap to see the latest status.'
    else 'Your maintenance ticket status changed to '
      || lower(v_status_label)
      || '.'
  end;

  insert into app.tenant_notifications (
    tenant_user_id,
    workspace_id,
    property_id,
    unit_id,
    request_id,
    ticket_id,
    type,
    event_key,
    title,
    body,
    deep_link,
    payload
  )
  values (
    v_row.tenant_user_id,
    v_row.workspace_id,
    v_row.property_id,
    v_row.unit_id,
    v_row.request_id,
    v_row.ticket_id,
    'maintenance_status_update',
    coalesce(p_status, 'updated'),
    v_title,
    v_body,
    'maintenance/tracking',
    jsonb_build_object(
      'request_id', v_row.request_id,
      'ticket_id', v_row.ticket_id,
      'request_reference', v_row.request_reference,
      'ticket_reference', v_row.ticket_reference,
      'title', v_row.request_title,
      'category', v_row.category,
      'area', v_row.area,
      'status', p_status,
      'old_status', p_old_status,
      'status_label', v_status_label,
      'fundi_name', v_row.fundi_name
    )
  )
  on conflict (tenant_user_id, ticket_id, type, event_key) do update
    set title = excluded.title,
        body = excluded.body,
        payload = excluded.payload,
        deep_link = excluded.deep_link,
        status = case
          when app.tenant_notifications.status = 'completed' then 'pending'
          else app.tenant_notifications.status
        end,
        updated_at = now()
  returning id into v_notification_id;

  return v_notification_id;
end;
$$;

create or replace function app.on_maintenance_ticket_status_update_prompt()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if new.status is distinct from old.status
     and new.status in ('assigned', 'in_progress', 'approval_needed', 'blocked')
  then
    perform app.enqueue_maintenance_status_update_notification(
      new.id,
      new.status,
      old.status
    );
  elsif new.assigned_fundi_id is not null
     and new.assigned_fundi_id is distinct from old.assigned_fundi_id then
    perform app.enqueue_maintenance_status_update_notification(
      new.id,
      'assigned',
      old.status
    );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_maintenance_ticket_status_update_prompt
  on app.maintenance_tickets;
create trigger trg_maintenance_ticket_status_update_prompt
  after update of status, assigned_fundi_id on app.maintenance_tickets
  for each row execute function
    app.on_maintenance_ticket_status_update_prompt();

create or replace function
  app.enqueue_completed_maintenance_review_notification(
  p_ticket_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_notification_id uuid;
  v_row record;
begin
  select
    t.id as ticket_id,
    t.reference as ticket_reference,
    t.workspace_id,
    t.property_id,
    t.unit_id,
    r.id as request_id,
    r.reference as request_reference,
    r.tenant_user_id,
    r.title,
    c.label as category,
    a.label as area
  into v_row
  from app.maintenance_tickets t
  join app.maintenance_requests r on r.id = t.request_id
  join app.maintenance_categories c on c.id = r.category_id
  join app.maintenance_areas a on a.id = r.area_id
  where t.id = p_ticket_id;

  if not found then
    return null;
  end if;

  insert into app.tenant_notifications (
    tenant_user_id,
    workspace_id,
    property_id,
    unit_id,
    request_id,
    ticket_id,
    type,
    event_key,
    title,
    body,
    deep_link,
    payload
  )
  values (
    v_row.tenant_user_id,
    v_row.workspace_id,
    v_row.property_id,
    v_row.unit_id,
    v_row.request_id,
    v_row.ticket_id,
    'maintenance_completion_review',
    'default',
    'Rate your maintenance service',
    'Your ' || lower(v_row.category) || ' ticket has been marked completed.',
    'maintenance/review',
    jsonb_build_object(
      'request_id', v_row.request_id,
      'ticket_id', v_row.ticket_id,
      'request_reference', v_row.request_reference,
      'ticket_reference', v_row.ticket_reference,
      'title', v_row.title,
      'category', v_row.category,
      'area', v_row.area
    )
  )
  on conflict (tenant_user_id, ticket_id, type, event_key) do update
    set title = excluded.title,
        body = excluded.body,
        payload = excluded.payload,
        deep_link = excluded.deep_link,
        updated_at = now()
    where app.tenant_notifications.status <> 'completed'
  returning id into v_notification_id;

  if v_notification_id is null then
    select id into v_notification_id
    from app.tenant_notifications
    where tenant_user_id = v_row.tenant_user_id
      and ticket_id = v_row.ticket_id
      and type = 'maintenance_completion_review'
      and event_key = 'default';
  end if;

  return v_notification_id;
end;
$$;

insert into app.tenant_push_deliveries (notification_id, tenant_user_id)
select id, tenant_user_id
from app.tenant_notifications
where status = 'pending'
  and type in (
    'maintenance_status_update',
    'maintenance_completion_review',
    'maintenance_delay_checkin'
  )
on conflict (notification_id) do nothing;

grant execute on function app.register_tenant_push_token(text, text)
  to authenticated;
grant execute on function app.enqueue_maintenance_status_update_notification(
  uuid,
  text,
  text
) to authenticated;
grant execute on function app.enqueue_completed_maintenance_review_notification(
  uuid
) to authenticated;
