-- ============================================================================
-- V 1 46: Move resolve_tenant_community_zone to public schema
-- ============================================================================
-- Problem
--   supabase_flutter's .rpc('fn') always sends Content-Profile: public, so
--   PostgREST only searches the public schema for callable functions.
--   v_1_45 defined the function in the app schema, making it unreachable
--   from the mobile client (PGRST202).
--
-- Fix
--   Re-create the function in the public schema (body unchanged) and drop
--   the old app schema copy so there is no ambiguity.
-- ============================================================================

create or replace function public.resolve_tenant_community_zone(
  p_user_id     uuid,
  p_property_id uuid
) returns uuid
language plpgsql security definer
set search_path = public, app
as $$
declare
  v_lat     double precision;
  v_lng     double precision;
  v_zone_id uuid;
begin
  select latitude, longitude
  into   v_lat, v_lng
  from   app.properties
  where  id = p_property_id;

  if v_lat is null or v_lng is null then
    return null;
  end if;

  -- Closest zone whose radius contains this property (haversine)
  select id into v_zone_id
  from   app.community_zones
  where (
    6371.0 * 2.0 * asin(sqrt(
      power(sin((radians(v_lat) - radians(center_lat)) / 2.0), 2) +
      cos(radians(center_lat)) * cos(radians(v_lat)) *
      power(sin((radians(v_lng) - radians(center_lng)) / 2.0), 2)
    ))
  ) <= radius_km
  order by (
    6371.0 * 2.0 * asin(sqrt(
      power(sin((radians(v_lat) - radians(center_lat)) / 2.0), 2) +
      cos(radians(center_lat)) * cos(radians(v_lat)) *
      power(sin((radians(v_lng) - radians(center_lng)) / 2.0), 2)
    ))
  )
  limit 1;

  if v_zone_id is null then
    return null;
  end if;

  insert into app.community_zone_members (community_zone_id, user_id, property_id)
  values (v_zone_id, p_user_id, p_property_id)
  on conflict (community_zone_id, user_id)
  do update set property_id = excluded.property_id, joined_at = now();

  return v_zone_id;
end;
$$;

revoke all  on function public.resolve_tenant_community_zone(uuid, uuid) from public;
grant execute on function public.resolve_tenant_community_zone(uuid, uuid) to authenticated;

-- Remove the unreachable app-schema copy
drop function if exists app.resolve_tenant_community_zone(uuid, uuid);
