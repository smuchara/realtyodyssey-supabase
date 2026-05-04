-- ─────────────────────────────────────────────────────────────────────────────
-- V1.40 — Provider Kanban RPC
-- Full ticket data for the fundi's Kanban board view.
-- ─────────────────────────────────────────────────────────────────────────────

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

          -- Assigned fundi (themselves)
          jsonb_build_object(
            'id',            v_profile.id,
            'name',          v_profile.name,
            'specialty',     v_profile.specialty,
            'phone',         v_profile.phone,
            'rating',        v_profile.rating,
            'completedJobs', v_profile.completed_jobs,
            'available',     v_profile.available
          )                                                           as fundi,

          -- Tenant name
          coalesce(nullif(trim(prof.first_name || ' ' || prof.last_name), ' '), 'Tenant')
                                                                      as tenant_name,

          -- Pending approval request (if any)
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

          -- Media
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
        order by t.created_at desc
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_my_provider_kanban_tickets() to authenticated;
