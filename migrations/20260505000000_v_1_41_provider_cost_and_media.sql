-- ─────────────────────────────────────────────────────────────────────────────
-- V1.41 — Provider cost update + media in assigned tickets RPC
-- ─────────────────────────────────────────────────────────────────────────────

-- ─── 1. Fundi can update costs for their own assigned tickets ─────────────────
-- (owner's update_maintenance_ticket_costs uses is_active_member which
--  excludes fundis; this RPC checks fundi profile ownership instead)

create or replace function app.update_provider_ticket_costs(
  p_ticket_id      uuid,
  p_estimated_cost numeric default null,
  p_actual_cost    numeric default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_fundi_profile app.fundi_profiles;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Find the fundi profile linked to this user
  select * into v_fundi_profile
  from app.fundi_profiles
  where user_id = auth.uid()
  limit 1;

  if not found then
    raise exception 'Provider profile not found' using errcode = 'P0404';
  end if;

  -- Ensure this ticket is actually assigned to this fundi
  if not exists (
    select 1 from app.maintenance_tickets
    where id = p_ticket_id
      and assigned_fundi_id = v_fundi_profile.id
  ) then
    raise exception 'Ticket not assigned to you' using errcode = 'P0403';
  end if;

  -- Update costs (coalesce preserves existing value when null is passed)
  update app.maintenance_tickets set
    estimated_cost = coalesce(p_estimated_cost, estimated_cost),
    actual_cost    = coalesce(p_actual_cost, actual_cost)
  where id = p_ticket_id;

  -- Log the activity
  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name, metadata)
  values (
    p_ticket_id, 'status_changed',
    'Costs updated'
      || case when p_estimated_cost is not null
              then ' — Est: Ksh ' || p_estimated_cost::text else '' end
      || case when p_actual_cost    is not null
              then ' · Actual: Ksh ' || p_actual_cost::text   else '' end,
    auth.uid(),
    coalesce(v_fundi_profile.name, 'Fundi'),
    jsonb_build_object(
      'estimated_cost', p_estimated_cost,
      'actual_cost',    p_actual_cost
    )
  );
end;
$$;

grant execute on function app.update_provider_ticket_costs(uuid, numeric, numeric) to authenticated;

-- ─── 2. Update get_my_assigned_tickets to include media ───────────────────────

create or replace function app.get_my_assigned_tickets()
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
          coalesce(nullif(trim(u.label), ''), 'Unit')                 as unit_name,
          t.priority,
          t.status,
          t.blocked_reason,
          t.completion_state,
          t.estimated_cost,
          t.actual_cost,
          t.assigned_at,
          t.started_at,
          t.completed_at,
          t.created_at,
          t.updated_at,

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
            where ar.ticket_id = t.id
              and ar.status    = 'pending'
            order by ar.requested_at desc
            limit 1
          )                                                           as approval_request,

          -- Media (evidence photos)
          coalesce(
            (select jsonb_agg(
               jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type)
               order by m.uploaded_at
             )
             from app.maintenance_media m where m.request_id = r.id),
            '[]'::jsonb
          )                                                           as media

        from app.maintenance_tickets   t
        join app.maintenance_requests  r  on r.id = t.request_id
        join app.maintenance_categories c on c.id = r.category_id
        join app.maintenance_areas      a on a.id = r.area_id
        join app.properties             p on p.id = t.property_id
        join app.units                  u on u.id = t.unit_id
        where t.assigned_fundi_id = v_profile.id
        order by t.created_at desc
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_my_assigned_tickets() to authenticated;
