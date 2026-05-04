-- V1.43 - Tenant maintenance requests include assigned fundi details.
-- The mobile app uses this payload to show who is working on a repair and
-- to unlock the tenant/fundi chat launcher.

create or replace function app.get_tenant_maintenance_requests()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          r.id,
          r.reference,
          r.title,
          r.description,
          c.code                                                   as category_code,
          c.label                                                  as category,
          a.code                                                   as area_code,
          a.label                                                  as area,
          r.urgency,
          r.priority,
          r.status,
          s.label                                                  as status_label,
          r.property_id,
          p.display_name                                           as property_name,
          r.unit_id,
          coalesce(nullif(trim(u.label), ''), 'Unit ' || u.id::text)
                                                                    as unit_name,
          concat_ws(', ', nullif(trim(u.block), ''), nullif(trim(u.floor), ''))
                                                                    as residence_address,
          r.tenant_user_id                                         as tenant_id,
          coalesce(
            nullif(trim(prof.first_name || ' ' || prof.last_name), ''),
            prof.email,
            'Tenant'
          )                                                        as tenant_name,
          t.id                                                     as ticket_id,
          t.reference                                              as ticket_reference,
          t.status                                                 as ticket_status,
          t.assigned_fundi_id,
          t.assigned_at,
          case
            when f.id is null then null
            else jsonb_build_object(
              'id',             f.id,
              'name',           f.name,
              'specialty',      coalesce(nullif(trim(f.specialty), ''), 'Maintenance Fundi'),
              'phone',          f.phone,
              'rating',         f.rating,
              'completed_jobs', f.completed_jobs
            )
          end                                                      as fundi,
          coalesce(
            (select jsonb_agg(
               jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type)
               order by m.uploaded_at
             )
             from app.maintenance_media m
             where m.request_id = r.id),
            '[]'::jsonb
          )                                                        as media,
          r.created_at,
          r.updated_at,
          r.resolved_at
        from app.maintenance_requests r
        join app.maintenance_categories c on c.id = r.category_id
        join app.maintenance_areas      a on a.id = r.area_id
        join app.maintenance_request_statuses s on s.code = r.status
        join app.properties             p on p.id = r.property_id
        join app.units                  u on u.id = r.unit_id
        left join app.profiles       prof on prof.id = r.tenant_user_id
        left join app.maintenance_tickets t on t.request_id = r.id
        left join app.fundi_profiles     f on f.id = t.assigned_fundi_id
        where r.tenant_user_id = v_uid
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_tenant_maintenance_requests() to authenticated;
