-- ============================================================================
-- V 1 18: Maintenance tenant satisfaction
-- ============================================================================
-- Stores tenant-facing maintenance review prompts and feedback:
--   - completion service rating (0-5) and optional comment
--   - two-week delay check-in with resolution status, reasoning, frustration,
--     and postponement context
-- ============================================================================

create schema if not exists app;

create table if not exists app.tenant_notifications (
  id              uuid primary key default gen_random_uuid(),
  tenant_user_id  uuid not null references auth.users(id) on delete cascade,
  workspace_id    uuid not null references app.workspaces(id) on delete cascade,
  property_id     uuid not null references app.properties(id) on delete cascade,
  unit_id         uuid not null references app.units(id) on delete cascade,
  request_id      uuid references app.maintenance_requests(id) on delete cascade,
  ticket_id       uuid references app.maintenance_tickets(id) on delete cascade,
  type            text not null check (
                  type in (
                      'maintenance_status_update',
                      'maintenance_completion_review',
                      'maintenance_delay_checkin'
                    )
                  ),
  event_key       text not null default 'default',
  title           text not null,
  body            text not null,
  deep_link       text,
  payload         jsonb not null default '{}'::jsonb,
  status          text not null default 'pending'
                    check (status in ('pending', 'opened', 'completed', 'dismissed')),
  popup_shown_at  timestamptz,
  opened_at       timestamptz,
  completed_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

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

drop trigger if exists trg_tenant_notifications_updated_at on app.tenant_notifications;
create trigger trg_tenant_notifications_updated_at
  before update on app.tenant_notifications
  for each row execute function app.set_updated_at();

create index if not exists idx_tenant_notifications_tenant_status
  on app.tenant_notifications (tenant_user_id, status, created_at desc);
create index if not exists idx_tenant_notifications_ticket
  on app.tenant_notifications (ticket_id);

create table if not exists app.maintenance_ticket_feedback (
  id                              uuid primary key default gen_random_uuid(),
  ticket_id                       uuid not null references app.maintenance_tickets(id) on delete cascade,
  request_id                      uuid not null references app.maintenance_requests(id) on delete cascade,
  notification_id                 uuid references app.tenant_notifications(id) on delete set null,
  tenant_user_id                  uuid not null references auth.users(id) on delete cascade,
  workspace_id                    uuid not null references app.workspaces(id) on delete cascade,
  property_id                     uuid not null references app.properties(id) on delete cascade,
  unit_id                         uuid not null references app.units(id) on delete cascade,
  feedback_type                   text not null check (
                                    feedback_type in (
                                      'completion_review',
                                      'delay_checkin'
                                    )
                                  ),
  service_rating                  integer check (service_rating between 0 and 5),
  service_comment                 text,
  resolution_status               text check (
                                    resolution_status in (
                                      'resolved',
                                      'unresolved',
                                      'postponed'
                                    )
                                  ),
  delay_reason                    text,
  frustration_rating              integer check (frustration_rating between 1 and 5),
  postponement_mutually_agreed    boolean,
  postponement_context            text,
  submitted_at                    timestamptz not null default now(),
  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now(),
  constraint uq_maintenance_ticket_feedback_type
    unique (ticket_id, tenant_user_id, feedback_type)
);

drop trigger if exists trg_maintenance_ticket_feedback_updated_at on app.maintenance_ticket_feedback;
create trigger trg_maintenance_ticket_feedback_updated_at
  before update on app.maintenance_ticket_feedback
  for each row execute function app.set_updated_at();

create index if not exists idx_maintenance_ticket_feedback_workspace
  on app.maintenance_ticket_feedback (workspace_id, submitted_at desc);
create index if not exists idx_maintenance_ticket_feedback_ticket
  on app.maintenance_ticket_feedback (ticket_id);
create index if not exists idx_maintenance_ticket_feedback_tenant
  on app.maintenance_ticket_feedback (tenant_user_id, submitted_at desc);

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

drop trigger if exists trg_tenant_push_tokens_updated_at on app.tenant_push_tokens;
create trigger trg_tenant_push_tokens_updated_at
  before update on app.tenant_push_tokens
  for each row execute function app.set_updated_at();

create index if not exists idx_tenant_push_tokens_user_active
  on app.tenant_push_tokens (tenant_user_id, is_active);

create table if not exists app.tenant_push_deliveries (
  id              uuid primary key default gen_random_uuid(),
  notification_id uuid not null unique references app.tenant_notifications(id) on delete cascade,
  tenant_user_id  uuid not null references auth.users(id) on delete cascade,
  status          text not null default 'pending'
                    check (status in ('pending', 'sent', 'failed', 'skipped')),
  attempts        integer not null default 0,
  last_error      text,
  sent_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

drop trigger if exists trg_tenant_push_deliveries_updated_at on app.tenant_push_deliveries;
create trigger trg_tenant_push_deliveries_updated_at
  before update on app.tenant_push_deliveries
  for each row execute function app.set_updated_at();

create index if not exists idx_tenant_push_deliveries_status
  on app.tenant_push_deliveries (status, created_at);
create index if not exists idx_tenant_push_deliveries_tenant
  on app.tenant_push_deliveries (tenant_user_id, created_at desc);

alter table app.tenant_notifications enable row level security;
alter table app.maintenance_ticket_feedback enable row level security;
alter table app.tenant_push_tokens enable row level security;
alter table app.tenant_push_deliveries enable row level security;

drop policy if exists "tenant_notifications_select" on app.tenant_notifications;
create policy "tenant_notifications_select"
  on app.tenant_notifications for select to authenticated
  using (
    tenant_user_id = auth.uid()
    or app.is_active_member(workspace_id)
  );

drop policy if exists "tenant_notifications_update" on app.tenant_notifications;
create policy "tenant_notifications_update"
  on app.tenant_notifications for update to authenticated
  using (tenant_user_id = auth.uid())
  with check (tenant_user_id = auth.uid());

drop policy if exists "maintenance_ticket_feedback_select" on app.maintenance_ticket_feedback;
create policy "maintenance_ticket_feedback_select"
  on app.maintenance_ticket_feedback for select to authenticated
  using (
    tenant_user_id = auth.uid()
    or app.is_active_member(workspace_id)
  );

drop policy if exists "maintenance_ticket_feedback_insert" on app.maintenance_ticket_feedback;
create policy "maintenance_ticket_feedback_insert"
  on app.maintenance_ticket_feedback for insert to authenticated
  with check (tenant_user_id = auth.uid());

drop policy if exists "maintenance_ticket_feedback_update" on app.maintenance_ticket_feedback;
create policy "maintenance_ticket_feedback_update"
  on app.maintenance_ticket_feedback for update to authenticated
  using (tenant_user_id = auth.uid())
  with check (tenant_user_id = auth.uid());

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

drop policy if exists "tenant_push_deliveries_select" on app.tenant_push_deliveries;
create policy "tenant_push_deliveries_select"
  on app.tenant_push_deliveries for select to authenticated
  using (tenant_user_id = auth.uid());

grant select, update on app.tenant_notifications to authenticated;
grant select, insert, update on app.maintenance_ticket_feedback to authenticated;
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

drop trigger if exists trg_tenant_notification_push_queued on app.tenant_notifications;
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
  v_event_key text;
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

  v_event_key := coalesce(p_old_status, 'none')
    || '_to_'
    || coalesce(p_status, 'updated')
    || '_'
    || gen_random_uuid()::text;

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
    v_event_key,
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
     and new.status in ('assigned', 'in_progress', 'approval_needed', 'blocked') then
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

drop trigger if exists trg_maintenance_ticket_status_update_prompt on app.maintenance_tickets;
create trigger trg_maintenance_ticket_status_update_prompt
  after update of status, assigned_fundi_id on app.maintenance_tickets
  for each row execute function app.on_maintenance_ticket_status_update_prompt();

create or replace function app.enqueue_completed_maintenance_review_notification(
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

create or replace function app.on_maintenance_ticket_satisfaction_prompt()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if new.status in ('completed', 'verified')
     and old.status not in ('completed', 'verified') then
    perform app.enqueue_completed_maintenance_review_notification(new.id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_maintenance_ticket_satisfaction_prompt on app.maintenance_tickets;
create trigger trg_maintenance_ticket_satisfaction_prompt
  after update of status on app.maintenance_tickets
  for each row execute function app.on_maintenance_ticket_satisfaction_prompt();

create or replace function app.ensure_maintenance_satisfaction_notifications()
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
  v_inserted integer := 0;
  v_ticket_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  for v_ticket_id in
    select t.id
    from app.maintenance_tickets t
    join app.maintenance_requests r on r.id = t.request_id
    where r.tenant_user_id = v_uid
      and t.status in ('completed', 'verified')
      and not exists (
        select 1
        from app.maintenance_ticket_feedback f
        where f.ticket_id = t.id
          and f.tenant_user_id = v_uid
          and f.feedback_type = 'completion_review'
      )
  loop
    perform app.enqueue_completed_maintenance_review_notification(v_ticket_id);
    v_inserted := v_inserted + 1;
  end loop;

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
  select
    r.tenant_user_id,
    t.workspace_id,
    t.property_id,
    t.unit_id,
    r.id,
    t.id,
    'maintenance_delay_checkin',
    'default',
    'Is this issue resolved?',
    'This maintenance ticket has been open for more than two weeks.',
    'maintenance/delay-checkin',
    jsonb_build_object(
      'request_id', r.id,
      'ticket_id', t.id,
      'request_reference', r.reference,
      'ticket_reference', t.reference,
      'title', r.title,
      'days_open', greatest(14, extract(day from now() - t.created_at)::int)
    )
  from app.maintenance_tickets t
  join app.maintenance_requests r on r.id = t.request_id
  where r.tenant_user_id = v_uid
    and t.status not in ('completed', 'verified')
    and t.created_at <= now() - interval '14 days'
    and not exists (
      select 1
      from app.maintenance_ticket_feedback f
      where f.ticket_id = t.id
        and f.tenant_user_id = v_uid
        and f.feedback_type = 'delay_checkin'
    )
  on conflict (tenant_user_id, ticket_id, type, event_key) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

create or replace function app.get_tenant_notifications()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  perform app.ensure_maintenance_satisfaction_notifications();

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          n.id,
          n.type,
          n.title,
          n.body,
          n.status,
          n.deep_link,
          n.payload,
          n.request_id,
          n.ticket_id,
          n.popup_shown_at,
          n.opened_at,
          n.completed_at,
          n.created_at,
          n.updated_at
        from app.tenant_notifications n
        where n.tenant_user_id = v_uid
          and n.status in ('pending', 'opened')
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function app.mark_tenant_notification_opened(
  p_notification_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  update app.tenant_notifications
  set status = case
        when type = 'maintenance_status_update' then 'completed'
        when status = 'pending' then 'opened'
        else status
      end,
      opened_at = coalesce(opened_at, now()),
      completed_at = case
        when type = 'maintenance_status_update' then coalesce(completed_at, now())
        else completed_at
      end
  where id = p_notification_id
    and tenant_user_id = v_uid
    and status in ('pending', 'opened');

  return found;
end;
$$;

create or replace function app.mark_tenant_notification_popup_shown(
  p_notification_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  update app.tenant_notifications
  set popup_shown_at = coalesce(popup_shown_at, now())
  where id = p_notification_id
    and tenant_user_id = v_uid
    and status in ('pending', 'opened');

  return found;
end;
$$;

create or replace function app.submit_maintenance_completion_feedback(
  p_notification_id uuid,
  p_ticket_id uuid,
  p_service_rating integer,
  p_service_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
  v_ticket record;
  v_feedback_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if p_service_rating is null or p_service_rating < 0 or p_service_rating > 5 then
    raise exception 'Service rating must be between 0 and 5' using errcode = 'P0400';
  end if;

  select
    t.id as ticket_id,
    t.request_id,
    t.workspace_id,
    t.property_id,
    t.unit_id,
    r.tenant_user_id
  into v_ticket
  from app.maintenance_tickets t
  join app.maintenance_requests r on r.id = t.request_id
  where t.id = coalesce(
    p_ticket_id,
    (select n.ticket_id from app.tenant_notifications n where n.id = p_notification_id)
  )
    and r.tenant_user_id = v_uid;

  if not found then
    raise exception 'Maintenance ticket not found' using errcode = 'P0404';
  end if;

  insert into app.maintenance_ticket_feedback (
    ticket_id,
    request_id,
    notification_id,
    tenant_user_id,
    workspace_id,
    property_id,
    unit_id,
    feedback_type,
    service_rating,
    service_comment,
    submitted_at
  )
  values (
    v_ticket.ticket_id,
    v_ticket.request_id,
    p_notification_id,
    v_uid,
    v_ticket.workspace_id,
    v_ticket.property_id,
    v_ticket.unit_id,
    'completion_review',
    p_service_rating,
    nullif(trim(p_service_comment), ''),
    now()
  )
  on conflict (ticket_id, tenant_user_id, feedback_type) do update
    set notification_id = excluded.notification_id,
        service_rating = excluded.service_rating,
        service_comment = excluded.service_comment,
        submitted_at = now(),
        updated_at = now()
  returning id into v_feedback_id;

  update app.tenant_notifications
  set status = 'completed',
      completed_at = coalesce(completed_at, now()),
      opened_at = coalesce(opened_at, now())
  where id = p_notification_id
    and tenant_user_id = v_uid;

  update app.maintenance_tickets
  set status = case when status = 'completed' then 'verified' else status end,
      completion_state = 'verified'
  where id = v_ticket.ticket_id
    and status in ('completed', 'verified');

  return jsonb_build_object('feedback_id', v_feedback_id, 'status', 'submitted');
end;
$$;

create or replace function app.submit_maintenance_delay_feedback(
  p_notification_id uuid,
  p_ticket_id uuid,
  p_resolution_status text,
  p_frustration_rating integer,
  p_delay_reason text default null,
  p_postponement_mutually_agreed boolean default null,
  p_postponement_context text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
  v_ticket record;
  v_feedback_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if p_resolution_status not in ('resolved', 'unresolved', 'postponed') then
    raise exception 'Resolution status must be resolved, unresolved, or postponed' using errcode = 'P0400';
  end if;

  if p_frustration_rating is null or p_frustration_rating < 1 or p_frustration_rating > 5 then
    raise exception 'Frustration rating must be between 1 and 5' using errcode = 'P0400';
  end if;

  select
    t.id as ticket_id,
    t.request_id,
    t.workspace_id,
    t.property_id,
    t.unit_id,
    r.tenant_user_id
  into v_ticket
  from app.maintenance_tickets t
  join app.maintenance_requests r on r.id = t.request_id
  where t.id = coalesce(
    p_ticket_id,
    (select n.ticket_id from app.tenant_notifications n where n.id = p_notification_id)
  )
    and r.tenant_user_id = v_uid;

  if not found then
    raise exception 'Maintenance ticket not found' using errcode = 'P0404';
  end if;

  insert into app.maintenance_ticket_feedback (
    ticket_id,
    request_id,
    notification_id,
    tenant_user_id,
    workspace_id,
    property_id,
    unit_id,
    feedback_type,
    resolution_status,
    delay_reason,
    frustration_rating,
    postponement_mutually_agreed,
    postponement_context,
    submitted_at
  )
  values (
    v_ticket.ticket_id,
    v_ticket.request_id,
    p_notification_id,
    v_uid,
    v_ticket.workspace_id,
    v_ticket.property_id,
    v_ticket.unit_id,
    'delay_checkin',
    p_resolution_status,
    nullif(trim(p_delay_reason), ''),
    p_frustration_rating,
    case when p_resolution_status = 'postponed' then p_postponement_mutually_agreed else null end,
    case when p_resolution_status = 'postponed' then nullif(trim(p_postponement_context), '') else null end,
    now()
  )
  on conflict (ticket_id, tenant_user_id, feedback_type) do update
    set notification_id = excluded.notification_id,
        resolution_status = excluded.resolution_status,
        delay_reason = excluded.delay_reason,
        frustration_rating = excluded.frustration_rating,
        postponement_mutually_agreed = excluded.postponement_mutually_agreed,
        postponement_context = excluded.postponement_context,
        submitted_at = now(),
        updated_at = now()
  returning id into v_feedback_id;

  update app.tenant_notifications
  set status = 'completed',
      completed_at = coalesce(completed_at, now()),
      opened_at = coalesce(opened_at, now())
  where id = p_notification_id
    and tenant_user_id = v_uid;

  return jsonb_build_object('feedback_id', v_feedback_id, 'status', 'submitted');
end;
$$;

grant execute on function app.enqueue_completed_maintenance_review_notification(uuid) to authenticated;
grant execute on function app.ensure_maintenance_satisfaction_notifications() to authenticated;
grant execute on function app.enqueue_maintenance_status_update_notification(uuid, text, text) to authenticated;
grant execute on function app.register_tenant_push_token(text, text) to authenticated;
grant execute on function app.get_tenant_notifications() to authenticated;
grant execute on function app.mark_tenant_notification_opened(uuid) to authenticated;
grant execute on function app.mark_tenant_notification_popup_shown(uuid) to authenticated;
grant execute on function app.submit_maintenance_completion_feedback(uuid, uuid, integer, text) to authenticated;
grant execute on function app.submit_maintenance_delay_feedback(uuid, uuid, text, integer, text, boolean, text) to authenticated;

create or replace function app.get_property_oversight_dashboard()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_today             date := current_date;
  v_curr_period_start date := date_trunc('month', v_today)::date;
  v_prev_period_end   date := (v_curr_period_start - interval '1 day')::date;
  v_prev_period_start date := date_trunc('month', v_prev_period_end)::date;
  v_two_ago_end       date := (v_prev_period_start - interval '1 day')::date;
  v_two_ago_start     date := date_trunc('month', v_two_ago_end)::date;
  v_workspace_id uuid;
  v_coll_rate numeric := 0;
  v_coll_rate_prev numeric := 0;
  v_coll_trend numeric := 0;
  v_occ_dashboard jsonb;
  v_occ_rate numeric := 0;
  v_occ_rate_prev numeric := 0;
  v_occ_trend numeric := 0;
  v_total_units int := 0;
  v_occupied_units int := 0;
  v_vacant_units int := 0;
  v_on_time_rate numeric := 0;
  v_maint_resolution_rate numeric := 100;
  v_dispute_free_rate numeric := 100;
  v_proxy_satisfaction_score int := 0;
  v_satisfaction_score int := 0;
  v_feedback_count int := 0;
  v_service_feedback_count int := 0;
  v_delay_feedback_count int := 0;
  v_avg_service_rating numeric;
  v_avg_frustration_rating numeric;
  v_direct_satisfaction_score numeric;
  v_curr_collected numeric := 0;
  v_curr_expected numeric := 0;
  v_curr_overdue numeric := 0;
  v_curr_overdue_units int := 0;
  v_maint_cost_curr numeric := 0;
  v_noi numeric := 0;
  v_risk_pct numeric := 0;
  v_currency text := 'KES';
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select w.id into v_workspace_id
  from app.workspaces w
  where w.owner_user_id = auth.uid()
  limit 1;

  if v_workspace_id is null then
    select wm.workspace_id into v_workspace_id
    from app.workspace_memberships wm
    where wm.user_id = auth.uid()
      and wm.status = 'active'
    order by wm.created_at asc
    limit 1;
  end if;

  select coalesce(round(least(100, sum(rcp.amount_paid)::numeric / nullif(sum(rcp.scheduled_amount), 0) * 100), 1), 0)
  into v_coll_rate
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_prev_period_start and v_prev_period_end;

  select coalesce(round(least(100, sum(rcp.amount_paid)::numeric / nullif(sum(rcp.scheduled_amount), 0) * 100), 1), 0)
  into v_coll_rate_prev
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_two_ago_start and v_two_ago_end;

  v_coll_trend := round(v_coll_rate - v_coll_rate_prev, 0);

  select coalesce(round(sum(rcp.amount_paid), 2), 0),
         coalesce(round(sum(rcp.scheduled_amount), 2), 0),
         coalesce(max(rcp.currency_code), 'KES')
  into v_curr_collected, v_curr_expected, v_currency
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_curr_period_start
      and (v_curr_period_start + interval '1 month - 1 day')::date;

  select coalesce(round(sum(rcp.outstanding_amount), 2), 0),
         count(distinct rcp.unit_id)::int
  into v_curr_overdue, v_curr_overdue_units
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status = 'overdue'
    and rcp.outstanding_amount > 0;

  if v_workspace_id is not null then
    select coalesce(round(sum(t.actual_cost), 2), 0)
    into v_maint_cost_curr
    from app.maintenance_tickets t
    where t.workspace_id = v_workspace_id
      and t.status in ('completed', 'verified')
      and t.actual_cost is not null
      and date_trunc('month', coalesce(t.completed_at, t.updated_at)) = v_curr_period_start;
  end if;

  v_noi := v_curr_collected - v_maint_cost_curr;
  v_risk_pct := case
    when v_curr_expected = 0 then 0
    else round(v_curr_overdue / nullif(v_curr_expected, 0) * 100, 1)
  end;

  select app.get_units_occupancy_dashboard() into v_occ_dashboard;
  v_occ_rate := coalesce((v_occ_dashboard -> 'summary' ->> 'occupancy_rate')::numeric, 0);
  v_total_units := coalesce((v_occ_dashboard -> 'summary' ->> 'total_units')::int, 0);
  v_occupied_units := coalesce((v_occ_dashboard -> 'summary' ->> 'occupied_units')::int, 0);
  v_vacant_units := coalesce((v_occ_dashboard -> 'summary' ->> 'vacant_units')::int, 0);

  select case
           when v_total_units = 0 then 0
           else round(count(distinct rcp.unit_id)::numeric / v_total_units * 100, 1)
         end
  into v_occ_rate_prev
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_prev_period_start and v_prev_period_end;

  v_occ_trend := round(v_occ_rate - v_occ_rate_prev, 0);

  select case
           when count(*) = 0 then 0
           else round(
             count(*) filter (
               where rcp.charge_status = 'paid'
                 and coalesce(rcp.full_collection_delay_days, 0) <= 0
             )::numeric / count(*) * 100,
             1
           )
         end
  into v_on_time_rate
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_prev_period_start and v_prev_period_end;

  if v_workspace_id is not null then
    select case
             when count(*) = 0 then 100
             else round(count(*) filter (where t.status in ('completed', 'verified'))::numeric / count(*) * 100, 1)
           end
    into v_maint_resolution_rate
    from app.maintenance_tickets t
    where t.workspace_id = v_workspace_id;
  end if;

  if v_total_units > 0 then
    select round(
             100 - (
               count(*) filter (where uos.occupancy_status = 'disputed')::numeric
               / v_total_units * 100
             ),
             1
           )
    into v_dispute_free_rate
    from app.unit_occupancy_snapshots uos
    join app.units u on u.id = uos.unit_id
    join app.get_financial_accessible_property_ids() ap on ap.property_id = u.property_id;
  end if;

  v_proxy_satisfaction_score := least(100, greatest(0,
    round(
      coalesce(v_on_time_rate, 0) * 0.40
      + coalesce(v_maint_resolution_rate, 100) * 0.35
      + coalesce(v_dispute_free_rate, 100) * 0.25
    )
  ))::int;

  if v_workspace_id is not null then
    select count(*)::int,
           count(*) filter (where service_rating is not null)::int,
           count(*) filter (where frustration_rating is not null)::int,
           round(avg(service_rating)::numeric, 2),
           round(avg(frustration_rating)::numeric, 2)
    into v_feedback_count,
         v_service_feedback_count,
         v_delay_feedback_count,
         v_avg_service_rating,
         v_avg_frustration_rating
    from app.maintenance_ticket_feedback f
    where f.workspace_id = v_workspace_id;
  end if;

  if v_feedback_count > 0 then
    v_direct_satisfaction_score :=
      case
        when v_avg_service_rating is not null and v_avg_frustration_rating is not null then
          (v_avg_service_rating / 5 * 100 * 0.75)
          + ((6 - v_avg_frustration_rating) / 5 * 100 * 0.25)
        when v_avg_service_rating is not null then
          v_avg_service_rating / 5 * 100
        when v_avg_frustration_rating is not null then
          (6 - v_avg_frustration_rating) / 5 * 100
        else v_proxy_satisfaction_score
      end;

    v_satisfaction_score := least(100, greatest(0,
      round(v_direct_satisfaction_score * 0.70 + v_proxy_satisfaction_score * 0.30)
    ))::int;
  else
    v_satisfaction_score := v_proxy_satisfaction_score;
  end if;

  return jsonb_build_object(
    'collection_efficiency', jsonb_build_object(
      'score', round(v_coll_rate)::int,
      'trend', v_coll_trend::int,
      'trend_label', 'Last month'
    ),
    'occupancy_rate', jsonb_build_object(
      'score', round(v_occ_rate)::int,
      'trend', v_occ_trend::int,
      'trend_label', 'Last month'
    ),
    'tenant_satisfaction', jsonb_build_object(
      'score', v_satisfaction_score,
      'trend', null,
      'trend_label', 'Last quarter',
      'feedback_count', v_feedback_count,
      'service_feedback_count', v_service_feedback_count,
      'delay_feedback_count', v_delay_feedback_count,
      'average_service_rating', v_avg_service_rating,
      'average_frustration_rating', v_avg_frustration_rating
    ),
    'net_operating_income', jsonb_build_object(
      'amount', v_noi,
      'currency_code', v_currency
    ),
    'expected_revenue', jsonb_build_object(
      'amount', v_curr_expected,
      'currency_code', v_currency
    ),
    'revenue_at_risk', jsonb_build_object(
      'amount', v_curr_overdue,
      'percentage', v_risk_pct,
      'units_affected', v_curr_overdue_units,
      'currency_code', v_currency
    ),
    'vacant_units', jsonb_build_object(
      'count', v_vacant_units,
      'total', v_total_units,
      'percentage', case
        when v_total_units = 0 then 0
        else round(v_vacant_units::numeric / v_total_units * 100, 1)
      end
    )
  );
end;
$$;

grant execute on function app.get_property_oversight_dashboard() to authenticated;
