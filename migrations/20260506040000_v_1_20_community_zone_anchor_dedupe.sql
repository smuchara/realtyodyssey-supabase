-- ============================================================================
-- V 1 20: Community zone property anchor de-duplication
-- ============================================================================
-- A property should anchor at most one auto-generated radius zone. This cleans
-- up duplicates created by repeated client loads and prevents future repeats.
-- ============================================================================

with ranked as (
  select
    id,
    property_id,
    first_value(id) over (
      partition by property_id
      order by created_at asc, id asc
    ) as keeper_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
),
duplicates as (
  select id as duplicate_id, keeper_id
  from ranked
  where rn > 1
)
delete from app.community_zone_members m
using duplicates d
where m.community_zone_id = d.duplicate_id
  and exists (
    select 1
    from app.community_zone_members keeper_member
    where keeper_member.community_zone_id = d.keeper_id
      and keeper_member.user_id = m.user_id
  );

with ranked as (
  select
    id,
    property_id,
    first_value(id) over (
      partition by property_id
      order by created_at asc, id asc
    ) as keeper_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
),
duplicates as (
  select id as duplicate_id, keeper_id
  from ranked
  where rn > 1
)
update app.community_zone_members m
set community_zone_id = d.keeper_id
from duplicates d
where m.community_zone_id = d.duplicate_id;

with ranked as (
  select
    id,
    property_id,
    first_value(id) over (
      partition by property_id
      order by created_at asc, id asc
    ) as keeper_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
),
duplicates as (
  select id as duplicate_id, keeper_id
  from ranked
  where rn > 1
)
update app.community_posts p
set community_zone_id = d.keeper_id
from duplicates d
where p.community_zone_id = d.duplicate_id;

with ranked as (
  select
    id,
    property_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
)
delete from app.community_zones z
using ranked r
where z.id = r.id
  and r.rn > 1;

create unique index if not exists uq_community_zones_property_anchor
  on app.community_zones (property_id)
  where property_id is not null;
