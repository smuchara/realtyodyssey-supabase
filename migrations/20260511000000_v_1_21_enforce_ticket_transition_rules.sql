-- ============================================================================
-- V 1 21: Enforce strict ticket status transition rules
-- ============================================================================
-- Every ticket MUST flow through In Progress before reaching Completed.
-- No stage-skipping is permitted at the database level. All transitions are
-- validated server-side regardless of which UI surface calls the RPC.
--
-- Allowed provider (fundi) transitions via move_provider_ticket:
--   assigned        → in_progress
--   in_progress     → approval_needed
--   in_progress     → completed
--
-- Allowed owner transitions via update_maintenance_ticket_status:
--   new             → assigned        (assign fundi — use assign_maintenance_ticket)
--   assigned        → in_progress     (owner working alongside fundi)
--   in_progress     → approval_needed
--   in_progress     → completed
--   approval_needed → in_progress     (approval granted)
--   approval_needed → assigned        (approval rejected — back to fundi)
--
-- Pause, reassign, and funding-hold transitions are handled by their
-- dedicated RPCs (pause_provider_ticket, reassign_paused_ticket,
-- resolve_ticket_funding_hold) and are not affected here.
-- ============================================================================

create schema if not exists app;

-- ─── 1. Transition rule reference table ──────────────────────────────────────
-- Single source of truth queried by both RPCs and useful for future tooling.

create table if not exists app.ticket_transition_rules (
  from_status text not null,
  to_status   text not null,
  actor_role  text not null check (actor_role in ('fundi', 'owner', 'both')),
  primary key (from_status, to_status, actor_role)
);

truncate table app.ticket_transition_rules;

insert into app.ticket_transition_rules (from_status, to_status, actor_role) values
  -- Fundi transitions (via move_provider_ticket)
  ('assigned',        'in_progress',     'fundi'),
  ('in_progress',     'approval_needed', 'fundi'),
  ('in_progress',     'completed',       'fundi'),
  -- Owner transitions (via update_maintenance_ticket_status)
  ('new',             'assigned',        'owner'),
  ('assigned',        'in_progress',     'owner'),
  ('in_progress',     'approval_needed', 'owner'),
  ('in_progress',     'completed',       'owner'),
  ('approval_needed', 'in_progress',     'owner'),
  ('approval_needed', 'assigned',        'owner');

alter table app.ticket_transition_rules enable row level security;

create policy "ticket_transition_rules_select"
  on app.ticket_transition_rules for select to authenticated using (true);

grant select on app.ticket_transition_rules to authenticated;

-- ─── 2. Helper: validate a transition ────────────────────────────────────────

create or replace function app.assert_valid_ticket_transition(
  p_from   text,
  p_to     text,
  p_role   text   -- 'fundi' | 'owner'
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if not exists (
    select 1 from app.ticket_transition_rules
    where from_status = p_from
      and to_status   = p_to
      and actor_role  in (p_role, 'both')
  ) then
    raise exception
      'Invalid transition: % → % is not allowed for role %. '
      'Tickets must progress through each stage in order.',
      p_from, p_to, p_role
      using errcode = 'P0400';
  end if;
end;
$$;

-- ─── 3. Patch move_provider_ticket ───────────────────────────────────────────

create or replace function app.move_provider_ticket(
  p_ticket_id uuid,
  p_status    text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_fundi_profile app.fundi_profiles;
  v_old_status    text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Resolve fundi profile
  select * into v_fundi_profile
  from app.fundi_profiles
  where user_id = auth.uid()
  limit 1;

  if not found then
    raise exception 'Provider profile not found' using errcode = 'P0404';
  end if;

  -- Verify the ticket is assigned to this fundi and lock it
  select status into v_old_status
  from app.maintenance_tickets
  where id              = p_ticket_id
    and assigned_fundi_id = v_fundi_profile.id
  for update;

  if not found then
    raise exception 'Ticket not assigned to you' using errcode = 'P0403';
  end if;

  -- Enforce transition rules (raises if invalid)
  perform app.assert_valid_ticket_transition(v_old_status, p_status, 'fundi');

  -- Apply the transition
  update app.maintenance_tickets set
    status       = p_status,
    started_at   = case when p_status = 'in_progress' and started_at is null then now() else started_at end,
    completed_at = case when p_status = 'completed' then now() else completed_at end
  where id = p_ticket_id;

  -- Activity log
  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    p_ticket_id,
    'status_changed',
    'Status: ' || v_old_status || ' → ' || p_status,
    auth.uid(),
    coalesce(v_fundi_profile.name, 'Fundi')
  );

  -- Push notification to tenant on key transitions
  if p_status in ('in_progress', 'completed') then
    perform app.enqueue_maintenance_status_update_notification(
      p_ticket_id, p_status, v_old_status
    );
  end if;
end;
$$;

grant execute on function app.move_provider_ticket(uuid, text) to authenticated;

-- ─── 4. Patch update_maintenance_ticket_status (owner) ───────────────────────

create or replace function app.update_maintenance_ticket_status(
  p_ticket_id      uuid,
  p_status         text,
  p_blocked_reason text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_old_status   text;
begin
  select workspace_id, status into v_workspace_id, v_old_status
  from app.maintenance_tickets
  where id = p_ticket_id
  for update;

  if not found then
    raise exception 'Ticket not found' using errcode = 'P0404';
  end if;

  if not app.is_active_member(v_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

  -- Enforce owner transition rules (raises if invalid)
  perform app.assert_valid_ticket_transition(v_old_status, p_status, 'owner');

  update app.maintenance_tickets set
    status         = p_status,
    blocked_reason = case when p_status = 'blocked' then p_blocked_reason else null end,
    blocked_at     = case when p_status = 'blocked' then now() else null end
  where id = p_ticket_id;

  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    p_ticket_id,
    case when p_status = 'blocked' then 'blocked' else 'status_changed' end,
    case
      when p_status = 'blocked'
        then 'Blocked — ' || coalesce(p_blocked_reason, 'reason not specified')
      else 'Status changed: ' || v_old_status || ' → ' || p_status
    end,
    auth.uid(),
    coalesce(
      (select first_name || ' ' || last_name from app.profiles where id = auth.uid()),
      'Admin'
    )
  );

  -- Push notification on key transitions
  if p_status in ('assigned', 'in_progress', 'completed') then
    perform app.enqueue_maintenance_status_update_notification(
      p_ticket_id, p_status, v_old_status
    );
  end if;
end;
$$;

grant execute on function app.update_maintenance_ticket_status(uuid, text, text) to authenticated;
