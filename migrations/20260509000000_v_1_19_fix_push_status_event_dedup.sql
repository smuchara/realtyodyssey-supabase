-- v1.20 — Fix push notification deduplication for repeated status transitions
--
-- The previous enqueue_maintenance_status_update_notification used the
-- ticket status string as event_key (e.g. "in_progress"). If a ticket
-- cycles through the same status more than once the second call hits
-- ON CONFLICT DO UPDATE, which fires no INSERT trigger, creates no new
-- tenant_push_deliveries row, and sends no push notification.
--
-- Fix: append a random UUID suffix so every state transition always
-- produces a fresh INSERT row, ensuring the webhook fires every time.

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

  -- Every transition gets a unique key so each call always INSERTs a new
  -- notification row. Using just the status string caused ON CONFLICT DO UPDATE
  -- on repeated transitions, which never triggered the push delivery trigger.
  v_event_key := coalesce(p_old_status, 'none')
    || '_to_'
    || coalesce(p_status, 'updated')
    || '_'
    || gen_random_uuid()::text;

  v_status_label := case p_status
    when 'assigned'        then 'Assigned'
    when 'in_progress'     then 'In progress'
    when 'approval_needed' then 'Waiting for approval'
    when 'blocked'         then 'Delayed'
    else initcap(replace(coalesce(p_status, 'updated'), '_', ' '))
  end;

  v_title := case p_status
    when 'assigned'        then 'A fundi has been assigned'
    when 'in_progress'     then 'Maintenance work has started'
    when 'approval_needed' then 'Your ticket needs approval'
    when 'blocked'         then 'Your maintenance ticket is delayed'
    else 'Maintenance status updated'
  end;

  v_body := case p_status
    when 'assigned' then
      coalesce(v_row.fundi_name, 'A fundi')
      || ' has been assigned to your '
      || lower(v_row.category) || ' request.'
    when 'in_progress' then
      'Your ' || lower(v_row.category) || ' request is now in progress.'
    when 'approval_needed' then
      'Your ' || lower(v_row.category) || ' request is waiting for approval.'
    when 'blocked' then
      'Your ' || lower(v_row.category)
      || ' request has been delayed. Tap to see the latest status.'
    else
      'Your maintenance ticket status changed to '
      || lower(v_status_label) || '.'
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
