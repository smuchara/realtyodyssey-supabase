-- ============================================================================
-- V 1 03: Property Domain and Onboarding Runtime
-- ============================================================================
-- Purpose
--   - Create the core property and unit hierarchy
--   - Create document and accountability-supporting domain tables
--   - Create collaboration membership and invite runtime tables
--   - Create onboarding session state tables
--   - Create audit log storage for property-domain events
--
-- Notes
--   - Security helpers, RLS, grants, and RPCs are intentionally deferred to
--     later migrations.
--   - This migration absorbs earlier table-shape patches so the resulting
--     schema starts from the final working form.
-- ============================================================================

create schema if not exists app;

create table if not exists app.properties (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_type_id uuid not null references app.lookup_property_types(id) on delete restrict,
  usage_type_id uuid references app.lookup_usage_types(id) on delete restrict,
  status app.property_status_enum not null default 'draft',
  display_name text not null,
  internal_ref_code text,
  city_town text,
  area_neighborhood text,
  address_description text,
  map_source_id uuid references app.lookup_map_sources(id) on delete restrict,
  place_id text,
  latitude double precision,
  longitude double precision,
  map_label text,
  identity_completed_at timestamptz,
  onboarding_completed_at timestamptz,
  current_step_key text not null default 'identity',
  last_activity_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_properties_display_name_len
    check (char_length(trim(display_name)) between 2 and 120)
);

drop trigger if exists trg_properties_updated_at on app.properties;
create trigger trg_properties_updated_at
before update on app.properties
for each row execute function app.set_updated_at();

create index if not exists idx_properties_workspace_id
  on app.properties (workspace_id);

create index if not exists idx_properties_status
  on app.properties (status);

create index if not exists idx_properties_last_activity_at
  on app.properties (last_activity_at);

create index if not exists idx_properties_workspace_deleted
  on app.properties (workspace_id, deleted_at);

create table if not exists app.units (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  label text,
  floor text,
  block text,
  preset_id uuid references app.lookup_unit_presets(id) on delete set null,
  home_type_id uuid references app.lookup_home_types(id) on delete set null,
  bedrooms integer not null default 0,
  bathrooms integer not null default 0,
  parking integer not null default 0,
  balconies integer not null default 0,
  lift_access_type_id uuid references app.lookup_lift_access_types(id) on delete set null,
  garage_slots integer not null default 0,
  waste_disposal_type_id uuid references app.lookup_waste_disposal_types(id) on delete set null,
  layout_type_id uuid references app.lookup_layout_types(id) on delete set null,
  water_meter_number text,
  electricity_meter_number text,
  expected_rate numeric(12, 2),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_units_bedrooms_non_negative check (bedrooms >= 0),
  constraint chk_units_bathrooms_non_negative check (bathrooms >= 0),
  constraint chk_units_parking_non_negative check (parking >= 0),
  constraint chk_units_balconies_non_negative check (balconies >= 0),
  constraint chk_units_garage_slots_non_negative check (garage_slots >= 0),
  constraint chk_units_water_meter_len
    check (
      water_meter_number is null
      or char_length(trim(water_meter_number)) between 1 and 100
    ),
  constraint chk_units_electricity_meter_len
    check (
      electricity_meter_number is null
      or char_length(trim(electricity_meter_number)) between 1 and 100
    )
);

drop trigger if exists trg_units_updated_at on app.units;
create trigger trg_units_updated_at
before update on app.units
for each row execute function app.set_updated_at();

create index if not exists idx_units_property_id
  on app.units (property_id);

create index if not exists idx_units_property_deleted
  on app.units (property_id, deleted_at);

create index if not exists idx_units_water_meter_number
  on app.units (water_meter_number)
  where deleted_at is null and water_meter_number is not null;

create index if not exists idx_units_electricity_meter_number
  on app.units (electricity_meter_number)
  where deleted_at is null and electricity_meter_number is not null;

create unique index if not exists uq_units_property_label_active
  on app.units (property_id, lower(label))
  where deleted_at is null
    and label is not null
    and length(trim(label)) > 0;

create unique index if not exists uq_units_property_water_meter_active
  on app.units (property_id, lower(trim(water_meter_number)))
  where deleted_at is null
    and water_meter_number is not null
    and length(trim(water_meter_number)) > 0;

create unique index if not exists uq_units_property_electricity_meter_active
  on app.units (property_id, lower(trim(electricity_meter_number)))
  where deleted_at is null
    and electricity_meter_number is not null
    and length(trim(electricity_meter_number)) > 0;

create table if not exists app.property_documents (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid references app.units(id) on delete set null,
  document_type_id uuid not null references app.lookup_document_types(id) on delete restrict,
  storage_bucket text not null default 'property-documents',
  storage_path text not null,
  file_name text,
  mime_type text,
  size_bytes bigint,
  verification_status_id uuid references app.lookup_verification_statuses(id) on delete set null,
  verified_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  verification_notes text,
  uploaded_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

drop trigger if exists trg_property_documents_updated_at on app.property_documents;
create trigger trg_property_documents_updated_at
before update on app.property_documents
for each row execute function app.set_updated_at();

create index if not exists idx_property_documents_property_id
  on app.property_documents (property_id);

create index if not exists idx_property_documents_unit_id
  on app.property_documents (unit_id);

create index if not exists idx_property_documents_property_deleted
  on app.property_documents (property_id, deleted_at);

create table if not exists app.property_admin_contacts (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  mode text not null default 'SELF',
  relationship_role_id uuid references app.lookup_relationship_roles(id) on delete set null,
  contact_name text,
  contact_email text,
  contact_phone text,
  notes text,
  linked_user_id uuid references auth.users(id) on delete set null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint uq_property_admin_contacts_property unique (property_id),
  constraint chk_property_admin_contacts_mode
    check (mode in ('SELF', 'DELEGATED'))
);

drop trigger if exists trg_property_admin_contacts_updated_at on app.property_admin_contacts;
create trigger trg_property_admin_contacts_updated_at
before update on app.property_admin_contacts
for each row execute function app.set_updated_at();

create index if not exists idx_property_admin_contacts_linked_user_id
  on app.property_admin_contacts (linked_user_id);

create table if not exists app.property_memberships (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references app.roles(id) on delete restrict,
  domain_scope_id uuid not null references app.lookup_domain_scopes(id) on delete restrict,
  status text not null default 'active',
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_from_invite_id uuid,
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_property_memberships_status
    check (status in ('active', 'pending', 'suspended', 'revoked', 'expired'))
);

drop trigger if exists trg_property_memberships_updated_at on app.property_memberships;
create trigger trg_property_memberships_updated_at
before update on app.property_memberships
for each row execute function app.set_updated_at();

create index if not exists idx_property_memberships_property_id
  on app.property_memberships (property_id);

create index if not exists idx_property_memberships_user_id
  on app.property_memberships (user_id);

create index if not exists idx_property_memberships_domain_scope_id
  on app.property_memberships (domain_scope_id);

create index if not exists idx_property_memberships_property_status
  on app.property_memberships (property_id, status)
  where deleted_at is null;

create unique index if not exists uq_property_memberships_active_scope
  on app.property_memberships (property_id, user_id, domain_scope_id)
  where deleted_at is null
    and status = 'active';

create table if not exists app.collaboration_invites (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  invited_email text not null,
  invited_phone text,
  role_id uuid not null references app.roles(id) on delete restrict,
  domain_scope_id uuid not null references app.lookup_domain_scopes(id) on delete restrict,
  access_mode app.invite_access_mode_enum not null default 'temporary',
  status app.invite_status_enum not null default 'pending',
  token_hash text not null,
  expires_at timestamptz not null,
  invited_by uuid references auth.users(id) on delete set null,
  accepted_by uuid references auth.users(id) on delete set null,
  accepted_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_collaboration_invites_email_len
    check (char_length(trim(invited_email)) between 3 and 320)
);

drop trigger if exists trg_collaboration_invites_updated_at on app.collaboration_invites;
create trigger trg_collaboration_invites_updated_at
before update on app.collaboration_invites
for each row execute function app.set_updated_at();

create index if not exists idx_collaboration_invites_property_id
  on app.collaboration_invites (property_id);

create index if not exists idx_collaboration_invites_email_lower
  on app.collaboration_invites (lower(invited_email));

create unique index if not exists uq_collaboration_invites_token_hash
  on app.collaboration_invites (token_hash);

create index if not exists idx_collaboration_invites_status
  on app.collaboration_invites (status);

create index if not exists idx_collaboration_invites_expires_at
  on app.collaboration_invites (expires_at);

create index if not exists idx_collaboration_invites_property_status
  on app.collaboration_invites (property_id, status)
  where deleted_at is null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'fk_property_memberships_created_from_invite'
  ) then
    alter table app.property_memberships
      add constraint fk_property_memberships_created_from_invite
      foreign key (created_from_invite_id)
      references app.collaboration_invites(id)
      on delete set null;
  end if;
end
$$;

create table if not exists app.property_onboarding_sessions (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  status app.onboarding_session_status_enum not null default 'in_progress',
  current_step_key text not null default 'identity',
  started_by uuid not null references auth.users(id) on delete restrict,
  last_activity_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

drop trigger if exists trg_property_onboarding_sessions_updated_at on app.property_onboarding_sessions;
create trigger trg_property_onboarding_sessions_updated_at
before update on app.property_onboarding_sessions
for each row execute function app.set_updated_at();

create index if not exists idx_property_onboarding_sessions_property_id
  on app.property_onboarding_sessions (property_id);

create index if not exists idx_property_onboarding_sessions_status
  on app.property_onboarding_sessions (status);

create index if not exists idx_property_onboarding_sessions_last_activity_at
  on app.property_onboarding_sessions (last_activity_at);

create unique index if not exists uq_property_onboarding_sessions_active_property
  on app.property_onboarding_sessions (property_id)
  where deleted_at is null;

create table if not exists app.property_onboarding_step_states (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references app.property_onboarding_sessions(id) on delete cascade,
  step_key text not null,
  status app.onboarding_step_status_enum not null default 'not_started',
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  data_snapshot jsonb not null default '{}'::jsonb,
  locked_by uuid references auth.users(id) on delete set null,
  locked_at timestamptz,
  lock_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint uq_property_onboarding_step_states_session_step unique (session_id, step_key)
);

drop trigger if exists trg_property_onboarding_step_states_updated_at on app.property_onboarding_step_states;
create trigger trg_property_onboarding_step_states_updated_at
before update on app.property_onboarding_step_states
for each row execute function app.set_updated_at();

create index if not exists idx_property_onboarding_step_states_session_id
  on app.property_onboarding_step_states (session_id);

create index if not exists idx_property_onboarding_step_states_status
  on app.property_onboarding_step_states (status);

create index if not exists idx_property_onboarding_step_states_lock_expires_at
  on app.property_onboarding_step_states (lock_expires_at);

create index if not exists idx_property_onboarding_step_states_locked_by
  on app.property_onboarding_step_states (locked_by);

create table if not exists app.audit_logs (
  id uuid primary key default gen_random_uuid(),
  property_id uuid references app.properties(id) on delete set null,
  unit_id uuid references app.units(id) on delete set null,
  actor_user_id uuid references auth.users(id) on delete set null,
  action_type_id uuid not null references app.lookup_audit_action_types(id) on delete restrict,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create index if not exists idx_audit_logs_property_created_at
  on app.audit_logs (property_id, created_at desc);

create index if not exists idx_audit_logs_actor_created_at
  on app.audit_logs (actor_user_id, created_at desc);

create index if not exists idx_audit_logs_unit_created_at
  on app.audit_logs (unit_id, created_at desc);

create index if not exists idx_audit_logs_action_type_created_at
  on app.audit_logs (action_type_id, created_at desc);

create index if not exists idx_audit_logs_payload_gin
  on app.audit_logs
  using gin (payload);
