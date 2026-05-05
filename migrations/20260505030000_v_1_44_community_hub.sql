-- ============================================================================
-- V 1 44: Community Hub — Radius Zones
-- ============================================================================
-- Purpose
--   Store owner-defined (or auto-generated) 10 km radius community zones that
--   group nearby properties on the map.  Owners can rename zones and resize
--   the radius; all changes persist here.
-- ============================================================================

create table if not exists app.community_zones (
  id                uuid          primary key default gen_random_uuid(),
  workspace_id      uuid          not null references app.workspaces(id)   on delete cascade,
  -- The property that anchored the zone (nullable: zone may outlive property)
  property_id       uuid          references  app.properties(id)           on delete set null,
  center_lat        double precision not null,
  center_lng        double precision not null,
  radius_km         double precision not null default 10
                      constraint chk_community_zones_radius check (radius_km between 1 and 100),
  -- Owner-visible title (editable); starts as auto_title
  title             text          not null
                      constraint chk_community_zones_title check (char_length(trim(title)) between 1 and 120),
  -- System-generated title derived from location names at creation time
  auto_title        text          not null,
  -- Hex colour assigned from the fixed palette to keep zones visually distinct
  color             text          not null default '#3b82f6',
  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now()
);

-- Keep updated_at fresh on every write
drop trigger if exists trg_community_zones_updated_at on app.community_zones;
create trigger trg_community_zones_updated_at
  before update on app.community_zones
  for each row execute function app.set_updated_at();

create index if not exists idx_community_zones_workspace_id
  on app.community_zones (workspace_id);

create index if not exists idx_community_zones_property_id
  on app.community_zones (property_id);

-- ── Row-Level Security ─────────────────────────────────────────────────────

alter table app.community_zones enable row level security;

-- Owners may read, create, update, and delete zones that belong to their workspace
create policy "owner_all_community_zones"
  on app.community_zones
  for all
  to authenticated
  using (
    exists (
      select 1 from app.workspaces w
      where  w.id             = community_zones.workspace_id
      and    w.owner_user_id  = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from app.workspaces w
      where  w.id             = community_zones.workspace_id
      and    w.owner_user_id  = auth.uid()
    )
  );

grant select, insert, update, delete on app.community_zones to authenticated;
