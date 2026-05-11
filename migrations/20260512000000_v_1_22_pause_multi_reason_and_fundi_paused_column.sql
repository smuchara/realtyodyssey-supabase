-- ============================================================================
-- V 1 22: Pause multi-reason support + fundi Paused column
-- ============================================================================
-- 1. Adds reason_codes text[] to ticket_pause_events so a fundi can select
--    multiple reasons in one pause action.
-- 2. Adds two new pause reasons: resource_delay, other.
-- 3. Patches pause_provider_ticket to accept p_reason_codes text[] and derive
--    behaviour from whether 'funding_delay' is in the array.
-- 4. Patches get_my_provider_kanban_tickets to include 'paused' tickets
--    (where the fundi is still assigned) so they appear in the Paused column.
-- ============================================================================

create schema if not exists app;

-- ─── 1. New pause reasons ─────────────────────────────────────────────────────

insert into app.ticket_pause_reasons (code, label, sort_order) values
  ('resource_delay', 'Resource Delay', 5),
  ('other',          'Other',          6)
on conflict (code) do update set label = excluded.label, sort_order = excluded.sort_order;

-- ─── 2. Add reason_codes[] to the pause event table ──────────────────────────

alter table app.ticket_pause_events
  add column if not exists reason_codes text[] not null default '{}';

-- Backfill existing rows
update app.ticket_pause_events
  set reason_codes = array[reason_code]
  where reason_codes = '{}';

-- ─── 3. Patch pause_provider_ticket ──────────────────────────────────────────
-- Accepts p_reason_codes text[].
-- Behaviour:
--   'funding_delay' in array  → ticket stays paused (owner must act)
--   otherwise                 → ticket moves to reassigning (new fundi needed)
-- Primary reason_code (stored for backward compat) = first element of the array.

create or replace function app.pause_provider_ticket(
  p_ticket_id       uuid,
  p_reason_codes    text[],          -- multi-select; at least one required
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
  v_user_id      uuid := auth.uid();
  v_profile      app.fundi_profiles;
  v_ticket       app.maintenance_tickets;
  v_pause_id     uuid;
  v_new_status   text;
  v_actor_name   text;
  v_primary_code text;
  v_has_funding  boolean;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Validate inputs
  if array_length(p_reason_codes, 1) is null or array_length(p_reason_codes, 1) = 0 then
    raise exception 'At least one pause reason is required' using errcode = 'P0400';
  end if;

  if char_length(trim(coalesce(p_work_note, ''))) < 10 then
    raise exception 'Work note must describe what has been completed (min 10 characters)'
      using errcode = 'P0400';
  end if;

  -- Validate every code against the reference table
  if exists (
    select 1 from unnest(p_reason_codes) rc(code)
    where not exists (select 1 from app.ticket_pause_reasons where code = rc.code)
  ) then
    raise exception 'One or more invalid pause reason codes' using errcode = 'P0400';
  end if;

  -- Resolve fundi profile
  select * into v_profile
  from app.fundi_profiles
  where user_id = v_user_id
  limit 1;

  if not found then
    raise exception 'Provider profile not found' using errcode = 'P0404';
  end if;

  -- Lock ticket
  select * into v_ticket
  from app.maintenance_tickets
  where id              = p_ticket_id
    and assigned_fundi_id = v_profile.id
  for update;

  if not found then
    raise exception 'Ticket not assigned to you' using errcode = 'P0403';
  end if;

  if v_ticket.status <> 'in_progress' then
    raise exception 'Only in-progress tickets can be paused (current: %)', v_ticket.status
      using errcode = 'P0400';
  end if;

  v_actor_name  := coalesce(v_profile.name, 'Fundi');
  v_primary_code := p_reason_codes[1];
  v_has_funding  := 'funding_delay' = any(p_reason_codes);
  v_new_status   := case v_has_funding when true then 'paused' else 'reassigning' end;

  -- Immutable pause event
  insert into app.ticket_pause_events
    (ticket_id, fundi_id, reason_code, reason_codes, work_note, amount_spent, materials_used)
  values
    (p_ticket_id, v_profile.id, v_primary_code, p_reason_codes,
     trim(p_work_note), p_amount_spent, nullif(trim(coalesce(p_materials_used, '')), ''))
  returning id into v_pause_id;

  -- Update ticket
  update app.maintenance_tickets set
    status            = v_new_status,
    assigned_fundi_id = case when v_has_funding then v_profile.id else null end,
    assigned_at       = case when v_has_funding then v_ticket.assigned_at else null end
  where id = p_ticket_id;

  -- Funding hold record (only for financial pauses)
  if v_has_funding then
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
    case v_has_funding when true then 'blocked' else 'status_changed' end,
    case v_has_funding
      when true then 'Work paused — awaiting funding from owner'
      else 'Work paused — ticket moved to reassignment (' || array_to_string(p_reason_codes, ', ') || ')'
    end,
    v_user_id,
    v_actor_name,
    jsonb_build_object(
      'pause_event_id', v_pause_id,
      'reason_codes',   p_reason_codes,
      'new_status',     v_new_status,
      'amount_spent',   p_amount_spent,
      'materials_used', p_materials_used
    )
  );

  -- Push notification to tenant
  perform app.enqueue_maintenance_status_update_notification(
    p_ticket_id, v_new_status, 'in_progress'
  );

  return jsonb_build_object(
    'pause_event_id', v_pause_id,
    'new_status',     v_new_status
  );
end;
$$;

-- Both old single-arg and new multi-arg signatures are supported
grant execute on function app.pause_provider_ticket(uuid, text[], text, numeric, text)
  to authenticated;

-- ─── 4. Patch get_my_provider_kanban_tickets to include paused tickets ────────
-- Paused tickets have the fundi still assigned (funding_delay path).
-- Reassigning tickets have assigned_fundi_id = null so the filter already
-- excludes them; we only need to remove 'paused' from the exclusion list.

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
          -- Latest pause event for the paused column display
          (
            select jsonb_build_object(
              'reason_codes',   pe.reason_codes,
              'work_note',      pe.work_note,
              'amount_spent',   pe.amount_spent,
              'materials_used', pe.materials_used,
              'paused_at',      pe.created_at
            )
            from app.ticket_pause_events pe
            where pe.ticket_id = t.id
            order by pe.created_at desc
            limit 1
          )                                                           as latest_pause_event,
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
        left join app.tenancies         tn  on tn.unit_id = t.unit_id and tn.status = 'active'
        left join public.profiles       prof on prof.id = tn.tenant_user_id
        -- Include paused (fundi still assigned) but exclude reassigning (fundi released)
        where t.assigned_fundi_id = v_profile.id
          and t.status <> 'reassigning'
        order by t.created_at desc
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_my_provider_kanban_tickets() to authenticated;
