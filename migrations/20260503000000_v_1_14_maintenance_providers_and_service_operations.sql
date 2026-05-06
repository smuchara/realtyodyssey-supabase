-- ============================================================================
-- V 1 14: Maintenance, Providers, and Service Operations
-- ============================================================================
-- Purpose
--   - Model tenant maintenance requests, owner ticket operations, approvals, costs, media, and activity logs.
--   - Support external provider invitation, acceptance, kanban, and assigned-ticket workflows.
--   - Expose tenant/provider RPCs through least-privilege RLS and authenticated grants.
--
-- Consolidated before first production publication. Earlier patch migrations
-- were folded into these domain files so a fresh reset replays the final
-- architecture without historical trial-and-error migration noise.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Maintenance request and ticket domain
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- ─── 1. Reference / lookup tables ────────────────────────────────────────────

create table if not exists app.maintenance_categories (
  id         uuid    primary key default gen_random_uuid(),
  code       text    unique not null,
  label      text    not null,
  icon       text,                     -- material icon name hint for UIs
  sort_order smallint not null default 0,
  is_active  boolean not null default true
);

insert into app.maintenance_categories (code, label, icon, sort_order) values
  ('plumbing',        'Plumbing',        'plumbing',             1),
  ('electrical',      'Electrical',      'electrical_services',  2),
  ('hvac',            'HVAC',            'ac_unit',              3),
  ('structural',      'Structural',      'home_repair_service',  4),
  ('windows_doors',   'Windows & Doors', 'sensor_door',          5),
  ('appliances',      'Appliances',      'kitchen',              6),
  ('painting',        'Painting',        'format_paint',         7),
  ('security',        'Security',        'security',             8),
  ('general_repairs', 'General Repairs', 'build',                9),
  ('other',           'Other',           'more_horiz',          10)
on conflict (code) do update
  set label = excluded.label, icon = excluded.icon, sort_order = excluded.sort_order;

create table if not exists app.maintenance_areas (
  id         uuid    primary key default gen_random_uuid(),
  code       text    unique not null,
  label      text    not null,
  icon       text,
  sort_order smallint not null default 0,
  is_active  boolean not null default true
);

insert into app.maintenance_areas (code, label, icon, sort_order) values
  ('kitchen',     'Kitchen',     'kitchen',       1),
  ('bathroom',    'Bathroom',    'bathroom',      2),
  ('bedroom',     'Bedroom',     'bed',           3),
  ('living_room', 'Living Room', 'chair',         4),
  ('balcony',     'Balcony',     'deck',          5),
  ('ceiling',     'Ceiling',     'roofing',       6),
  ('common_area', 'Common Area', 'groups',        7),
  ('parking',     'Parking',     'local_parking', 8),
  ('gate',        'Gate',        'sensor_door',   9),
  ('rooftop',     'Rooftop',     'roofing',      10),
  ('stairwell',   'Stairwell',   'stairs',       11),
  ('other',       'Other',       'more_horiz',   12)
on conflict (code) do update
  set label = excluded.label, icon = excluded.icon, sort_order = excluded.sort_order;

-- Urgency: tenant-visible.
-- Priority is derived and is the owner/operational representation.
create table if not exists app.maintenance_urgency_levels (
  code              text    primary key,  -- 'standard' | 'moderate' | 'emergency'
  label             text    not null,
  priority          text    not null,     -- 'low' | 'medium' | 'high'
  response_days_max smallint,
  sort_order        smallint not null default 0
);

insert into app.maintenance_urgency_levels (code, label, priority, response_days_max, sort_order) values
  ('standard',  'Standard',  'low',    5, 1),
  ('moderate',  'Moderate',  'medium', 4, 2),
  ('emergency', 'Emergency', 'high',   1, 3)
on conflict (code) do update
  set label = excluded.label, priority = excluded.priority,
      response_days_max = excluded.response_days_max;

-- Tenant-visible request statuses (simple, reassuring language)
create table if not exists app.maintenance_request_statuses (
  code       text primary key,
  label      text not null,
  sort_order smallint not null default 0
);

insert into app.maintenance_request_statuses (code, label, sort_order) values
  ('submitted',           'Submitted',            1),
  ('under_review',        'Under Review',         2),
  ('specialist_assigned', 'Specialist Assigned',  3),
  ('in_progress',         'In Progress',          4),
  ('waiting',             'Waiting for Approval', 5),
  ('completed',           'Completed',            6)
on conflict (code) do update set label = excluded.label;

-- Owner / operational ticket statuses
create table if not exists app.maintenance_ticket_statuses (
  code       text primary key,
  label      text not null,
  sort_order smallint not null default 0
);

insert into app.maintenance_ticket_statuses (code, label, sort_order) values
  ('new',             'New / Unassigned',  1),
  ('assigned',        'Assigned',          2),
  ('in_progress',     'In Progress',       3),
  ('approval_needed', 'Approval Needed',   4),
  ('blocked',         'Blocked',           5),
  ('completed',       'Completed',         6),
  ('verified',        'Verified',          7)
on conflict (code) do update set label = excluded.label;

-- ─── 2. Fundi (contractor) profiles ──────────────────────────────────────────

create table if not exists app.fundi_profiles (
  id             uuid    primary key default gen_random_uuid(),
  workspace_id   uuid    not null references app.workspaces(id) on delete cascade,
  name           text    not null,
  specialty      text,
  location       text,
  phone          text,
  rating         numeric(3,2) not null default 0 check (rating between 0 and 5),
  completed_jobs integer      not null default 0,
  available      boolean      not null default true,
  notes          text,
  created_at     timestamptz  not null default now(),
  updated_at     timestamptz  not null default now()
);

drop trigger if exists trg_fundi_profiles_updated_at on app.fundi_profiles;
create trigger trg_fundi_profiles_updated_at
  before update on app.fundi_profiles
  for each row execute function app.set_updated_at();

create index if not exists idx_fundi_profiles_workspace
  on app.fundi_profiles (workspace_id);

-- ─── 3. Maintenance requests (tenant-submitted) ───────────────────────────────

create table if not exists app.maintenance_requests (
  id           uuid primary key default gen_random_uuid(),
  reference    text unique not null,   -- REQ-XXXXX (generated)

  -- Who submitted
  tenant_user_id uuid not null references auth.users(id) on delete restrict,
  workspace_id   uuid not null references app.workspaces(id) on delete restrict,
  property_id    uuid not null references app.properties(id) on delete restrict,
  unit_id        uuid not null references app.units(id) on delete restrict,

  -- What they reported
  title          text not null,
  description    text not null check (char_length(description) >= 10),
  category_id    uuid not null references app.maintenance_categories(id),
  area_id        uuid not null references app.maintenance_areas(id),
  urgency        text not null references app.maintenance_urgency_levels(code),
  priority       text not null check (priority in ('low', 'medium', 'high')),

  -- Tenant-visible status
  status         text not null default 'submitted'
                 references app.maintenance_request_statuses(code),

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  resolved_at    timestamptz
);

drop trigger if exists trg_maintenance_requests_updated_at on app.maintenance_requests;
create trigger trg_maintenance_requests_updated_at
  before update on app.maintenance_requests
  for each row execute function app.set_updated_at();

create index if not exists idx_maintenance_requests_tenant
  on app.maintenance_requests (tenant_user_id);
create index if not exists idx_maintenance_requests_workspace
  on app.maintenance_requests (workspace_id);
create index if not exists idx_maintenance_requests_property
  on app.maintenance_requests (property_id);
create index if not exists idx_maintenance_requests_status
  on app.maintenance_requests (status);

-- ─── 4. Maintenance tickets (owner / operational view) ────────────────────────
--
-- Auto-created by trigger when a maintenance_request is inserted.
-- Mirrors the request fields for query performance, adds operational
-- fields (assignment, cost, blocking, resolution).

create table if not exists app.maintenance_tickets (
  id                uuid    primary key default gen_random_uuid(),
  reference         text    unique not null,    -- MT-XXXX (generated)
  request_id        uuid    not null unique references app.maintenance_requests(id) on delete restrict,

  -- Denormalized for efficient owner queries
  workspace_id      uuid    not null references app.workspaces(id),
  property_id       uuid    not null references app.properties(id),
  unit_id           uuid    not null references app.units(id),
  category_id       uuid    not null references app.maintenance_categories(id),
  urgency           text    not null references app.maintenance_urgency_levels(code),
  priority          text    not null check (priority in ('low', 'medium', 'high')),

  -- Operational status
  status            text    not null default 'new'
                    references app.maintenance_ticket_statuses(code),

  -- Fundi assignment
  assigned_fundi_id uuid    references app.fundi_profiles(id) on delete set null,
  assigned_at       timestamptz,

  -- Blocked state
  blocked_reason    text,
  blocked_at        timestamptz,

  -- Cost tracking — nullable until fundi provides actuals
  estimated_cost    numeric(12,2),
  actual_cost       numeric(12,2),
  -- budget_variance is derived; computed column not used for cross-DB compat
  -- calculate as: actual_cost - estimated_cost in application layer

  -- Resolution timing
  started_at        timestamptz,
  completed_at      timestamptz,
  resolution_days   integer,           -- set by trigger on completion

  -- Future completion flow: pending_review → verified
  completion_state  text check (completion_state in ('pending_review', 'verified')),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists idx_maintenance_tickets_workspace
  on app.maintenance_tickets (workspace_id);
create index if not exists idx_maintenance_tickets_property
  on app.maintenance_tickets (property_id);
create index if not exists idx_maintenance_tickets_status
  on app.maintenance_tickets (status);
create index if not exists idx_maintenance_tickets_fundi
  on app.maintenance_tickets (assigned_fundi_id);

-- ─── 5. Media (photos / videos) ──────────────────────────────────────────────

create table if not exists app.maintenance_media (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references app.maintenance_requests(id) on delete cascade,
  ticket_id    uuid references app.maintenance_tickets(id) on delete set null,
  storage_path text not null,       -- Supabase Storage object path
  url          text,                -- cached public / signed URL
  media_type   text not null default 'image' check (media_type in ('image', 'video')),
  -- Stage: when in the workflow was this uploaded
  stage        text not null default 'report'
               check (stage in ('report', 'in_progress', 'completion')),
  uploaded_by  uuid not null references auth.users(id) on delete restrict,
  uploaded_at  timestamptz not null default now()
);

create index if not exists idx_maintenance_media_request
  on app.maintenance_media (request_id);
create index if not exists idx_maintenance_media_ticket
  on app.maintenance_media (ticket_id);

-- ─── 6. Approval requests (scope-change sign-off) ────────────────────────────

create table if not exists app.maintenance_approval_requests (
  id               uuid primary key default gen_random_uuid(),
  ticket_id        uuid not null references app.maintenance_tickets(id) on delete cascade,
  reason           text not null,
  requested_amount numeric(12,2),
  note             text,
  status           text not null default 'pending'
                   check (status in ('pending', 'approved', 'rejected')),
  requested_by     uuid not null references auth.users(id) on delete restrict,
  resolved_by      uuid references auth.users(id) on delete set null,
  requested_at     timestamptz not null default now(),
  resolved_at      timestamptz
);

create index if not exists idx_maintenance_approvals_ticket
  on app.maintenance_approval_requests (ticket_id);

-- ─── 7. Activity log (immutable audit trail) ─────────────────────────────────

create table if not exists app.maintenance_activity_log (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid references app.maintenance_tickets(id) on delete set null,
  request_id  uuid references app.maintenance_requests(id) on delete set null,
  event_type  text not null,    -- created | assigned | status_changed | blocked | approval_requested | etc.
  label       text not null,    -- human-readable description
  actor_id    uuid references auth.users(id) on delete set null,
  actor_name  text not null,
  metadata    jsonb,            -- structured hook data (cost, fundi_id, etc.)
  created_at  timestamptz not null default now()
);

-- Activity log is append-only; no updates trigger needed
create index if not exists idx_maintenance_activity_ticket
  on app.maintenance_activity_log (ticket_id, created_at desc);
create index if not exists idx_maintenance_activity_request
  on app.maintenance_activity_log (request_id, created_at desc);

-- ─── 8. Reference generation helpers ─────────────────────────────────────────

create or replace function app.generate_maintenance_reference()
returns text
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_ref  text;
  v_iter int := 0;
begin
  loop
    v_ref := 'REQ-' || lpad((floor(random() * 90000 + 10000))::text, 5, '0');
    exit when not exists (select 1 from app.maintenance_requests where reference = v_ref);
    v_iter := v_iter + 1;
    if v_iter > 200 then
      raise exception 'generate_maintenance_reference: exhausted attempts';
    end if;
  end loop;
  return v_ref;
end;
$$;

create or replace function app.generate_ticket_reference()
returns text
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_ref  text;
  v_iter int := 0;
begin
  loop
    v_ref := 'MT-' || lpad((floor(random() * 9000 + 1000))::text, 4, '0');
    exit when not exists (select 1 from app.maintenance_tickets where reference = v_ref);
    v_iter := v_iter + 1;
    if v_iter > 200 then
      raise exception 'generate_ticket_reference: exhausted attempts';
    end if;
  end loop;
  return v_ref;
end;
$$;

-- ─── 9. Trigger: auto-create ticket when request is inserted ─────────────────

create or replace function app.on_maintenance_request_inserted()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_ticket_id uuid;
  v_actor     text;
begin
  -- Create the operational ticket
  insert into app.maintenance_tickets (
    reference, request_id, workspace_id, property_id, unit_id,
    category_id, urgency, priority, status
  ) values (
    app.generate_ticket_reference(),
    new.id,
    new.workspace_id,
    new.property_id,
    new.unit_id,
    new.category_id,
    new.urgency,
    new.priority,
    'new'
  )
  returning id into v_ticket_id;

  -- Resolve actor display name
  select coalesce(p.first_name || ' ' || p.last_name, 'Tenant')
  into v_actor
  from app.profiles p
  where p.id = new.tenant_user_id;

  -- Seed the activity log
  insert into app.maintenance_activity_log
    (ticket_id, request_id, event_type, label, actor_id, actor_name)
  values
    (v_ticket_id, new.id, 'created', 'Maintenance request submitted by tenant',
     new.tenant_user_id, coalesce(v_actor, 'Tenant'));

  return new;
end;
$$;

drop trigger if exists trg_maintenance_request_inserted on app.maintenance_requests;
create trigger trg_maintenance_request_inserted
  after insert on app.maintenance_requests
  for each row execute function app.on_maintenance_request_inserted();

-- ─── 10. Trigger: ticket lifecycle hooks ─────────────────────────────────────
--
-- Runs BEFORE UPDATE so it can modify the row in place.
-- Responsibilities:
--   - Set started_at when work begins
--   - Calculate resolution_days on completion
--   - Set completion_state = 'pending_review' on first completion
--   - Sync the tenant-visible request status

create or replace function app.on_maintenance_ticket_updated()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  -- Mark when active work started
  if new.status = 'in_progress' and old.status <> 'in_progress' then
    new.started_at := coalesce(old.started_at, now());
  end if;

  -- Resolve completion fields
  if new.status in ('completed', 'verified')
     and old.status not in ('completed', 'verified') then
    new.completed_at      := now();
    new.completion_state  := coalesce(old.completion_state, 'pending_review');
    if new.started_at is not null then
      new.resolution_days :=
        greatest(1, extract(day from (now() - new.started_at))::integer);
    end if;
  end if;

  -- Sync tenant-visible request status
  update app.maintenance_requests
  set
    status = case new.status
      when 'new'             then 'submitted'
      when 'assigned'        then 'specialist_assigned'
      when 'in_progress'     then 'in_progress'
      when 'approval_needed' then 'waiting'
      when 'blocked'         then 'waiting'
      when 'completed'       then 'completed'
      when 'verified'        then 'completed'
      else 'under_review'
    end,
    resolved_at = case
      when new.status in ('completed', 'verified') then now()
      else null
    end
  where id = new.request_id;

  return new;
end;
$$;

drop trigger if exists trg_maintenance_ticket_updated on app.maintenance_tickets;
create trigger trg_maintenance_ticket_updated
  before update of status, completion_state on app.maintenance_tickets
  for each row execute function app.on_maintenance_ticket_updated();

drop trigger if exists trg_maintenance_tickets_updated_at on app.maintenance_tickets;
create trigger trg_maintenance_tickets_updated_at
  before update on app.maintenance_tickets
  for each row execute function app.set_updated_at();

-- ─── 11. RLS ─────────────────────────────────────────────────────────────────

alter table app.maintenance_categories        enable row level security;
alter table app.maintenance_areas             enable row level security;
alter table app.maintenance_urgency_levels    enable row level security;
alter table app.maintenance_request_statuses  enable row level security;
alter table app.maintenance_ticket_statuses   enable row level security;
alter table app.fundi_profiles                enable row level security;
alter table app.maintenance_requests          enable row level security;
alter table app.maintenance_tickets           enable row level security;
alter table app.maintenance_media             enable row level security;
alter table app.maintenance_approval_requests enable row level security;
alter table app.maintenance_activity_log      enable row level security;

-- Reference tables: any authenticated user may read
create policy "maintenance_categories_select"
  on app.maintenance_categories for select to authenticated using (true);

create policy "maintenance_areas_select"
  on app.maintenance_areas for select to authenticated using (true);

create policy "maintenance_urgency_levels_select"
  on app.maintenance_urgency_levels for select to authenticated using (true);

create policy "maintenance_request_statuses_select"
  on app.maintenance_request_statuses for select to authenticated using (true);

create policy "maintenance_ticket_statuses_select"
  on app.maintenance_ticket_statuses for select to authenticated using (true);

-- Fundi profiles: workspace members read; admins write
create policy "fundi_profiles_select"
  on app.fundi_profiles for select to authenticated
  using (app.is_active_member(workspace_id));

create policy "fundi_profiles_insert"
  on app.fundi_profiles for insert to authenticated
  with check (app.is_workspace_admin(workspace_id));

create policy "fundi_profiles_update"
  on app.fundi_profiles for update to authenticated
  using (app.is_workspace_admin(workspace_id));

-- Maintenance requests: tenants submit their own; workspace members read all
create policy "maintenance_requests_select"
  on app.maintenance_requests for select to authenticated
  using (
    tenant_user_id = auth.uid()
    or app.is_active_member(workspace_id)
  );

create policy "maintenance_requests_insert"
  on app.maintenance_requests for insert to authenticated
  with check (
    tenant_user_id = auth.uid()
    and exists (
      select 1 from app.unit_tenancies ut
      where ut.tenant_user_id = auth.uid()
        and ut.unit_id        = maintenance_requests.unit_id
        and ut.property_id    = maintenance_requests.property_id
        and ut.status         = 'active'
    )
  );

-- Tickets: workspace members only (not tenants directly)
create policy "maintenance_tickets_select"
  on app.maintenance_tickets for select to authenticated
  using (app.is_active_member(workspace_id));

create policy "maintenance_tickets_update"
  on app.maintenance_tickets for update to authenticated
  using (app.is_active_member(workspace_id));

-- Media: request owner + workspace members
create policy "maintenance_media_select"
  on app.maintenance_media for select to authenticated
  using (
    uploaded_by = auth.uid()
    or exists (
      select 1 from app.maintenance_requests r
      where r.id = request_id
        and (r.tenant_user_id = auth.uid() or app.is_active_member(r.workspace_id))
    )
  );

create policy "maintenance_media_insert"
  on app.maintenance_media for insert to authenticated
  with check (uploaded_by = auth.uid());

-- Approval requests: workspace members
create policy "maintenance_approval_requests_select"
  on app.maintenance_approval_requests for select to authenticated
  using (
    exists (
      select 1 from app.maintenance_tickets t
      where t.id = ticket_id and app.is_active_member(t.workspace_id)
    )
  );

create policy "maintenance_approval_requests_insert"
  on app.maintenance_approval_requests for insert to authenticated
  with check (requested_by = auth.uid());

create policy "maintenance_approval_requests_update"
  on app.maintenance_approval_requests for update to authenticated
  using (
    exists (
      select 1 from app.maintenance_tickets t
      where t.id = ticket_id and app.is_workspace_admin(t.workspace_id)
    )
  );

-- Activity log: actors + workspace members read; append-only (no update/delete)
create policy "maintenance_activity_log_select"
  on app.maintenance_activity_log for select to authenticated
  using (
    actor_id = auth.uid()
    or (ticket_id  is not null and exists (
          select 1 from app.maintenance_tickets t
          where t.id = ticket_id and app.is_active_member(t.workspace_id)))
    or (request_id is not null and exists (
          select 1 from app.maintenance_requests r
          where r.id = request_id and r.tenant_user_id = auth.uid()))
  );

-- ─── 12. Grants ───────────────────────────────────────────────────────────────

grant select on app.maintenance_categories        to authenticated;
grant select on app.maintenance_areas             to authenticated;
grant select on app.maintenance_urgency_levels    to authenticated;
grant select on app.maintenance_request_statuses  to authenticated;
grant select on app.maintenance_ticket_statuses   to authenticated;
grant select, insert, update on app.fundi_profiles                to authenticated;
grant select, insert         on app.maintenance_requests          to authenticated;
grant select, update         on app.maintenance_tickets           to authenticated;
grant select, insert         on app.maintenance_media             to authenticated;
grant select, insert, update on app.maintenance_approval_requests to authenticated;
grant select, insert         on app.maintenance_activity_log      to authenticated;

-- ─── 13. RPC: create_maintenance_request ─────────────────────────────────────
-- Called by the Flutter tenant app to submit a new request.
-- Validates tenancy, resolves FK IDs, generates reference, inserts record.
-- The trigger on maintenance_requests auto-creates the ticket.

create or replace function app.create_maintenance_request(
  p_property_id   uuid,
  p_unit_id       uuid,
  p_category_code text,
  p_area_code     text,
  p_description   text,
  p_urgency       text,
  p_title         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid          uuid := auth.uid();
  v_workspace_id uuid;
  v_category_id  uuid;
  v_area_id      uuid;
  v_priority     text;
  v_reference    text;
  v_title        text;
  v_req_id       uuid;
  v_ticket_id    uuid;
  v_ticket_ref   text;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Validate active tenancy
  if not exists (
    select 1 from app.unit_tenancies ut
    where ut.tenant_user_id = v_uid
      and ut.unit_id        = p_unit_id
      and ut.property_id    = p_property_id
      and ut.status         = 'active'
  ) then
    raise exception 'No active tenancy found for this unit' using errcode = 'P0001';
  end if;

  -- Resolve workspace
  select workspace_id into v_workspace_id
  from app.properties where id = p_property_id;

  if v_workspace_id is null then
    raise exception 'Property not found' using errcode = 'P0001';
  end if;

  -- Resolve category
  select id into v_category_id
  from app.maintenance_categories
  where code = p_category_code and is_active;

  if v_category_id is null then
    raise exception 'Unknown category: %', p_category_code using errcode = 'P0001';
  end if;

  -- Resolve area
  select id into v_area_id
  from app.maintenance_areas
  where code = p_area_code and is_active;

  if v_area_id is null then
    raise exception 'Unknown area: %', p_area_code using errcode = 'P0001';
  end if;

  -- Resolve priority from urgency
  select priority into v_priority
  from app.maintenance_urgency_levels where code = p_urgency;

  if v_priority is null then
    raise exception 'Unknown urgency: %', p_urgency using errcode = 'P0001';
  end if;

  -- Generate unique reference
  v_reference := app.generate_maintenance_reference();

  -- Build title (use explicit title if provided, otherwise derive from area + description)
  v_title := coalesce(
    nullif(trim(p_title), ''),
    (select label from app.maintenance_areas where id = v_area_id)
      || ' — '
      || left(trim(p_description), 60)
      || case when char_length(trim(p_description)) > 60 then '...' else '' end
  );

  -- Insert — trigger creates the ticket and seeds the activity log
  insert into app.maintenance_requests (
    reference, tenant_user_id, workspace_id, property_id, unit_id,
    title, description, category_id, area_id, urgency, priority
  ) values (
    v_reference, v_uid, v_workspace_id, p_property_id, p_unit_id,
    v_title, trim(p_description), v_category_id, v_area_id, p_urgency, v_priority
  )
  returning id into v_req_id;

  -- Fetch the auto-created ticket reference
  select id, reference into v_ticket_id, v_ticket_ref
  from app.maintenance_tickets where request_id = v_req_id;

  return jsonb_build_object(
    'request_id',       v_req_id,
    'ticket_id',        v_ticket_id,
    'reference',        v_reference,
    'ticket_reference', v_ticket_ref,
    'status',           'submitted'
  );
end;
$$;

grant execute on function app.create_maintenance_request(uuid,uuid,text,text,text,text,text) to authenticated;

-- ─── 14. RPC: get_tenant_maintenance_requests ────────────────────────────────
-- Returns all requests for the calling tenant with human-readable labels.

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
          c.code   as category_code,
          c.label  as category,
          a.code   as area_code,
          a.label  as area,
          r.urgency,
          r.priority,
          r.status,
          s.label  as status_label,
          -- Media URLs
          coalesce(
            (select jsonb_agg(
               jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type)
               order by m.uploaded_at
             )
             from app.maintenance_media m where m.request_id = r.id),
            '[]'::jsonb
          ) as media,
          r.created_at,
          r.updated_at,
          r.resolved_at
        from app.maintenance_requests r
        join app.maintenance_categories c on c.id = r.category_id
        join app.maintenance_areas      a on a.id = r.area_id
        join app.maintenance_request_statuses s on s.code = r.status
        where r.tenant_user_id = v_uid
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_tenant_maintenance_requests() to authenticated;

-- ─── 15. RPC: get_workspace_maintenance_tickets ───────────────────────────────
-- Returns all tickets for an owner workspace — powers the web Kanban board.

create or replace function app.get_workspace_maintenance_tickets(
  p_workspace_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          t.id                                                      as ticket_id,
          t.reference                                               as ticket_reference,
          r.id                                                      as request_id,
          r.reference                                               as request_reference,
          r.title,
          r.description,
          c.code                                                    as category_code,
          c.label                                                   as category,
          a.label                                                   as area,
          p.display_name                                            as property_name,
          t.property_id,
          t.unit_id,
          coalesce(nullif(trim(u.label), ''), 'Unit ' || u.id::text) as unit_name,
          t.urgency,
          t.priority,
          t.status                                                  as ticket_status,
          r.status                                                  as request_status,
          f.id                                                      as fundi_id,
          f.name                                                    as fundi_name,
          f.specialty                                               as fundi_specialty,
          f.phone                                                   as fundi_phone,
          f.rating                                                  as fundi_rating,
          f.completed_jobs                                          as fundi_completed_jobs,
          t.blocked_reason,
          t.estimated_cost,
          t.actual_cost,
          case
            when t.actual_cost is not null and t.estimated_cost is not null
            then t.actual_cost - t.estimated_cost
            else null
          end                                                       as budget_variance,
          t.resolution_days,
          t.completion_state,
          t.started_at,
          t.completed_at,
          t.assigned_at,
          coalesce(nullif(trim(prof.first_name || ' ' || prof.last_name), ' '), 'Tenant')
                                                                    as tenant_name,
          -- Pending approval request if any
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
          )                                                         as approval_request,
          -- Media
          coalesce(
            (select jsonb_agg(
               jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type, 'stage', m.stage)
               order by m.uploaded_at
             )
             from app.maintenance_media m where m.request_id = r.id),
            '[]'::jsonb
          )                                                         as media,
          -- Activity log (most recent 20 events)
          coalesce(
            (select jsonb_agg(
               jsonb_build_object(
                 'id',          al.id,
                 'event_type',  al.event_type,
                 'label',       al.label,
                 'actor_name',  al.actor_name,
                 'created_at',  al.created_at
               )
               order by al.created_at desc
             )
             from (
               select * from app.maintenance_activity_log
               where ticket_id = t.id
               order by created_at desc
               limit 20
             ) al),
            '[]'::jsonb
          )                                                         as activity_log,
          t.created_at,
          t.updated_at
        from app.maintenance_tickets t
        join app.maintenance_requests    r    on r.id   = t.request_id
        join app.maintenance_categories  c    on c.id   = t.category_id
        join app.maintenance_areas       a    on a.id   = r.area_id
        join app.properties              p    on p.id   = t.property_id
        join app.units                   u    on u.id   = t.unit_id
        join app.profiles                prof on prof.id = r.tenant_user_id
        left join app.fundi_profiles     f    on f.id   = t.assigned_fundi_id
        where t.workspace_id = p_workspace_id
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_workspace_maintenance_tickets(uuid) to authenticated;

-- ─── 16. RPC: assign_maintenance_ticket ──────────────────────────────────────

create or replace function app.assign_maintenance_ticket(
  p_ticket_id uuid,
  p_fundi_id  uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_fundi_name   text;
begin
  select workspace_id into v_workspace_id
  from app.maintenance_tickets where id = p_ticket_id;

  if not app.is_workspace_admin(v_workspace_id) then
    raise exception 'Only workspace admins can assign tickets' using errcode = 'P0401';
  end if;

  select name into v_fundi_name from app.fundi_profiles where id = p_fundi_id;

  update app.maintenance_tickets set
    assigned_fundi_id = p_fundi_id,
    assigned_at       = now(),
    status            = 'assigned'
  where id = p_ticket_id;

  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    p_ticket_id, 'assigned',
    'Assigned to ' || coalesce(v_fundi_name, 'fundi'),
    auth.uid(),
    coalesce((select first_name || ' ' || last_name from app.profiles where id = auth.uid()), 'Admin')
  );
end;
$$;

grant execute on function app.assign_maintenance_ticket(uuid, uuid) to authenticated;

-- ─── 17. RPC: update_maintenance_ticket_status ───────────────────────────────

create or replace function app.update_maintenance_ticket_status(
  p_ticket_id     uuid,
  p_status        text,
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
  from app.maintenance_tickets where id = p_ticket_id;

  if not app.is_active_member(v_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

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
    coalesce((select first_name || ' ' || last_name from app.profiles where id = auth.uid()), 'Admin')
  );
end;
$$;

grant execute on function app.update_maintenance_ticket_status(uuid, text, text) to authenticated;

-- ─── 18. RPC: update_maintenance_ticket_costs ────────────────────────────────
-- Future hook: fundi submits actual costs; triggers budget variance recalc.

create or replace function app.update_maintenance_ticket_costs(
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
  v_workspace_id uuid;
begin
  select workspace_id into v_workspace_id
  from app.maintenance_tickets where id = p_ticket_id;

  if not app.is_active_member(v_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

  update app.maintenance_tickets set
    estimated_cost = coalesce(p_estimated_cost, estimated_cost),
    actual_cost    = coalesce(p_actual_cost, actual_cost)
  where id = p_ticket_id;

  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name, metadata)
  values (
    p_ticket_id, 'status_changed',
    'Costs updated'
      || case when p_estimated_cost is not null then ' — Est: Ksh ' || p_estimated_cost::text else '' end
      || case when p_actual_cost    is not null then ' / Actual: Ksh ' || p_actual_cost::text    else '' end,
    auth.uid(),
    coalesce((select first_name || ' ' || last_name from app.profiles where id = auth.uid()), 'Admin'),
    jsonb_build_object('estimated_cost', p_estimated_cost, 'actual_cost', p_actual_cost)
  );
end;
$$;

grant execute on function app.update_maintenance_ticket_costs(uuid, numeric, numeric) to authenticated;

-- ─── 19. RPC: request_maintenance_approval ───────────────────────────────────

create or replace function app.request_maintenance_approval(
  p_ticket_id        uuid,
  p_reason           text,
  p_requested_amount numeric default null,
  p_note             text    default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_approval_id  uuid;
begin
  select workspace_id into v_workspace_id
  from app.maintenance_tickets where id = p_ticket_id;

  if not app.is_active_member(v_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

  insert into app.maintenance_approval_requests
    (ticket_id, reason, requested_amount, note, requested_by)
  values
    (p_ticket_id, p_reason, p_requested_amount, p_note, auth.uid())
  returning id into v_approval_id;

  update app.maintenance_tickets set status = 'approval_needed' where id = p_ticket_id;

  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name, metadata)
  values (
    p_ticket_id, 'approval_requested',
    'Approval requested — ' || p_reason,
    auth.uid(),
    coalesce((select first_name || ' ' || last_name from app.profiles where id = auth.uid()), 'Fundi'),
    jsonb_build_object('approval_id', v_approval_id, 'requested_amount', p_requested_amount)
  );

  return v_approval_id;
end;
$$;

grant execute on function app.request_maintenance_approval(uuid, text, numeric, text) to authenticated;

-- ─── 20. RPC: resolve_maintenance_approval ───────────────────────────────────

create or replace function app.resolve_maintenance_approval(
  p_approval_id uuid,
  p_decision    text    -- 'approved' | 'rejected'
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_ticket_id    uuid;
  v_workspace_id uuid;
begin
  select t.id, t.workspace_id
  into v_ticket_id, v_workspace_id
  from app.maintenance_approval_requests ar
  join app.maintenance_tickets t on t.id = ar.ticket_id
  where ar.id = p_approval_id;

  if not app.is_workspace_admin(v_workspace_id) then
    raise exception 'Only workspace admins can resolve approvals' using errcode = 'P0401';
  end if;

  update app.maintenance_approval_requests set
    status      = p_decision,
    resolved_by = auth.uid(),
    resolved_at = now()
  where id = p_approval_id;

  -- Approved → back to in_progress; Rejected → back to assigned
  update app.maintenance_tickets set
    status = case p_decision when 'approved' then 'in_progress' else 'assigned' end
  where id = v_ticket_id;

  insert into app.maintenance_activity_log
    (ticket_id, event_type, label, actor_id, actor_name)
  values (
    v_ticket_id, 'approval_resolved',
    'Approval ' || p_decision || ' by owner',
    auth.uid(),
    coalesce((select first_name || ' ' || last_name from app.profiles where id = auth.uid()), 'Admin')
  );
end;
$$;

grant execute on function app.resolve_maintenance_approval(uuid, text) to authenticated;

-- ─── 21. Dashboard aggregate: maintenance_summary ────────────────────────────
-- Used by owner dashboard KPI cards and property stats.
-- Returns aggregate counts + cost totals per workspace.

create or replace function app.get_maintenance_summary(
  p_workspace_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0401';
  end if;

  return (
    select jsonb_build_object(
      'total',               count(*),
      'pending',             count(*) filter (where t.status = 'new'),
      'in_progress',         count(*) filter (where t.status = 'in_progress'),
      'approval_needed',     count(*) filter (where t.status = 'approval_needed'),
      'blocked',             count(*) filter (where t.status = 'blocked'),
      'completed',           count(*) filter (where t.status in ('completed', 'verified')),
      'avg_resolution_days', round(avg(t.resolution_days) filter (where t.resolution_days is not null), 1),
      'total_estimated_cost',coalesce(sum(t.estimated_cost), 0),
      'total_actual_cost',   coalesce(sum(t.actual_cost), 0)
    )
    from app.maintenance_tickets t
    where t.workspace_id = p_workspace_id
  );
end;
$$;

grant execute on function app.get_maintenance_summary(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Maintenance media storage bucket and policies
-- ----------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'maintenance-media',
  'maintenance-media',
  true,
  10485760,  -- 10 MB per file
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'video/mp4']
)
on conflict (id) do update
  set public             = true,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Any authenticated user can upload (RLS on maintenance_media table enforces tenancy)
create policy "maintenance_media_storage_insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'maintenance-media');

-- Public read — bucket is public so this is a formality but good for RLS completeness
-- Uploader can delete their own files
create policy "maintenance_media_storage_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'maintenance-media'
    and owner = auth.uid()
  );

-- ----------------------------------------------------------------------------
-- Maintenance realtime publication
-- ----------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'app'
        and tablename = 'maintenance_requests'
    ) then
      alter publication supabase_realtime add table app.maintenance_requests;
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'app'
        and tablename = 'maintenance_media'
    ) then
      alter publication supabase_realtime add table app.maintenance_media;
    end if;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Service provider invitation registry and RPCs
-- ----------------------------------------------------------------------------

create table if not exists app.vendor_invites (
  id               uuid primary key default gen_random_uuid(),
  workspace_id     uuid not null references app.workspaces(id) on delete cascade,

  -- Provider type
  profile_type     text not null check (profile_type in ('individual', 'company')),

  -- Individual Fundi fields
  full_name        text,
  email            text not null,
  phone            text,
  id_number        text,

  -- Company fields
  company_name     text,
  company_email    text,
  company_phone    text,
  contact_person   text,

  -- Service profile
  specializations  text[]      not null default '{}',
  regions          jsonb       not null default '[]',
  -- regions shape: [{ placeId, name, lat, lng }]

  -- Invite tracking
  status           text        not null default 'pending'
                   check (status in ('pending', 'accepted', 'declined')),
  token            text        unique not null
                   default encode(extensions.gen_random_bytes(32), 'hex'),
  invited_by       uuid        not null references auth.users(id) on delete restrict,
  invited_at       timestamptz not null default now(),
  accepted_at      timestamptz,

  -- Linked fundi profile once accepted
  fundi_profile_id uuid        references app.fundi_profiles(id) on delete set null
);

create index if not exists idx_vendor_invites_workspace
  on app.vendor_invites (workspace_id);
create index if not exists idx_vendor_invites_email
  on app.vendor_invites (email);
create index if not exists idx_vendor_invites_token
  on app.vendor_invites (token);
create index if not exists idx_vendor_invites_status
  on app.vendor_invites (workspace_id, status);

-- ─── 2. RLS ───────────────────────────────────────────────────────────────────

alter table app.vendor_invites enable row level security;

create policy "vendor_invites_select"
  on app.vendor_invites for select to authenticated
  using (app.is_active_member(workspace_id));

create policy "vendor_invites_insert"
  on app.vendor_invites for insert to authenticated
  with check (
    app.is_active_member(workspace_id)
    and invited_by = auth.uid()
  );

create policy "vendor_invites_update"
  on app.vendor_invites for update to authenticated
  using (app.is_active_member(workspace_id));

grant select, insert, update on app.vendor_invites to authenticated;

-- ─── 3. RPC: invite_service_provider ──────────────────────────────────────────

create or replace function app.invite_service_provider(
  p_workspace_id    uuid,
  p_profile_type    text,
  p_email           text,
  p_full_name       text     default null,
  p_phone           text     default null,
  p_id_number       text     default null,
  p_company_name    text     default null,
  p_company_email   text     default null,
  p_company_phone   text     default null,
  p_contact_person  text     default null,
  p_specializations text[]   default '{}',
  p_regions         jsonb    default '[]'
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite_id        uuid;
  v_token            text;
  v_email            text;
  v_existing_user_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0403';
  end if;

  if p_email is null or char_length(trim(p_email)) < 3 then
    raise exception 'A valid email address is required';
  end if;
  v_email := trim(lower(p_email));

  select u.id
    into v_existing_user_id
  from auth.users u
  where lower(trim(coalesce(u.email, ''))) = v_email
  limit 1;

  if v_existing_user_id is not null then
    raise exception 'An account with this email already exists. Ask the provider to sign in with that email instead of sending a new invite.';
  end if;

  if p_profile_type not in ('individual', 'company') then
    raise exception 'profile_type must be individual or company';
  end if;

  insert into app.vendor_invites (
    workspace_id, profile_type,
    full_name, email, phone, id_number,
    company_name, company_email, company_phone, contact_person,
    specializations, regions, invited_by
  ) values (
    p_workspace_id, p_profile_type,
    nullif(trim(coalesce(p_full_name, '')), ''),
    v_email,
    nullif(trim(coalesce(p_phone, '')), ''),
    nullif(trim(coalesce(p_id_number, '')), ''),
    nullif(trim(coalesce(p_company_name, '')), ''),
    nullif(trim(lower(coalesce(p_company_email, ''))), ''),
    nullif(trim(coalesce(p_company_phone, '')), ''),
    nullif(trim(coalesce(p_contact_person, '')), ''),
    p_specializations,
    p_regions,
    auth.uid()
  )
  returning id, token into v_invite_id, v_token;

  -- Email delivery is handled by the application layer using the returned token.
  -- The caller constructs the invite URL: /join/vendor?token={v_token}

  return jsonb_build_object(
    'invite_id', v_invite_id,
    'token',     v_token,
    'email',     v_email
  );
end;
$$;

grant execute on function app.invite_service_provider(
  uuid, text, text, text, text, text, text, text, text, text, text[], jsonb
) to authenticated;

-- ─── 4. RPC: get_workspace_vendor_invites ─────────────────────────────────────

create or replace function app.get_workspace_vendor_invites(p_workspace_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0403';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.invited_at desc)
      from (
        select
          vi.id,
          vi.profile_type,
          coalesce(vi.full_name, vi.company_name)   as display_name,
          coalesce(vi.email, vi.company_email)       as display_email,
          coalesce(vi.phone, vi.company_phone)       as display_phone,
          vi.specializations,
          vi.regions,
          vi.status,
          vi.invited_at,
          vi.accepted_at
        from app.vendor_invites vi
        where vi.workspace_id = p_workspace_id
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_workspace_vendor_invites(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Vendor invite uniqueness and resend flow
-- ----------------------------------------------------------------------------

delete from app.vendor_invites
where id not in (
  select distinct on (workspace_id, email) id
  from app.vendor_invites
  order by workspace_id, email, invited_at desc
);

-- 2. Unique constraint
alter table app.vendor_invites
  add constraint uq_vendor_invites_workspace_email
  unique (workspace_id, email);

-- 3. Update RPC to upsert (do nothing on conflict) so callers get a clean error
--    The application layer handles the conflict and returns a friendly message.

-- 4. RPC: resend_vendor_invite — refresh invited_at and return fresh token
create or replace function app.resend_vendor_invite(p_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite app.vendor_invites;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select * into v_invite
  from app.vendor_invites
  where id = p_invite_id;

  if not found then
    raise exception 'Invite not found' using errcode = 'P0404';
  end if;

  if not app.is_active_member(v_invite.workspace_id) then
    raise exception 'Access denied' using errcode = 'P0403';
  end if;

  -- Refresh timestamp so recipients know it is a new send
  update app.vendor_invites
  set invited_at = now()
  where id = p_invite_id;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'token',     v_invite.token,
    'email',     v_invite.email
  );
end;
$$;

grant execute on function app.resend_vendor_invite(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Vendor acceptance flow and provider self-service RPCs
-- ----------------------------------------------------------------------------

alter table app.vendor_invites
  add column if not exists user_id uuid references auth.users(id) on delete set null;

-- Link fundi profile to auth user (one profile per user)
alter table app.fundi_profiles
  add column if not exists user_id uuid unique references auth.users(id) on delete set null;

-- ─── 2. RPC: get_vendor_invite_by_token (public — no auth required) ───────────
-- Used by the invite acceptance page to pre-fill the form.

create or replace function public.get_vendor_invite_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_invite app.vendor_invites;
begin
  select * into v_invite
  from app.vendor_invites
  where token = p_token
    and status = 'pending';

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id',              v_invite.id,
    'profile_type',    v_invite.profile_type,
    'full_name',       v_invite.full_name,
    'company_name',    v_invite.company_name,
    'contact_person',  v_invite.contact_person,
    'email',           v_invite.email,
    'phone',           coalesce(v_invite.phone, v_invite.company_phone),
    'specializations', v_invite.specializations,
    'regions',         v_invite.regions,
    'workspace_id',    v_invite.workspace_id
  );
end;
$$;

grant execute on function public.get_vendor_invite_by_token(text) to anon, authenticated;

-- ─── 3. RPC: accept_vendor_invite (authenticated) ────────────────────────────
-- Called after OTP verification. Creates the fundi_profile and marks invite accepted.

create or replace function app.accept_vendor_invite(
  p_token    text,
  p_name     text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_invite   app.vendor_invites;
  v_profile  app.fundi_profiles;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Find the invite (allow re-accepting for idempotency)
  select * into v_invite
  from app.vendor_invites
  where token = p_token
    and status in ('pending', 'accepted');

  if not found then
    raise exception 'Invite not found or already declined' using errcode = 'P0404';
  end if;

  -- Upsert fundi profile (idempotent)
  insert into app.fundi_profiles (
    workspace_id,
    user_id,
    name,
    specialty,
    phone,
    available
  ) values (
    v_invite.workspace_id,
    v_user_id,
    coalesce(
      nullif(trim(coalesce(p_name, '')), ''),
      v_invite.full_name,
      v_invite.contact_person,
      v_invite.company_name,
      'Provider'
    ),
    -- Use first specialization as primary specialty
    coalesce(v_invite.specializations[1], 'general_repairs'),
    coalesce(v_invite.phone, v_invite.company_phone),
    true
  )
  on conflict (user_id)
    do update set
      name      = excluded.name,
      specialty = excluded.specialty,
      phone     = excluded.phone,
      updated_at = now()
  returning * into v_profile;

  -- Mark invite as accepted
  update app.vendor_invites
  set status     = 'accepted',
      user_id    = v_user_id,
      accepted_at = now()
  where id = v_invite.id;

  return jsonb_build_object(
    'fundi_profile_id', v_profile.id,
    'workspace_id',     v_invite.workspace_id,
    'name',             v_profile.name,
    'specializations',  v_invite.specializations,
    'regions',          v_invite.regions
  );
end;
$$;

grant execute on function app.accept_vendor_invite(text, text) to authenticated;

-- ─── 4. RPC: get_my_provider_profile (authenticated) ─────────────────────────
-- Returns the provider's profile and assigned tickets count.

create or replace function app.get_my_provider_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile app.fundi_profiles;
  v_invite  app.vendor_invites;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select * into v_profile
  from app.fundi_profiles
  where user_id = v_user_id
  limit 1;

  if not found then
    return null;
  end if;

  select * into v_invite
  from app.vendor_invites
  where user_id = v_user_id
  limit 1;

  return jsonb_build_object(
    'id',              v_profile.id,
    'name',            v_profile.name,
    'specialty',       v_profile.specialty,
    'phone',           v_profile.phone,
    'rating',          v_profile.rating,
    'completed_jobs',  v_profile.completed_jobs,
    'available',       v_profile.available,
    'workspace_id',    v_profile.workspace_id,
    'specializations', coalesce(v_invite.specializations, '[]'::jsonb),
    'regions',         coalesce(v_invite.regions, '[]'::jsonb),
    'profile_type',    coalesce(v_invite.profile_type, 'individual')
  );
end;
$$;

grant execute on function app.get_my_provider_profile() to authenticated;

-- ─── 5. RPC: get_my_assigned_tickets ─────────────────────────────────────────
-- Returns maintenance tickets assigned to the authenticated provider.

create or replace function app.get_my_assigned_tickets()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id   uuid := auth.uid();
  v_profile   app.fundi_profiles;
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
          t.id                                                    as ticket_id,
          t.reference                                             as ticket_reference,
          r.title,
          r.description,
          c.label                                                 as category,
          a.label                                                 as area,
          p.display_name                                          as property_name,
          coalesce(nullif(trim(u.label), ''), 'Unit')             as unit_name,
          t.priority,
          t.status,
          t.estimated_cost,
          t.actual_cost,
          t.assigned_at,
          t.started_at,
          t.completed_at,
          t.created_at
        from app.maintenance_tickets   t
        join app.maintenance_requests  r on r.id = t.request_id
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

-- ─── 6. RLS update: provider can see their own fundi profile ──────────────────

create policy "fundi_profiles_self_select"
  on app.fundi_profiles for select to authenticated
  using (user_id = auth.uid());

create policy "fundi_profiles_self_update"
  on app.fundi_profiles for update to authenticated
  using (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- Provider kanban RPC
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- Provider cost updates and media-enriched ticket feed
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- Provider ticket movement workflow
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- Tenant maintenance feed assigned-provider details
-- ----------------------------------------------------------------------------

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
