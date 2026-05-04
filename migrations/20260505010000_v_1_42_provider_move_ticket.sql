-- ─────────────────────────────────────────────────────────────────────────────
-- V1.42 — Provider move ticket RPC
-- Fundis are not workspace members so they can't use update_maintenance_ticket_status.
-- This RPC verifies fundi profile ownership instead.
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_allowed_statuses text[] := ARRAY['assigned','in_progress','approval_needed','completed'];
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if p_status != all(v_allowed_statuses) then
    raise exception 'Invalid status: %', p_status using errcode = 'P0400';
  end if;

  -- Find the fundi profile for this user
  select * into v_fundi_profile
  from app.fundi_profiles
  where user_id = auth.uid()
  limit 1;

  if not found then
    raise exception 'Provider profile not found' using errcode = 'P0404';
  end if;

  -- Verify the ticket is assigned to this fundi
  select status into v_old_status
  from app.maintenance_tickets
  where id = p_ticket_id
    and assigned_fundi_id = v_fundi_profile.id;

  if not found then
    raise exception 'Ticket not assigned to you' using errcode = 'P0403';
  end if;

  -- Update status
  update app.maintenance_tickets set
    status     = p_status,
    started_at = case when p_status = 'in_progress' and started_at is null then now() else started_at end,
    completed_at = case when p_status = 'completed' then now() else completed_at end
  where id = p_ticket_id;

  -- Log activity
  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    p_ticket_id,
    'status_changed',
    'Status: ' || v_old_status || ' → ' || p_status,
    auth.uid(),
    coalesce(v_fundi_profile.name, 'Fundi')
  );
end;
$$;

grant execute on function app.move_provider_ticket(uuid, text) to authenticated;
