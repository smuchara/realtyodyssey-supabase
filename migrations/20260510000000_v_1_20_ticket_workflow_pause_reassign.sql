-- ============================================================================
-- V 1 20: Ticket Workflow — Pause, Funding Hold, and Reassignment
-- ============================================================================
-- Adds the full pause / reassign lifecycle to maintenance tickets:
--
--   in_progress ──[fundi pauses: other reason]──► reassigning ──[owner assigns]──► assigned
--   in_progress ──[fundi pauses: funding_delay]──► paused ──[owner resolves]──► in_progress
--
-- New tables:
--   ticket_pause_events   — immutable audit record written when fundi pauses
--   ticket_funding_holds  — active hold row while ticket awaits owner funding
--
-- New RPCs:
--   pause_provider_ticket          — fundi action (in_progress → paused|reassigning)
--   resolve_ticket_funding_hold    — owner action (paused → in_progress)
--   reassign_paused_ticket         — owner action (reassigning → assigned)
--
-- Updated:
--   on_maintenance_ticket_updated  — adds paused + reassigning request sync
--   enqueue_maintenance_status_update_notification — new push messages
-- ============================================================================

create schema if not exists app;

-- ─── 1. New operational statuses ─────────────────────────────────────────────

insert into app.maintenance_ticket_statuses (code, label, sort_order) values
  ('paused',       'Paused — Funding Hold',   6),
  ('reassigning',  'Reassigning',             7)
on conflict (code) do update set label = excluded.label, sort_order = excluded.sort_order;

-- ─── 2. Pause reason lookup ───────────────────────────────────────────────────

create table if not exists app.ticket_pause_reasons (
  code       text primary key,
  label      text not null,
  sort_order smallint not null default 0
);

insert into app.ticket_pause_reasons (code, label, sort_order) values
  ('family_emergency',       'Family Emergency',        1),
  ('health_issue',           'Health Issue',            2),
  ('waiting_for_materials',  'Waiting for Materials',   3),
  ('funding_delay',          'Funding Delay',           4)
on conflict (code) do update set label = excluded.label;

-- ─── 3. Pause event log (immutable, one row per pause action) ─────────────────

create table if not exists app.ticket_pause_events (
  id               uuid    primary key default gen_random_uuid(),
  ticket_id        uuid    not null references app.maintenance_tickets(id) on delete cascade,
  fundi_id         uuid    not null references app.fundi_profiles(id) on delete restrict,
  reason_code      text    not null references app.ticket_pause_reasons(code),
  work_note        text    not null,    -- what has been completed
  amount_spent     numeric(12,2),       -- how much has been spent so far
  materials_used   text,                -- materials consumed
  created_at       timestamptz not null default now()
);

create index if not exists idx_ticket_pause_events_ticket
  on app.ticket_pause_events (ticket_id, created_at desc);

alter table app.ticket_pause_events enable row level security;

create policy "ticket_pause_events_select"
  on app.ticket_pause_events for select to authenticated
  using (
    exists (
      select 1 from app.maintenance_tickets t
      where t.id = ticket_id and app.is_active_member(t.workspace_id)
    )
    or fundi_id in (
      select id from app.fundi_profiles where user_id = auth.uid()
    )
  );

grant select, insert on app.ticket_pause_events to authenticated;

-- ─── 4. Funding hold table (one active row per paused-for-funding ticket) ─────

create table if not exists app.ticket_funding_holds (
  id              uuid    primary key default gen_random_uuid(),
  ticket_id       uuid    not null references app.maintenance_tickets(id) on delete cascade,
  pause_event_id  uuid    references app.ticket_pause_events(id) on delete set null,
  amount_needed   numeric(12,2),
  note            text,
  held_at         timestamptz not null default now(),
  resolved_at     timestamptz,
  resolved_by     uuid    references auth.users(id) on delete set null,
  resolution_note text
);

create unique index if not exists uq_ticket_funding_holds_active
  on app.ticket_funding_holds (ticket_id)
  where resolved_at is null;

create index if not exists idx_ticket_funding_holds_ticket
  on app.ticket_funding_holds (ticket_id);

alter table app.ticket_funding_holds enable row level security;

create policy "ticket_funding_holds_select"
  on app.ticket_funding_holds for select to authenticated
  using (
    exists (
      select 1 from app.maintenance_tickets t
      where t.id = ticket_id and app.is_active_member(t.workspace_id)
    )
  );

create policy "ticket_funding_holds_update"
  on app.ticket_funding_holds for update to authenticated
  using (
    exists (
      select 1 from app.maintenance_tickets t
      where t.id = ticket_id and app.is_workspace_admin(t.workspace_id)
    )
  );

grant select, insert, update on app.ticket_funding_holds to authenticated;

-- ─── 5. Update ticket lifecycle trigger ───────────────────────────────────────
-- Extends the existing trigger to sync paused/reassigning → tenant request status.

create or replace function app.on_maintenance_ticket_updated()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  -- Mark when active work started
  if new.status = 'in_progress' and old.status <> 'in_progress' then
    new.started_at := coalesce(old.started_at, now());
  end if;

  -- Resolve completion fields
  if new.status in ('completed', 'verified')
     and old.status not in ('completed', 'verified') then
    new.completed_at      := now();
    new.completion_state  := coalesce(old.completion_state, 'pending_review');
    if new.started_at is not null then
      new.resolution_days :=
        greatest(1, extract(day from (now() - new.started_at))::integer);
    end if;
  end if;

  -- Sync tenant-visible request status
  update app.maintenance_requests
  set
    status = case new.status
      when 'new'             then 'submitted'
      when 'assigned'        then 'specialist_assigned'
      when 'in_progress'     then 'in_progress'
      when 'approval_needed' then 'waiting'
      when 'paused'          then 'waiting'
      when 'reassigning'     then 'under_review'
      when 'blocked'         then 'waiting'
      when 'completed'       then 'completed'
      when 'verified'        then 'completed'
      else 'under_review'
    end,
    resolved_at = case
      when new.status in ('completed', 'verified') then now()
      else null
    end
  where id = new.request_id;

  return new;
end;
$$;

-- ─── 6. RPC: pause_provider_ticket ───────────────────────────────────────────
-- Called by the fundi after confirming the pause modal.
-- funding_delay  → ticket moves to 'paused', funding hold is created.
-- any other reason → ticket moves directly to 'reassigning', fundi is released.

create or replace function app.pause_provider_ticket(
  p_ticket_id       uuid,
  p_reason_code     text,
  p_work_note       text,
  p_amount_spent    numeric  default null,
  p_materials_used  text     default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_profile     app.fundi_profiles;
  v_ticket      app.maintenance_tickets;
  v_pause_id    uuid;
  v_new_status  text;
  v_actor_name  text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Validate reason code
  if not exists (select 1 from app.ticket_pause_reasons where code = p_reason_code) then
    raise exception 'Invalid pause reason: %', p_reason_code using errcode = 'P0400';
  end if;

  -- Require a meaningful note
  if char_length(trim(coalesce(p_work_note, ''))) < 10 then
    raise exception 'Work note must describe what has been completed (min 10 characters)'
      using errcode = 'P0400';
  end if;

  -- Resolve fundi profile
  select * into v_profile
  from app.fundi_profiles
  where user_id = v_user_id
  limit 1;

  if not found then
    raise exception 'Provider profile not found' using errcode = 'P0404';
  end if;

  -- Lock ticket row to prevent concurrent updates
  select * into v_ticket
  from app.maintenance_tickets
  where id = p_ticket_id
    and assigned_fundi_id = v_profile.id
  for update;

  if not found then
    raise exception 'Ticket not assigned to you' using errcode = 'P0403';
  end if;

  if v_ticket.status <> 'in_progress' then
    raise exception 'Only in-progress tickets can be paused (current: %)', v_ticket.status
      using errcode = 'P0400';
  end if;

  v_actor_name := coalesce(v_profile.name, 'Fundi');

  -- Determine where the ticket lands
  v_new_status := case p_reason_code
    when 'funding_delay' then 'paused'
    else                      'reassigning'
  end;

  -- Write the immutable pause event
  insert into app.ticket_pause_events
    (ticket_id, fundi_id, reason_code, work_note, amount_spent, materials_used)
  values
    (p_ticket_id, v_profile.id, p_reason_code,
     trim(p_work_note), p_amount_spent, nullif(trim(coalesce(p_materials_used, '')), ''))
  returning id into v_pause_id;

  -- Update ticket status (trigger fires; syncs request status)
  update app.maintenance_tickets set
    status         = v_new_status,
    -- For non-funding pauses, clear the fundi assignment to signal "open for reassignment"
    assigned_fundi_id = case p_reason_code
      when 'funding_delay' then v_profile.id   -- keep same fundi for funding holds
      else                      null
    end,
    assigned_at    = case p_reason_code
      when 'funding_delay' then v_ticket.assigned_at
      else                      null
    end
  where id = p_ticket_id;

  -- For funding delays: create the hold record
  if p_reason_code = 'funding_delay' then
    insert into app.ticket_funding_holds
      (ticket_id, pause_event_id, amount_needed, note)
    values
      (p_ticket_id, v_pause_id, p_amount_spent, p_work_note);
  end if;

  -- Activity log
  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name, metadata)
  values (
    p_ticket_id,
    case p_reason_code when 'funding_delay' then 'blocked' else 'status_changed' end,
    case p_reason_code
      when 'funding_delay' then 'Work paused — awaiting funding from owner'
      else 'Work paused — ticket moved to reassignment (' || p_reason_code || ')'
    end,
    v_user_id,
    v_actor_name,
    jsonb_build_object(
      'pause_event_id',  v_pause_id,
      'reason_code',     p_reason_code,
      'new_status',      v_new_status,
      'amount_spent',    p_amount_spent,
      'materials_used',  p_materials_used
    )
  );

  -- Enqueue push notification to tenant
  perform app.enqueue_maintenance_status_update_notification(
    p_ticket_id, v_new_status, 'in_progress'
  );

  return jsonb_build_object(
    'pause_event_id', v_pause_id,
    'new_status',     v_new_status
  );
end;
$$;

grant execute on function app.pause_provider_ticket(uuid, text, text, numeric, text)
  to authenticated;

-- ─── 7. RPC: resolve_ticket_funding_hold ─────────────────────────────────────
-- Owner action: resolves the funding hold and returns ticket to in_progress.

create or replace function app.resolve_ticket_funding_hold(
  p_ticket_id      uuid,
  p_resolution_note text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_hold_id      uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select workspace_id into v_workspace_id
  from app.maintenance_tickets where id = p_ticket_id;

  if not app.is_workspace_admin(v_workspace_id) then
    raise exception 'Only workspace admins can resolve funding holds' using errcode = 'P0401';
  end if;

  -- Find the active hold
  select id into v_hold_id
  from app.ticket_funding_holds
  where ticket_id = p_ticket_id and resolved_at is null;

  if not found then
    raise exception 'No active funding hold found for this ticket' using errcode = 'P0404';
  end if;

  -- Resolve the hold
  update app.ticket_funding_holds set
    resolved_at     = now(),
    resolved_by     = auth.uid(),
    resolution_note = nullif(trim(coalesce(p_resolution_note, '')), '')
  where id = v_hold_id;

  -- Return ticket to in_progress (trigger syncs request status)
  update app.maintenance_tickets set status = 'in_progress' where id = p_ticket_id;

  -- Activity log
  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    p_ticket_id, 'status_changed',
    'Funding resolved — work resumed',
    auth.uid(),
    coalesce(
      (select first_name || ' ' || last_name from app.profiles where id = auth.uid()),
      'Owner'
    )
  );

  -- Push notification to tenant
  perform app.enqueue_maintenance_status_update_notification(
    p_ticket_id, 'in_progress', 'paused'
  );
end;
$$;

grant execute on function app.resolve_ticket_funding_hold(uuid, text) to authenticated;

-- ─── 8. RPC: reassign_paused_ticket ──────────────────────────────────────────
-- Owner action: assigns a new fundi to a ticket in 'reassigning' status.

create or replace function app.reassign_paused_ticket(
  p_ticket_id uuid,
  p_fundi_id  uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_old_status   text;
  v_fundi_name   text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select workspace_id, status into v_workspace_id, v_old_status
  from app.maintenance_tickets where id = p_ticket_id;

  if not app.is_workspace_admin(v_workspace_id) then
    raise exception 'Only workspace admins can reassign tickets' using errcode = 'P0401';
  end if;

  if v_old_status <> 'reassigning' then
    raise exception 'Ticket must be in reassigning status to reassign (current: %)', v_old_status
      using errcode = 'P0400';
  end if;

  select name into v_fundi_name from app.fundi_profiles where id = p_fundi_id;

  -- Assign the new fundi (trigger syncs request status → specialist_assigned)
  update app.maintenance_tickets set
    assigned_fundi_id = p_fundi_id,
    assigned_at       = now(),
    status            = 'assigned'
  where id = p_ticket_id;

  -- Activity log
  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    p_ticket_id, 'assigned',
    'Reassigned to ' || coalesce(v_fundi_name, 'new fundi') || ' after pause',
    auth.uid(),
    coalesce(
      (select first_name || ' ' || last_name from app.profiles where id = auth.uid()),
      'Admin'
    )
  );

  -- Push notification to tenant
  perform app.enqueue_maintenance_status_update_notification(
    p_ticket_id, 'assigned', v_old_status
  );
end;
$$;

grant execute on function app.reassign_paused_ticket(uuid, uuid) to authenticated;

-- ─── 9. Update push notification messages for new statuses ───────────────────

create or replace function app.enqueue_maintenance_status_update_notification(
  p_ticket_id  uuid,
  p_status     text,
  p_old_status text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_notification_id uuid;
  v_row             record;
  v_title           text;
  v_body            text;
  v_status_label    text;
  v_event_key       text;
begin
  select
    t.id              as ticket_id,
    t.reference       as ticket_reference,
    t.workspace_id,
    t.property_id,
    t.unit_id,
    r.id              as request_id,
    r.reference       as request_reference,
    r.tenant_user_id,
    r.title           as request_title,
    c.label           as category,
    a.label           as area,
    f.name            as fundi_name
  into v_row
  from app.maintenance_tickets t
  join app.maintenance_requests    r on r.id  = t.request_id
  join app.maintenance_categories  c on c.id  = r.category_id
  join app.maintenance_areas       a on a.id  = r.area_id
  left join app.fundi_profiles     f on f.id  = t.assigned_fundi_id
  where t.id = p_ticket_id;

  if not found then
    return null;
  end if;

  -- Unique key: every transition always inserts a fresh notification row
  v_event_key := coalesce(p_old_status, 'none')
    || '_to_'
    || coalesce(p_status, 'updated')
    || '_'
    || gen_random_uuid()::text;

  v_status_label := case p_status
    when 'assigned'        then 'Specialist Assigned'
    when 'in_progress'     then 'In Progress'
    when 'approval_needed' then 'Waiting for Approval'
    when 'paused'          then 'Work Paused'
    when 'reassigning'     then 'Finding New Specialist'
    when 'blocked'         then 'Delayed'
    when 'completed'       then 'Completed'
    else initcap(replace(coalesce(p_status, 'updated'), '_', ' '))
  end;

  v_title := case p_status
    when 'assigned'        then 'A specialist has been assigned'
    when 'in_progress'     then case p_old_status
                                  when 'paused' then 'Work has resumed on your request'
                                  else 'Maintenance work has started'
                                end
    when 'approval_needed' then 'Your request needs approval'
    when 'paused'          then 'Work has been paused — awaiting funds'
    when 'reassigning'     then 'Finding you a new specialist'
    when 'blocked'         then 'Your maintenance request is delayed'
    when 'completed'       then 'Your maintenance work is complete'
    else 'Maintenance update'
  end;

  v_body := case p_status
    when 'assigned' then
      coalesce(v_row.fundi_name, 'A specialist')
      || ' has been assigned to your '
      || lower(v_row.category) || ' request.'
    when 'in_progress' then case p_old_status
      when 'paused'
        then 'Funding was resolved. Work on your ' || lower(v_row.category) || ' request has resumed.'
      else
        'Your ' || lower(v_row.category) || ' request is now in progress.'
      end
    when 'approval_needed' then
      'Your ' || lower(v_row.category) || ' request is waiting for approval before work can continue.'
    when 'paused' then
      'Work on your ' || lower(v_row.category)
      || ' request is on hold. The owner is reviewing the funding requirement.'
    when 'reassigning' then
      'Your previous specialist is unavailable. We are assigning a new specialist to your '
      || lower(v_row.category) || ' request.'
    when 'blocked' then
      'Your ' || lower(v_row.category) || ' request has been delayed. Tap to see the latest status.'
    when 'completed' then
      'Your ' || lower(v_row.category) || ' request has been completed. Tap to leave a review.'
    else
      'Your maintenance request status changed to ' || lower(v_status_label) || '.'
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
      'request_id',        v_row.request_id,
      'ticket_id',         v_row.ticket_id,
      'request_reference', v_row.request_reference,
      'ticket_reference',  v_row.ticket_reference,
      'title',             v_row.request_title,
      'category',          v_row.category,
      'area',              v_row.area,
      'status',            p_status,
      'old_status',        p_old_status,
      'status_label',      v_status_label,
      'fundi_name',        v_row.fundi_name
    )
  )
  returning id into v_notification_id;

  return v_notification_id;
end;
$$;

grant execute on function app.enqueue_maintenance_status_update_notification(uuid, text, text)
  to authenticated;

-- ─── 10. Extend get_workspace_maintenance_tickets to include pause context ────

create or replace function app.get_workspace_maintenance_tickets(
  p_workspace_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          t.id                                                      as ticket_id,
          t.reference                                               as ticket_reference,
          r.id                                                      as request_id,
          r.reference                                               as request_reference,
          r.title,
          r.description,
          c.code                                                    as category_code,
          c.label                                                   as category,
          a.label                                                   as area,
          p.display_name                                            as property_name,
          t.property_id,
          t.unit_id,
          coalesce(nullif(trim(u.label), ''), 'Unit ' || u.id::text) as unit_name,
          t.urgency,
          t.priority,
          t.status                                                  as ticket_status,
          r.status                                                  as request_status,
          f.id                                                      as fundi_id,
          f.name                                                    as fundi_name,
          f.specialty                                               as fundi_specialty,
          f.phone                                                   as fundi_phone,
          f.rating                                                  as fundi_rating,
          f.completed_jobs                                          as fundi_completed_jobs,
          t.blocked_reason,
          t.estimated_cost,
          t.actual_cost,
          case
            when t.actual_cost is not null and t.estimated_cost is not null
            then t.actual_cost - t.estimated_cost
            else null
          end                                                       as budget_variance,
          t.resolution_days,
          t.completion_state,
          t.started_at,
          t.completed_at,
          t.assigned_at,
          coalesce(nullif(trim(prof.first_name || ' ' || prof.last_name), ' '), 'Tenant')
                                                                    as tenant_name,
          -- Latest pause event (if any)
          (
            select jsonb_build_object(
              'id',              pe.id,
              'reason_code',     pe.reason_code,
              'work_note',       pe.work_note,
              'amount_spent',    pe.amount_spent,
              'materials_used',  pe.materials_used,
              'paused_at',       pe.created_at,
              'paused_by_name',  fp.name
            )
            from app.ticket_pause_events pe
            join app.fundi_profiles fp on fp.id = pe.fundi_id
            where pe.ticket_id = t.id
            order by pe.created_at desc
            limit 1
          )                                                         as latest_pause_event,
          -- Active funding hold (if any)
          (
            select jsonb_build_object(
              'id',               fh.id,
              'amount_needed',    fh.amount_needed,
              'note',             fh.note,
              'held_at',          fh.held_at
            )
            from app.ticket_funding_holds fh
            where fh.ticket_id = t.id and fh.resolved_at is null
            limit 1
          )                                                         as active_funding_hold,
          -- Pending approval request
          (
            select jsonb_build_object(
              'id',               ar.id,
              'reason',           ar.reason,
              'requested_amount', ar.requested_amount,
              'note',             ar.note,
              'status',           ar.status,
              'requested_at',     ar.requested_at
            )
            from app.maintenance_approval_requests ar
            where ar.ticket_id = t.id and ar.status = 'pending'
            order by ar.requested_at desc
            limit 1
          )                                                         as approval_request,
          -- Media
          coalesce(
            (select jsonb_agg(
               jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type, 'stage', m.stage)
               order by m.uploaded_at
             )
             from app.maintenance_media m where m.request_id = r.id),
            '[]'::jsonb
          )                                                         as media,
          -- Activity log (most recent 20)
          coalesce(
            (select jsonb_agg(
               jsonb_build_object(
                 'id',          al.id,
                 'event_type',  al.event_type,
                 'label',       al.label,
                 'actor_name',  al.actor_name,
                 'created_at',  al.created_at
               )
               order by al.created_at desc
             )
             from (
               select * from app.maintenance_activity_log
               where ticket_id = t.id
               order by created_at desc
               limit 20
             ) al),
            '[]'::jsonb
          )                                                         as activity_log,
          t.created_at,
          t.updated_at
        from app.maintenance_tickets t
        join app.maintenance_requests    r    on r.id   = t.request_id
        join app.maintenance_categories  c    on c.id   = t.category_id
        join app.maintenance_areas       a    on a.id   = r.area_id
        join app.properties              p    on p.id   = t.property_id
        join app.units                   u    on u.id   = t.unit_id
        join app.profiles                prof on prof.id = r.tenant_user_id
        left join app.fundi_profiles     f    on f.id   = t.assigned_fundi_id
        where t.workspace_id = p_workspace_id
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_workspace_maintenance_tickets(uuid) to authenticated;

-- ─── 11. Extend get_my_provider_kanban_tickets to include pause history ────────

create or replace function app.get_my_provider_kanban_tickets()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile app.fundi_profiles;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select * into v_profile
  from app.fundi_profiles
  where user_id = v_user_id
  limit 1;

  if not found then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          t.id                                                        as ticket_id,
          t.reference                                                 as ticket_reference,
          r.id                                                        as request_id,
          r.title,
          r.description,
          c.label                                                     as category,
          a.label                                                     as area,
          p.display_name                                              as property_name,
          t.property_id,
          t.unit_id,
          coalesce(nullif(trim(u.label), ''), 'Unit ' || u.id::text) as unit_name,
          t.priority,
          t.status                                                    as ticket_status,
          t.blocked_reason,
          t.completion_state,
          t.estimated_cost,
          t.actual_cost,
          t.assigned_at,
          t.created_at,
          t.updated_at,
          jsonb_build_object(
            'id',            v_profile.id,
            'name',          v_profile.name,
            'specialty',     v_profile.specialty,
            'phone',         v_profile.phone,
            'rating',        v_profile.rating,
            'completedJobs', v_profile.completed_jobs,
            'available',     v_profile.available
          )                                                           as fundi,
          coalesce(nullif(trim(prof.first_name || ' ' || prof.last_name), ' '), 'Tenant')
                                                                      as tenant_name,
          (
            select jsonb_build_object(
              'id',               ar.id,
              'reason',           ar.reason,
              'requested_amount', ar.requested_amount,
              'note',             ar.note,
              'status',           ar.status,
              'requested_at',     ar.requested_at
            )
            from app.maintenance_approval_requests ar
            where ar.ticket_id = t.id and ar.status = 'pending'
            order by ar.requested_at desc
            limit 1
          )                                                           as approval_request,
          coalesce(
            (select jsonb_agg(
               jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type)
               order by m.uploaded_at
             )
             from app.maintenance_media m where m.request_id = r.id),
            '[]'::jsonb
          )                                                           as media

        from app.maintenance_tickets   t
        join app.maintenance_requests  r on r.id = t.request_id
        join app.maintenance_categories c on c.id = r.category_id
        join app.maintenance_areas      a on a.id = r.area_id
        join app.properties             p on p.id = t.property_id
        join app.units                  u on u.id = t.unit_id
        left join app.tenancies         tn on tn.unit_id = t.unit_id and tn.status = 'active'
        left join public.profiles       prof on prof.id = tn.tenant_user_id
        where t.assigned_fundi_id = v_profile.id
          and t.status not in ('reassigning', 'paused')
        order by t.created_at desc
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_my_provider_kanban_tickets() to authenticated;

-- ─── 12. Realtime publication for new tables ──────────────────────────────────

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'app'
        and tablename = 'ticket_funding_holds'
    ) then
      alter publication supabase_realtime add table app.ticket_funding_holds;
    end if;
  end if;
end $$;
