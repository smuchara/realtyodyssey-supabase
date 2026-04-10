-- ============================================================================
-- REBUILD 02: Reference Data and RBAC
-- ============================================================================
-- Purpose
--   - Create shared business enums used across property workflows
--   - Create lookup tables and RBAC tables
--   - Seed canonical reference data needed by later migrations
--
-- Notes
--   - This migration depends on REBUILD 01 for the app schema and the
--     app.set_updated_at() trigger helper.
--   - Security policies are intentionally deferred.
-- ============================================================================

create schema if not exists app;

do $$
begin
  create type app.property_status_enum as enum (
    'draft',
    'active',
    'archived'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type app.invite_status_enum as enum (
    'pending',
    'viewed',
    'accepted',
    'expired',
    'revoked'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type app.invite_access_mode_enum as enum (
    'temporary',
    'permanent'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type app.onboarding_session_status_enum as enum (
    'in_progress',
    'completed',
    'abandoned'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type app.onboarding_step_status_enum as enum (
    'not_started',
    'in_progress',
    'pending_collaboration',
    'completed'
  );
exception
  when duplicate_object then null;
end
$$;

create table if not exists app.lookup_property_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_usage_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_map_sources (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_layout_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_waste_disposal_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_lift_access_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_unit_presets (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  bedrooms integer not null default 0,
  bathrooms integer not null default 0,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_home_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_document_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_verification_statuses (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_relationship_roles (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_domain_scopes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.lookup_audit_action_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.roles (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name text not null,
  description text,
  is_system boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.permissions (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists app.role_permissions (
  role_id uuid not null references app.roles(id) on delete cascade,
  permission_id uuid not null references app.permissions(id) on delete cascade,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  primary key (role_id, permission_id)
);

create index if not exists idx_role_permissions_role_id
  on app.role_permissions (role_id);

create index if not exists idx_role_permissions_permission_id
  on app.role_permissions (permission_id);

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'lookup_property_types',
    'lookup_usage_types',
    'lookup_map_sources',
    'lookup_layout_types',
    'lookup_waste_disposal_types',
    'lookup_lift_access_types',
    'lookup_unit_presets',
    'lookup_home_types',
    'lookup_document_types',
    'lookup_verification_statuses',
    'lookup_relationship_roles',
    'lookup_domain_scopes',
    'lookup_audit_action_types',
    'roles',
    'permissions'
  ]
  loop
    execute format('drop trigger if exists trg_%I_updated_at on app.%I', v_table_name, v_table_name);
    execute format(
      'create trigger trg_%I_updated_at before update on app.%I for each row execute function app.set_updated_at()',
      v_table_name,
      v_table_name
    );
  end loop;
end
$$;

insert into app.lookup_property_types (code, label, description, sort_order)
values
  ('APARTMENT', 'Apartment', 'An individual unit within a residential building or complex', 1),
  ('HOUSE', 'House', 'A standalone house for rental or short-stay use', 2),
  ('BUILDING', 'Building', 'A full building owned and managed as one property', 3),
  ('COMMERCIAL', 'Commercial', 'Offices, retail stores, and other business units', 4)
on conflict (code) do nothing;

insert into app.lookup_usage_types (code, label, description, sort_order)
values
  ('LONG_TERM', 'Long-term Rental', 'Monthly or yearly rental agreements', 1),
  ('SHORT_TERM', 'Short-term Rental', 'Daily or weekly stays', 2),
  ('OWNER_OCCUPIED', 'Owner Occupied', 'Owner lives in the property', 3),
  ('VACANT', 'Vacant', 'Currently unoccupied', 4),
  ('MIXED', 'Mixed Use', 'Combination of residential and commercial use', 5)
on conflict (code) do nothing;

insert into app.lookup_map_sources (code, label, sort_order)
values
  ('GOOGLE_MAPS', 'Google Maps', 1),
  ('APPLE_MAPS', 'Apple Maps', 2),
  ('MANUAL', 'Manual Entry', 3)
on conflict (code) do nothing;

insert into app.lookup_layout_types (code, label, sort_order)
values
  ('OPEN_PLAN', 'Open Plan', 1),
  ('CLOSED', 'Closed / Traditional', 2),
  ('DUPLEX', 'Duplex', 3),
  ('LOFT', 'Loft', 4),
  ('STUDIO', 'Studio', 5),
  ('PENTHOUSE', 'Penthouse', 6)
on conflict (code) do nothing;

insert into app.lookup_waste_disposal_types (code, label, sort_order)
values
  ('BUILDING_MANAGED', 'Building Managed', 1),
  ('COUNTY_COLLECTION', 'County Collection', 2),
  ('PRIVATE_COLLECTOR', 'Private Collector', 3),
  ('SELF_MANAGED', 'Self Managed', 4),
  ('NONE', 'None', 5)
on conflict (code) do nothing;

insert into app.lookup_lift_access_types (code, label, sort_order)
values
  ('YES', 'Yes - Lift Available', 1),
  ('NO', 'No - Stairs Only', 2),
  ('PARTIAL', 'Partial - Some Floors Only', 3),
  ('SERVICE_ONLY', 'Service Lift Only', 4)
on conflict (code) do nothing;

insert into app.lookup_unit_presets (code, label, bedrooms, bathrooms, sort_order)
values
  ('BEDSITTER', 'Bedsitter', 0, 1, 1),
  ('STUDIO', 'Studio', 0, 1, 2),
  ('1BR', '1 Bedroom', 1, 1, 3),
  ('2BR', '2 Bedrooms', 2, 1, 4),
  ('3BR', '3 Bedrooms', 3, 2, 5),
  ('4BR', '4 Bedrooms', 4, 2, 6),
  ('5BR', '5 Bedrooms', 5, 3, 7),
  ('CUSTOM', 'Custom', 0, 0, 8)
on conflict (code) do nothing;

insert into app.lookup_home_types (code, label, description, sort_order)
values
  ('BUNGALOW', 'Bungalow', 'Single-storey detached house', 1),
  ('MAISONETTE', 'Maisonette', 'Two-storey unit with its own entrance', 2),
  ('VILLA', 'Villa', 'Large detached house, often with grounds', 3),
  ('TOWNHOUSE', 'Townhouse', 'Multi-storey terraced or semi-detached home', 4),
  ('COTTAGE', 'Cottage', 'Small rural or semi-rural house', 5),
  ('MANSION', 'Mansion', 'Large luxury residence', 6),
  ('OTHER', 'Other', 'Other type of home', 7)
on conflict (code) do nothing;

insert into app.lookup_document_types (code, label, description, sort_order)
values
  ('TITLE_DEED', 'Title Deed', 'Property ownership deed', 1),
  ('LEASE_AGREEMENT', 'Lease Agreement', 'Tenant and landlord lease contract', 2),
  ('SALE_AGREEMENT', 'Sale Agreement', 'Property sale and purchase agreement', 3),
  ('LAND_RATE_RECEIPT', 'Land Rate Receipt', 'County land rate clearance', 4),
  ('KRA_PIN', 'KRA PIN Certificate', 'Tax registration certificate', 5),
  ('UTILITY_BILL', 'Utility Bill', 'Electricity, water, or gas bill', 6),
  ('ID_DOCUMENT', 'ID Document', 'National ID, passport, or other identification', 7),
  ('PHOTO', 'Property Photo', 'Photos of the property', 8),
  ('OTHER', 'Other', 'Other supporting document', 9)
on conflict (code) do nothing;

insert into app.lookup_verification_statuses (code, label, sort_order)
values
  ('UNVERIFIED', 'Unverified', 1),
  ('PENDING', 'Pending Verification', 2),
  ('VERIFIED', 'Verified', 3),
  ('REJECTED', 'Rejected', 4)
on conflict (code) do nothing;

insert into app.lookup_relationship_roles (code, label, sort_order)
values
  ('OWNER', 'Owner', 1),
  ('SPOUSE', 'Spouse', 2),
  ('FAMILY_MEMBER', 'Family Member', 3),
  ('CARETAKER', 'Caretaker', 4),
  ('PROPERTY_MANAGER', 'Property Manager', 5),
  ('AGENT', 'Agent', 6),
  ('TENANT', 'Tenant', 7),
  ('OTHER', 'Other', 8)
on conflict (code) do nothing;

insert into app.lookup_domain_scopes (code, label, description, sort_order)
values
  ('FULL_PROPERTY', 'Full Property', 'Access to all property operations', 1),
  ('TENANCY', 'Tenancy', 'Tenant-related operations only', 2),
  ('MAINTENANCE', 'Maintenance', 'Maintenance and repair operations', 3),
  ('FINANCIAL', 'Financial', 'Financial and billing operations', 4),
  ('DOCUMENTS', 'Documents', 'Document management only', 5),
  ('UNITS', 'Units', 'Unit and structure operations', 6),
  ('OWNERSHIP', 'Ownership', 'Ownership and document verification operations', 7),
  ('ACCOUNTABILITY', 'Accountability', 'Property accountability operations', 8)
on conflict (code) do nothing;

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('PROPERTY_CREATED', 'Property Created', 1),
  ('PROPERTY_UPDATED', 'Property Updated', 2),
  ('PROPERTY_ACTIVATED', 'Property Activated', 3),
  ('PROPERTY_ARCHIVED', 'Property Archived', 4),
  ('PROPERTY_DELETED', 'Property Deleted', 5),
  ('ONBOARDING_STARTED', 'Onboarding Started', 6),
  ('ONBOARDING_STEP_UPDATED', 'Onboarding Step Updated', 7),
  ('ONBOARDING_COMPLETED', 'Onboarding Completed', 8),
  ('DOC_UPLOADED', 'Document Uploaded', 9),
  ('DOCUMENT_DELETED', 'Document Deleted', 10),
  ('UNIT_CREATED', 'Unit Created', 11),
  ('UNIT_UPDATED', 'Unit Updated', 12),
  ('INVITE_SENT', 'Invite Sent', 13),
  ('INVITE_ACCEPTED', 'Invite Accepted', 14),
  ('INVITE_REVOKED', 'Invite Revoked', 15),
  ('MEMBER_ADDED', 'Member Added', 16),
  ('MEMBER_REMOVED', 'Member Removed', 17),
  ('PCA_SET', 'Property Admin Contact Set', 18)
on conflict (code) do nothing;

insert into app.roles (key, name, description, is_system, is_active)
values
  ('OWNER', 'Owner', 'Property owner', true, true),
  ('CARETAKER', 'Caretaker', 'Property caretaker', true, true),
  ('PROPERTY_MANAGER', 'Property Manager / PCA', 'Principal contact agent', true, true),
  ('LEGAL', 'Legal Associate', 'Handles documents and verification', true, true),
  ('TENANT', 'Tenant', 'Individual leasing a unit', true, true)
on conflict (key) do nothing;
