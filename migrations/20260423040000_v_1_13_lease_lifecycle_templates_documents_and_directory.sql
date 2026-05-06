-- ============================================================================
-- V 1 13: Lease Lifecycle, Templates, Documents, and Directory
-- ============================================================================
-- Purpose
--   - Model reusable lease templates, versioning, invitation-time rendering, and immutable acceptance evidence.
--   - Expose tenant invite lookup, dispute handling, lease directory views, and signed document records.
--   - Keep executed lease content protected from later mutation.
--
-- Consolidated before first production publication. Earlier patch migrations
-- were folded into these domain files so a fresh reset replays the final
-- architecture without historical trial-and-error migration noise.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Lease template engine
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- ─── Enums ───────────────────────────────────────────────────────────────────

do $$ begin
  create type app.lease_template_status_enum as enum (
    'draft',      -- being authored, not usable
    'active',     -- available for use in invitations
    'archived'    -- no longer available for new invitations
  );
exception when duplicate_object then null; end $$;

-- ─── Audit action types ───────────────────────────────────────────────────────

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('LEASE_TEMPLATE_CREATED',          'Lease Template Created',           200),
  ('LEASE_TEMPLATE_VERSION_PUBLISHED','Lease Template Version Published',  201),
  ('LEASE_TEMPLATE_ARCHIVED',         'Lease Template Archived',          202)
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order;

-- ─── lease_templates ─────────────────────────────────────────────────────────
-- Reusable template identity and metadata.
-- Actual clause content lives in lease_template_versions.

create table if not exists app.lease_templates (
  id                      uuid primary key default gen_random_uuid(),
  workspace_id            uuid not null references app.workspaces(id) on delete restrict,
  property_id             uuid references app.properties(id) on delete set null,
  -- null property_id = workspace-wide template available to all properties

  name                    text not null,
  description             text,
  lease_type              app.lease_type_enum not null default 'fixed_term',
  property_category       text not null default 'apartment',
  -- apartment | standalone_house | estate_unit | commercial_space

  default_duration_months integer,
  -- null for month_to_month / informal / rolling

  renewal_behavior        text not null default 'manual'
                          check (renewal_behavior in ('manual', 'auto', 'converts_to_month_to_month')),

  notice_period_days      integer not null default 30
                          check (notice_period_days in (30, 60, 90)),

  status                  app.lease_template_status_enum not null default 'draft',

  created_by              uuid not null references auth.users(id) on delete restrict,
  updated_by              uuid references auth.users(id) on delete set null,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  deleted_at              timestamptz,

  constraint chk_lease_templates_name_len
    check (char_length(trim(name)) between 2 and 200),
  constraint chk_lease_templates_property_category
    check (property_category in ('apartment','standalone_house','estate_unit','commercial_space'))
);

drop trigger if exists trg_lease_templates_updated_at on app.lease_templates;
create trigger trg_lease_templates_updated_at
  before update on app.lease_templates
  for each row execute function app.set_updated_at();

create index if not exists idx_lease_templates_workspace
  on app.lease_templates (workspace_id);

create index if not exists idx_lease_templates_property
  on app.lease_templates (property_id)
  where property_id is not null;

create index if not exists idx_lease_templates_status
  on app.lease_templates (status)
  where deleted_at is null;

-- ─── lease_template_versions ─────────────────────────────────────────────────
-- Immutable snapshots of a template's clause content.
-- Once a version is referenced by a tenant_invitation or lease_agreement,
-- its `sections` column cannot be changed (enforced by trigger).
-- Status changes (e.g. active → archived) are always permitted.

create table if not exists app.lease_template_versions (
  id               uuid primary key default gen_random_uuid(),
  template_id      uuid not null references app.lease_templates(id) on delete restrict,

  version_number   integer not null check (version_number > 0),
  -- Monotonically increasing per template; enforced by application layer.

  version_label    text not null,
  -- Human-readable label, e.g. "v1.2". Stored separately from version_number
  -- so labels can follow semantic or date-based conventions.

  sections         jsonb not null,
  -- Array of section objects:
  -- [{
  --   "id": "parties",
  --   "section_number": 1,
  --   "title": "Parties to the Agreement",
  --   "content": "This Lease Agreement is entered into on {{lease.start_date}} ...",
  --   "required": true,
  --   "placeholder_keys": ["{{tenant.full_name}}", "{{lease.start_date}}"]
  -- }, ...]
  --
  -- IMMUTABLE once referenced by any invitation or lease (trigger enforces).

  placeholder_keys text[] not null default '{}',
  -- Extracted flat list of all {{key}} tokens across all sections.
  -- Populated by the Edge Function at publish time.

  change_note      text,
  -- What changed from the previous version. Required for version_number > 1.

  status           app.lease_template_status_enum not null default 'draft',

  published_at     timestamptz,
  published_by     uuid references auth.users(id) on delete set null,

  created_by       uuid not null references auth.users(id) on delete restrict,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint uq_lease_template_versions_number unique (template_id, version_number),
  constraint chk_lease_template_versions_label_len
    check (char_length(trim(version_label)) between 1 and 40)
);

drop trigger if exists trg_lease_template_versions_updated_at on app.lease_template_versions;
create trigger trg_lease_template_versions_updated_at
  before update on app.lease_template_versions
  for each row execute function app.set_updated_at();

create index if not exists idx_ltv_template
  on app.lease_template_versions (template_id);

create index if not exists idx_ltv_status
  on app.lease_template_versions (status);

create index if not exists idx_ltv_sections_gin
  on app.lease_template_versions using gin (sections);

-- ─── Immutability: block sections changes once version is referenced ──────────
-- Allows status, change_note, and metadata updates.
-- Raises an exception if sections or placeholder_keys are modified after the
-- version has been used in any invitation or lease agreement.

create or replace function app.trg_fn_protect_used_template_version()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  -- If sections and placeholder_keys are unchanged, allow any other column update.
  if (new.sections is not distinct from old.sections)
     and (new.placeholder_keys is not distinct from old.placeholder_keys) then
    return new;
  end if;

  -- Check if this version has been referenced.
  if exists (
    select 1
    from app.tenant_invitations
    where template_version_id = old.id
    limit 1
  ) or exists (
    select 1
    from app.lease_agreements
    where template_version_id = old.id
    limit 1
  ) then
    raise exception
      'Template version % cannot be modified — it has been referenced by an '
      'invitation or lease agreement. Create a new version instead.',
      old.id
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_used_template_version on app.lease_template_versions;
create trigger trg_protect_used_template_version
  before update on app.lease_template_versions
  for each row execute function app.trg_fn_protect_used_template_version();

-- ─── Extend: lease_agreements ─────────────────────────────────────────────────
-- Add template linkage, rendered content snapshot, and immutability anchor.
-- All columns are nullable and additive — existing rows and callers unaffected.

alter table app.lease_agreements
  add column if not exists template_version_id uuid
    references app.lease_template_versions(id) on delete set null,
  add column if not exists content_snapshot jsonb,
  -- Rendered sections JSONB (placeholders replaced with real tenant/unit/rent
  -- data). This is the legal clause content the tenant reviews and accepts.
  -- Separate from terms_snapshot (which holds owner-facing operational metadata).
  -- IMMUTABLE once locked_at IS NOT NULL (trigger enforces).
  add column if not exists locked_at timestamptz,
  -- Set when the tenant formally accepts the lease.
  -- Once set, content_snapshot cannot be modified.
  add column if not exists locked_by uuid
    references auth.users(id) on delete set null;

create index if not exists idx_lease_agreements_template_version
  on app.lease_agreements (template_version_id)
  where template_version_id is not null;

create index if not exists idx_lease_agreements_locked
  on app.lease_agreements (locked_at)
  where locked_at is not null;

-- ─── Immutability: protect locked lease content ───────────────────────────────

create or replace function app.trg_fn_protect_locked_lease_content()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if old.locked_at is not null then
    if new.content_snapshot is distinct from old.content_snapshot then
      raise exception
        'Cannot modify content_snapshot of locked lease agreement %. '
        'The legal content is immutable after tenant acceptance.',
        old.id
        using errcode = 'P0001';
    end if;
    if new.locked_at is distinct from old.locked_at then
      raise exception
        'Cannot modify locked_at of lease agreement % once it has been set.',
        old.id
        using errcode = 'P0001';
    end if;
    if new.locked_by is distinct from old.locked_by then
      raise exception
        'Cannot modify locked_by of lease agreement % once it has been set.',
        old.id
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_locked_lease_content on app.lease_agreements;
create trigger trg_protect_locked_lease_content
  before update on app.lease_agreements
  for each row execute function app.trg_fn_protect_locked_lease_content();

-- ─── Extend: tenant_invitations ──────────────────────────────────────────────
-- Add template reference columns. Nullable — existing invitations are unaffected.

alter table app.tenant_invitations
  add column if not exists template_id uuid
    references app.lease_templates(id) on delete set null,
  add column if not exists template_version_id uuid
    references app.lease_template_versions(id) on delete set null;

create index if not exists idx_tenant_invitations_template_version
  on app.tenant_invitations (template_version_id)
  where template_version_id is not null;

-- ─── RPCs ─────────────────────────────────────────────────────────────────────

-- app.create_lease_template
-- Creates a new template for the given workspace.
-- Returns the new template id.

create or replace function app.create_lease_template(
  p_workspace_id          uuid,
  p_name                  text,
  p_description           text default null,
  p_lease_type            app.lease_type_enum default 'fixed_term',
  p_property_category     text default 'apartment',
  p_default_duration_months integer default null,
  p_renewal_behavior      text default 'manual',
  p_notice_period_days    integer default 30,
  p_property_id           uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_template_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from app.workspaces w
    where w.id = p_workspace_id
      and (
        w.owner_user_id = auth.uid()
        or exists (
          select 1 from app.workspace_memberships wm
          where wm.workspace_id = p_workspace_id
            and wm.user_id = auth.uid()
            and wm.status = 'active'
        )
      )
  ) then
    raise exception 'Forbidden: you do not have access to this workspace';
  end if;

  if p_property_id is not null and not app.has_tenancy_management_access(
    (select property_id from app.properties where id = p_property_id and deleted_at is null limit 1)
  ) then
    raise exception 'Forbidden: you do not have access to this property';
  end if;

  insert into app.lease_templates (
    workspace_id, property_id, name, description, lease_type, property_category,
    default_duration_months, renewal_behavior, notice_period_days, status, created_by
  ) values (
    p_workspace_id, p_property_id, trim(p_name), nullif(trim(coalesce(p_description, '')), ''),
    p_lease_type, coalesce(p_property_category, 'apartment'),
    p_default_duration_months, coalesce(p_renewal_behavior, 'manual'),
    coalesce(p_notice_period_days, 30), 'draft', auth.uid()
  )
  returning id into v_template_id;

  return jsonb_build_object(
    'template_id', v_template_id,
    'status', 'draft'
  );
end;
$$;

-- app.create_lease_template_version
-- Creates a new version for an existing template.
-- The sections JSONB and placeholder_keys are provided by the caller
-- (typically the Edge Function after the user saves the template editor).

create or replace function app.create_lease_template_version(
  p_template_id       uuid,
  p_version_number    integer,
  p_version_label     text,
  p_sections          jsonb,
  p_placeholder_keys  text[] default '{}',
  p_change_note       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_template  record;
  v_version_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select t.*, w.owner_user_id
    into v_template
  from app.lease_templates t
  join app.workspaces w on w.id = t.workspace_id
  where t.id = p_template_id
    and t.deleted_at is null;

  if v_template.id is null then
    raise exception 'Template not found';
  end if;

  if v_template.status = 'archived' then
    raise exception 'Cannot add versions to an archived template';
  end if;

  -- Validate change_note for version > 1
  if p_version_number > 1 and (p_change_note is null or length(trim(p_change_note)) < 3) then
    raise exception 'A change note is required for template versions after the first';
  end if;

  if jsonb_typeof(p_sections) <> 'array' then
    raise exception 'sections must be a JSON array of clause objects';
  end if;

  insert into app.lease_template_versions (
    template_id, version_number, version_label, sections,
    placeholder_keys, change_note, status, created_by
  ) values (
    p_template_id, p_version_number, trim(p_version_label), p_sections,
    coalesce(p_placeholder_keys, '{}'), nullif(trim(coalesce(p_change_note, '')), ''),
    'draft', auth.uid()
  )
  returning id into v_version_id;

  return jsonb_build_object(
    'template_version_id', v_version_id,
    'template_id', p_template_id,
    'version_number', p_version_number,
    'version_label', p_version_label,
    'status', 'draft'
  );
end;
$$;

-- app.publish_lease_template_version
-- Marks a draft version as active (usable in invitations).
-- Supersedes any previously active version of the same template.

create or replace function app.publish_lease_template_version(
  p_template_version_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_version record;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select ltv.*, lt.workspace_id, lt.id as tmpl_id, lt.status as template_status
    into v_version
  from app.lease_template_versions ltv
  join app.lease_templates lt on lt.id = ltv.template_id
  where ltv.id = p_template_version_id;

  if v_version.id is null then
    raise exception 'Template version not found';
  end if;
  if v_version.template_status = 'archived' then
    raise exception 'Cannot publish a version belonging to an archived template';
  end if;
  if v_version.status = 'active' then
    return jsonb_build_object('template_version_id', p_template_version_id, 'status', 'active');
  end if;
  if v_version.status = 'archived' then
    raise exception 'Cannot publish an archived template version';
  end if;

  -- Archive other active versions of this template
  update app.lease_template_versions
     set status = 'archived', updated_at = now()
   where template_id = v_version.tmpl_id
     and status = 'active'
     and id <> p_template_version_id;

  -- Publish this version
  update app.lease_template_versions
     set status = 'active', published_at = now(), published_by = auth.uid(), updated_at = now()
   where id = p_template_version_id;

  -- Ensure the parent template is also active
  update app.lease_templates
     set status = 'active', updated_by = auth.uid(), updated_at = now()
   where id = v_version.tmpl_id
     and status = 'draft';

  return jsonb_build_object(
    'template_version_id', p_template_version_id,
    'template_id', v_version.tmpl_id,
    'status', 'active',
    'published_at', now()
  );
end;
$$;

-- app.get_lease_templates
-- Returns all active templates for the caller's accessible workspaces.
-- Includes the latest active version for each template.

create or replace function app.get_lease_templates(
  p_workspace_id  uuid default null,
  p_property_id   uuid default null,
  p_status        app.lease_template_status_enum default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return (
    select coalesce(jsonb_agg(row order by row.created_at desc), '[]'::jsonb)
    from (
      select
        t.id,
        t.workspace_id,
        t.property_id,
        t.name,
        t.description,
        t.lease_type,
        t.property_category,
        t.default_duration_months,
        t.renewal_behavior,
        t.notice_period_days,
        t.status,
        t.created_at,
        t.updated_at,
        -- Latest active version
        (
          select jsonb_build_object(
            'id', ltv.id,
            'version_number', ltv.version_number,
            'version_label', ltv.version_label,
            'status', ltv.status,
            'published_at', ltv.published_at,
            'placeholder_keys', ltv.placeholder_keys,
            'section_count', jsonb_array_length(coalesce(ltv.sections, '[]'::jsonb))
          )
          from app.lease_template_versions ltv
          where ltv.template_id = t.id
            and ltv.status = 'active'
          order by ltv.version_number desc
          limit 1
        ) as latest_active_version,
        -- Count of invitations using this template
        (
          select count(*)
          from app.tenant_invitations ti
          where ti.template_id = t.id
        ) as invitation_count
      from app.lease_templates t
      join app.workspaces w on w.id = t.workspace_id
      where t.deleted_at is null
        and (p_workspace_id is null or t.workspace_id = p_workspace_id)
        and (p_property_id is null or t.property_id = p_property_id or t.property_id is null)
        and (p_status is null or t.status = p_status)
        and (
          w.owner_user_id = auth.uid()
          or exists (
            select 1 from app.workspace_memberships wm
            where wm.workspace_id = t.workspace_id
              and wm.user_id = auth.uid()
              and wm.status = 'active'
          )
        )
    ) row
  );
end;
$$;

-- app.get_lease_template_version_sections
-- Returns the full sections JSONB for a specific template version.
-- Used by the Edge Function to render (fill placeholders) before calling
-- create_tenant_invitation().

create or replace function app.get_lease_template_version_sections(
  p_template_version_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_version record;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select ltv.sections, ltv.placeholder_keys, ltv.status,
         lt.workspace_id
    into v_version
  from app.lease_template_versions ltv
  join app.lease_templates lt on lt.id = ltv.template_id
  where ltv.id = p_template_version_id
    and lt.deleted_at is null;

  if v_version.workspace_id is null then
    raise exception 'Template version not found';
  end if;

  return jsonb_build_object(
    'template_version_id', p_template_version_id,
    'status', v_version.status,
    'sections', v_version.sections,
    'placeholder_keys', v_version.placeholder_keys
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on table app.lease_templates         from public, anon, authenticated;
revoke all on table app.lease_template_versions from public, anon, authenticated;

revoke all on function app.create_lease_template(uuid,text,text,app.lease_type_enum,text,integer,text,integer,uuid)
  from public, anon, authenticated;
revoke all on function app.create_lease_template_version(uuid,integer,text,jsonb,text[],text)
  from public, anon, authenticated;
revoke all on function app.publish_lease_template_version(uuid)
  from public, anon, authenticated;
revoke all on function app.get_lease_templates(uuid,uuid,app.lease_template_status_enum)
  from public, anon, authenticated;
revoke all on function app.get_lease_template_version_sections(uuid)
  from public, anon, authenticated;

grant execute on function app.create_lease_template(uuid,text,text,app.lease_type_enum,text,integer,text,integer,uuid)
  to authenticated;
grant execute on function app.create_lease_template_version(uuid,integer,text,jsonb,text[],text)
  to authenticated;
grant execute on function app.publish_lease_template_version(uuid)
  to authenticated;
grant execute on function app.get_lease_templates(uuid,uuid,app.lease_template_status_enum)
  to authenticated;
grant execute on function app.get_lease_template_version_sections(uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- Lease documents, acceptance evidence, and activity events
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- ─── Enums ───────────────────────────────────────────────────────────────────

do $$ begin
  create type app.lease_document_type_enum as enum (
    'lease_agreement',
    'amendment',
    'renewal_letter',
    'termination_notice',
    'acceptance_record',
    'rent_increase_notice',
    'service_charge_addendum',
    'inspection_report',
    'supporting_id',
    'other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.lease_document_status_enum as enum (
    'uploaded',    -- file uploaded, not yet linked to a specific lease version
    'attached',    -- linked to a lease agreement / version
    'verified',    -- reviewed and confirmed by property manager
    'superseded',  -- replaced by a newer version (original preserved)
    'archived'     -- no longer relevant but preserved for audit
  );
exception when duplicate_object then null; end $$;

-- ─── Audit action types ───────────────────────────────────────────────────────

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('LEASE_ACCEPTED_WITH_EVIDENCE',  'Lease Accepted With Evidence',   210),
  ('LEASE_DOCUMENT_UPLOADED',       'Lease Document Uploaded',        211),
  ('LEASE_DOCUMENT_VERIFIED',       'Lease Document Verified',        212),
  ('LEASE_ACTIVITY_RECORDED',       'Lease Activity Recorded',        213),
  ('LEASE_CONTENT_LOCKED',          'Lease Content Locked',           214)
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order;

-- ─── lease_acceptance_records ─────────────────────────────────────────────────
-- Immutable formal proof of tenant acceptance.
-- Written once via record_lease_acceptance().
-- The trigger below prevents any subsequent UPDATE or DELETE.

create table if not exists app.lease_acceptance_records (
  id                      uuid primary key default gen_random_uuid(),
  property_id             uuid not null references app.properties(id) on delete restrict,
  unit_id                 uuid not null references app.units(id) on delete restrict,
  lease_agreement_id      uuid not null references app.lease_agreements(id) on delete restrict,
  tenant_invitation_id    uuid references app.tenant_invitations(id) on delete set null,
  tenant_user_id          uuid not null references auth.users(id) on delete restrict,

  -- Identity evidence
  accepted_by_user_id     uuid not null references auth.users(id) on delete restrict,
  accepted_full_name      text not null,
  -- The exact name the tenant typed at acceptance time.
  checkbox_confirmed      boolean not null,
  -- Carries a CHECK constraint so false can never be stored.

  acceptance_method       text not null default 'checkbox_acknowledgment',
  -- Future values: 'digital_signature' | 'esign_docusign' etc.

  accepted_at             timestamptz not null default now(),

  -- Forensic metadata (nullable — populated when available from the mobile app)
  ip_address              text,
  user_agent              text,
  device_metadata         jsonb,

  created_at              timestamptz not null default now(),
  -- No updated_at — this record is immutable by design and trigger.

  constraint uq_lease_acceptance_records_per_lease
    unique (lease_agreement_id),
  -- One acceptance record per lease agreement.

  constraint chk_lease_acceptance_records_checkbox
    check (checkbox_confirmed = true),
  -- DB-level guarantee: false confirmation can never be stored.

  constraint chk_lease_acceptance_records_full_name_len
    check (char_length(trim(accepted_full_name)) between 2 and 200),

  constraint chk_lease_acceptance_records_acceptance_method
    check (acceptance_method in ('checkbox_acknowledgment', 'digital_signature'))
);

create index if not exists idx_lar_lease
  on app.lease_acceptance_records (lease_agreement_id);

create index if not exists idx_lar_tenant
  on app.lease_acceptance_records (tenant_user_id);

create index if not exists idx_lar_property
  on app.lease_acceptance_records (property_id);

-- ─── Immutability trigger: acceptance records ─────────────────────────────────

create or replace function app.trg_fn_protect_lease_acceptance_records()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception
      'Lease acceptance records are immutable and cannot be modified. '
      'They are permanent legal evidence. (record id: %)', old.id
      using errcode = 'P0001';
  elsif tg_op = 'DELETE' then
    raise exception
      'Lease acceptance records cannot be deleted — '
      'they are permanent legal evidence. (record id: %)', old.id
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_protect_lease_acceptance_records on app.lease_acceptance_records;
create trigger trg_protect_lease_acceptance_records
  before update or delete on app.lease_acceptance_records
  for each row execute function app.trg_fn_protect_lease_acceptance_records();

-- ─── lease_activity_events ────────────────────────────────────────────────────
-- Append-only audit trail for all legally relevant lease lifecycle events.
-- The trigger below prevents UPDATE and DELETE.
-- Use record_lease_activity() RPC to insert.

create table if not exists app.lease_activity_events (
  id                    uuid primary key default gen_random_uuid(),
  property_id           uuid references app.properties(id) on delete set null,
  unit_id               uuid references app.units(id) on delete set null,
  lease_agreement_id    uuid references app.lease_agreements(id) on delete set null,
  template_version_id   uuid references app.lease_template_versions(id) on delete set null,
  tenant_invitation_id  uuid references app.tenant_invitations(id) on delete set null,
  document_id           uuid,
  -- FK to lease_documents added after that table is created (below).

  actor_user_id         uuid references auth.users(id) on delete set null,

  event_type            text not null,
  event_title           text not null,
  event_description     text,
  metadata              jsonb,

  created_at            timestamptz not null default now(),
  -- No updated_at — append-only.

  constraint chk_lease_activity_events_event_type check (
    event_type in (
      -- Template lifecycle
      'template_created', 'template_version_published', 'template_archived',
      -- Invite + lease draft lifecycle
      'invite_created', 'invite_sent', 'invite_viewed', 'invite_expired', 'invite_cancelled',
      'lease_draft_created',
      -- Acceptance
      'lease_accepted', 'lease_accepted_with_evidence', 'lease_content_locked',
      'lease_activated', 'lease_disputed',
      -- Post-activation lifecycle
      'renewal_initiated', 'renewal_sent', 'renewal_accepted', 'renewal_declined',
      'amendment_created', 'amendment_sent', 'amendment_accepted', 'amendment_rejected',
      'termination_initiated', 'termination_notice_served', 'termination_completed',
      'lease_expiring_soon', 'lease_expired', 'lease_cancelled',
      -- Documents
      'document_uploaded', 'document_verified', 'document_superseded', 'document_archived',
      -- Export / compliance
      'case_file_prepared'
    )
  ),

  constraint chk_lease_activity_events_title_len
    check (char_length(trim(event_title)) between 2 and 300)
);

create index if not exists idx_lae_lease
  on app.lease_activity_events (lease_agreement_id)
  where lease_agreement_id is not null;

create index if not exists idx_lae_unit
  on app.lease_activity_events (unit_id)
  where unit_id is not null;

create index if not exists idx_lae_property
  on app.lease_activity_events (property_id)
  where property_id is not null;

create index if not exists idx_lae_event_type
  on app.lease_activity_events (event_type);

create index if not exists idx_lae_created_at
  on app.lease_activity_events (created_at desc);

create index if not exists idx_lae_invitation
  on app.lease_activity_events (tenant_invitation_id)
  where tenant_invitation_id is not null;

-- ─── Immutability trigger: activity events ────────────────────────────────────

create or replace function app.trg_fn_prevent_lease_activity_mutation()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception
      'Lease activity events are append-only and cannot be modified. (event id: %)', old.id
      using errcode = 'P0001';
  elsif tg_op = 'DELETE' then
    raise exception
      'Lease activity events form the legal audit trail and cannot be deleted. (event id: %)', old.id
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_prevent_lease_activity_mutation on app.lease_activity_events;
create trigger trg_prevent_lease_activity_mutation
  before update or delete on app.lease_activity_events
  for each row execute function app.trg_fn_prevent_lease_activity_mutation();

-- ─── lease_documents ─────────────────────────────────────────────────────────
-- Metadata for lease-related files stored in Supabase Storage.
-- Files are never overwritten — replacement creates a new row
-- (version_number++, previous row's status → 'superseded').

create table if not exists app.lease_documents (
  id                    uuid primary key default gen_random_uuid(),
  property_id           uuid not null references app.properties(id) on delete restrict,
  unit_id               uuid not null references app.units(id) on delete restrict,
  lease_agreement_id    uuid references app.lease_agreements(id) on delete set null,
  template_version_id   uuid references app.lease_template_versions(id) on delete set null,

  document_type         app.lease_document_type_enum not null,
  document_name         text not null,

  -- Storage location (Supabase Storage)
  storage_bucket        text not null default 'lease-documents',
  storage_path          text not null,
  -- e.g. '{workspace_id}/{property_id}/{unit_id}/{lease_id}/{uuid}.pdf'

  file_size_bytes       bigint,
  mime_type             text,

  -- Versioning: when a document is replaced, superseded_by points to the new row
  version_number        integer not null default 1 check (version_number > 0),
  superseded_by         uuid references app.lease_documents(id) on delete set null,

  status                app.lease_document_status_enum not null default 'uploaded',

  uploaded_by           uuid not null references auth.users(id) on delete restrict,
  uploaded_at           timestamptz not null default now(),

  verified_at           timestamptz,
  verified_by           uuid references auth.users(id) on delete set null,

  metadata              jsonb,
  -- e.g. { "original_filename": "lease_signed.pdf", "pages": 4 }

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint chk_lease_documents_name_len
    check (char_length(trim(document_name)) between 2 and 300),
  constraint chk_lease_documents_path_len
    check (char_length(trim(storage_path)) > 5),
  constraint chk_lease_documents_file_size
    check (file_size_bytes is null or file_size_bytes > 0)
);

drop trigger if exists trg_lease_documents_updated_at on app.lease_documents;
create trigger trg_lease_documents_updated_at
  before update on app.lease_documents
  for each row execute function app.set_updated_at();

create index if not exists idx_ld_lease
  on app.lease_documents (lease_agreement_id)
  where lease_agreement_id is not null;

create index if not exists idx_ld_unit
  on app.lease_documents (unit_id);

create index if not exists idx_ld_property
  on app.lease_documents (property_id);

create index if not exists idx_ld_type_status
  on app.lease_documents (document_type, status);

create index if not exists idx_ld_uploaded_at
  on app.lease_documents (uploaded_at desc);

-- Add document FK to activity events now that the table exists
alter table app.lease_activity_events
  add constraint fk_lae_document
    foreign key (document_id)
    references app.lease_documents(id)
    on delete set null;

create index if not exists idx_lae_document
  on app.lease_activity_events (document_id)
  where document_id is not null;

-- Property sync trigger for new tables (consistent with existing pattern)

drop trigger if exists trg_lease_acceptance_records_property_sync on app.lease_acceptance_records;
create trigger trg_lease_acceptance_records_property_sync
  before insert or update of unit_id, property_id on app.lease_acceptance_records
  for each row execute function app.sync_related_property_id_from_unit();

drop trigger if exists trg_lease_documents_property_sync on app.lease_documents;
create trigger trg_lease_documents_property_sync
  before insert or update of unit_id, property_id on app.lease_documents
  for each row execute function app.sync_related_property_id_from_unit();

-- ─── RPC: app.record_lease_activity ──────────────────────────────────────────
-- Append-only helper used by other RPCs and Edge Functions to write activity
-- events. Security definer so callers don't need direct table access.

create or replace function app.record_lease_activity(
  p_event_type          text,
  p_event_title         text,
  p_actor_user_id       uuid,
  p_property_id         uuid      default null,
  p_unit_id             uuid      default null,
  p_lease_agreement_id  uuid      default null,
  p_template_version_id uuid      default null,
  p_invitation_id       uuid      default null,
  p_document_id         uuid      default null,
  p_event_description   text      default null,
  p_metadata            jsonb     default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_event_id uuid;
begin
  insert into app.lease_activity_events (
    property_id, unit_id, lease_agreement_id, template_version_id,
    tenant_invitation_id, document_id, actor_user_id,
    event_type, event_title, event_description, metadata
  ) values (
    p_property_id, p_unit_id, p_lease_agreement_id, p_template_version_id,
    p_invitation_id, p_document_id, p_actor_user_id,
    p_event_type, p_event_title, p_event_description, p_metadata
  )
  returning id into v_event_id;

  return v_event_id;
end;
$$;

-- ─── RPC: app.record_lease_acceptance ────────────────────────────────────────
-- Called by the mobile app AFTER accept_tenant_invitation() succeeds.
-- Creates the immutable acceptance record, locks the content_snapshot,
-- and writes activity events.
--
-- The two-call pattern (accept then record_evidence) keeps the existing
-- RPC contract intact while adding the formal legal evidence layer.

create or replace function app.record_lease_acceptance(
  p_lease_agreement_id    uuid,
  p_checkbox_confirmed    boolean,
  p_accepted_full_name    text,
  p_ip_address            text    default null,
  p_user_agent            text    default null,
  p_device_metadata       jsonb   default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id       uuid := auth.uid();
  v_lease         record;
  v_invitation    record;
  v_acceptance_id uuid;
  v_event_id      uuid;
  v_clean_name    text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- ── Validate inputs ─────────────────────────────────────────────────────────
  if not coalesce(p_checkbox_confirmed, false) then
    raise exception 'ACCEPTANCE_REQUIRES_CHECKBOX: Checkbox confirmation is required'
      using errcode = 'P0001';
  end if;

  v_clean_name := nullif(trim(coalesce(p_accepted_full_name, '')), '');
  if v_clean_name is null or char_length(v_clean_name) < 2 then
    raise exception 'ACCEPTANCE_REQUIRES_NAME: Full name confirmation is required (min 2 characters)'
      using errcode = 'P0001';
  end if;

  -- ── Load and validate lease ──────────────────────────────────────────────────
  select
    l.id,
    l.property_id,
    l.unit_id,
    l.tenant_user_id,
    l.status,
    l.confirmation_status,
    l.template_version_id,
    l.locked_at
  into v_lease
  from app.lease_agreements l
  where l.id = p_lease_agreement_id
  for update;

  if v_lease.id is null then
    raise exception 'LEASE_NOT_FOUND: Lease agreement not found'
      using errcode = 'P0001';
  end if;

  -- Tenant must be the confirmed tenant on this lease
  if v_lease.tenant_user_id is distinct from v_user_id then
    raise exception 'FORBIDDEN: You are not the tenant on this lease agreement'
      using errcode = 'P0001';
  end if;

  -- Lease must be confirmed or active before recording evidence
  if v_lease.confirmation_status not in ('confirmed')
     and v_lease.status not in ('active', 'confirmed') then
    raise exception
      'LEASE_NOT_CONFIRMED: Lease must be confirmed by the system before recording acceptance evidence. '
      'Call accept_tenant_invitation() first. Current confirmation status: %',
      v_lease.confirmation_status
      using errcode = 'P0001';
  end if;

  -- Guard against duplicate acceptance records
  if exists (
    select 1 from app.lease_acceptance_records
    where lease_agreement_id = p_lease_agreement_id
  ) then
    raise exception
      'DUPLICATE_ACCEPTANCE: An acceptance record already exists for lease agreement %',
      p_lease_agreement_id
      using errcode = 'P0001';
  end if;

  -- ── Fetch linked invitation (for FK) ─────────────────────────────────────────
  select id into v_invitation
  from app.tenant_invitations
  where lease_agreement_id = p_lease_agreement_id
  limit 1;

  -- ── Create immutable acceptance record ───────────────────────────────────────
  insert into app.lease_acceptance_records (
    property_id,
    unit_id,
    lease_agreement_id,
    tenant_invitation_id,
    tenant_user_id,
    accepted_by_user_id,
    accepted_full_name,
    checkbox_confirmed,
    acceptance_method,
    accepted_at,
    ip_address,
    user_agent,
    device_metadata
  ) values (
    v_lease.property_id,
    v_lease.unit_id,
    p_lease_agreement_id,
    v_invitation.id,
    v_user_id,
    v_user_id,
    v_clean_name,
    true,
    'checkbox_acknowledgment',
    now(),
    nullif(trim(coalesce(p_ip_address, '')), ''),
    nullif(trim(coalesce(p_user_agent, '')), ''),
    p_device_metadata
  )
  returning id into v_acceptance_id;

  -- ── Lock the content_snapshot (if present) ───────────────────────────────────
  -- locked_at IS checked by the trigger — only set if not already locked.
  if v_lease.locked_at is null then
    update app.lease_agreements
       set locked_at = now(),
           locked_by = v_user_id,
           updated_at = now()
     where id = p_lease_agreement_id
       and locked_at is null;
  end if;

  -- ── Write audit log ───────────────────────────────────────────────────────────
  declare v_action_id uuid;
  begin
    v_action_id := app.get_audit_action_id_by_code('LEASE_ACCEPTED_WITH_EVIDENCE');
    if v_action_id is not null then
      insert into app.audit_logs (
        property_id, unit_id, actor_user_id, action_type_id, payload
      ) values (
        v_lease.property_id,
        v_lease.unit_id,
        v_user_id,
        v_action_id,
        jsonb_build_object(
          'acceptance_id',          v_acceptance_id,
          'lease_agreement_id',     p_lease_agreement_id,
          'accepted_full_name',     v_clean_name,
          'acceptance_method',      'checkbox_acknowledgment',
          'checkbox_confirmed',     true,
          'ip_address',             p_ip_address
        )
      );
    end if;
  end;

  -- ── Write activity event ──────────────────────────────────────────────────────
  v_event_id := app.record_lease_activity(
    p_event_type          => 'lease_accepted_with_evidence',
    p_event_title         => 'Lease accepted with formal confirmation',
    p_actor_user_id       => v_user_id,
    p_property_id         => v_lease.property_id,
    p_unit_id             => v_lease.unit_id,
    p_lease_agreement_id  => p_lease_agreement_id,
    p_template_version_id => v_lease.template_version_id,
    p_invitation_id       => v_invitation.id,
    p_event_description   => format(
      '"%s" confirmed acceptance via checkbox acknowledgment',
      v_clean_name
    ),
    p_metadata            => jsonb_build_object(
      'acceptance_id',      v_acceptance_id,
      'acceptance_method',  'checkbox_acknowledgment',
      'ip_address',         p_ip_address,
      'content_locked',     (v_lease.locked_at is null)
    )
  );

  return jsonb_build_object(
    'acceptance_id',          v_acceptance_id,
    'lease_agreement_id',     p_lease_agreement_id,
    'accepted_full_name',     v_clean_name,
    'accepted_at',            now(),
    'acceptance_method',      'checkbox_acknowledgment',
    'content_locked',         true,
    'activity_event_id',      v_event_id
  );
end;
$$;

-- ─── RPC: app.upload_lease_document ──────────────────────────────────────────
-- Registers a document that has already been uploaded to Supabase Storage.
-- The Edge Function uploads the file, then calls this RPC with the path.

create or replace function app.upload_lease_document(
  p_unit_id               uuid,
  p_storage_path          text,
  p_document_name         text,
  p_document_type         app.lease_document_type_enum,
  p_lease_agreement_id    uuid  default null,
  p_template_version_id   uuid  default null,
  p_file_size_bytes       bigint default null,
  p_mime_type             text   default null,
  p_storage_bucket        text   default 'lease-documents',
  p_metadata              jsonb  default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_unit       record;
  v_doc_id     uuid;
  v_version_no integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select u.id, u.property_id, p.display_name as property_name, p.status as property_status
    into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null;

  if v_unit.id is null then
    raise exception 'Unit not found or deleted';
  end if;

  perform app.assert_tenancy_management_access(v_unit.property_id);

  -- Version number for this document type on this unit
  select coalesce(max(d.version_number), 0) + 1
    into v_version_no
  from app.lease_documents d
  where d.unit_id = p_unit_id
    and d.document_type = p_document_type
    and (p_lease_agreement_id is null or d.lease_agreement_id = p_lease_agreement_id);

  -- Mark previous versions of the same type/lease as superseded
  if v_version_no > 1 then
    update app.lease_documents
       set status = 'superseded', updated_at = now()
     where unit_id = p_unit_id
       and document_type = p_document_type
       and (p_lease_agreement_id is null or lease_agreement_id = p_lease_agreement_id)
       and status not in ('superseded', 'archived');
  end if;

  insert into app.lease_documents (
    property_id, unit_id, lease_agreement_id, template_version_id,
    document_type, document_name, storage_bucket, storage_path,
    file_size_bytes, mime_type, version_number, status,
    uploaded_by, uploaded_at, metadata
  ) values (
    v_unit.property_id, p_unit_id, p_lease_agreement_id, p_template_version_id,
    p_document_type, trim(p_document_name),
    coalesce(nullif(trim(p_storage_bucket), ''), 'lease-documents'),
    trim(p_storage_path),
    p_file_size_bytes, p_mime_type, v_version_no,
    case when p_lease_agreement_id is not null then 'attached' else 'uploaded' end,
    v_user_id, now(), p_metadata
  )
  returning id into v_doc_id;

  -- Activity event
  perform app.record_lease_activity(
    p_event_type          => 'document_uploaded',
    p_event_title         => format('Document uploaded: %s', trim(p_document_name)),
    p_actor_user_id       => v_user_id,
    p_property_id         => v_unit.property_id,
    p_unit_id             => p_unit_id,
    p_lease_agreement_id  => p_lease_agreement_id,
    p_template_version_id => p_template_version_id,
    p_document_id         => v_doc_id,
    p_metadata            => jsonb_build_object(
      'document_id',      v_doc_id,
      'document_type',    p_document_type::text,
      'version_number',   v_version_no,
      'storage_path',     trim(p_storage_path)
    )
  );

  return jsonb_build_object(
    'document_id',      v_doc_id,
    'document_type',    p_document_type::text,
    'version_number',   v_version_no,
    'status',           case when p_lease_agreement_id is not null then 'attached' else 'uploaded' end,
    'storage_path',     trim(p_storage_path)
  );
end;
$$;

-- ─── RPC: app.verify_lease_document ──────────────────────────────────────────

create or replace function app.verify_lease_document(p_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_doc     record;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select d.id, d.property_id, d.unit_id, d.document_name, d.status,
         d.lease_agreement_id, d.template_version_id
    into v_doc
  from app.lease_documents d
  where d.id = p_document_id;

  if v_doc.id is null then
    raise exception 'Document not found';
  end if;

  perform app.assert_tenancy_management_access(v_doc.property_id);

  if v_doc.status = 'verified' then
    return jsonb_build_object('document_id', p_document_id, 'status', 'verified');
  end if;

  if v_doc.status in ('archived', 'superseded') then
    raise exception 'Cannot verify a document that is % ', v_doc.status;
  end if;

  update app.lease_documents
     set status = 'verified', verified_at = now(), verified_by = v_user_id, updated_at = now()
   where id = p_document_id;

  perform app.record_lease_activity(
    p_event_type          => 'document_verified',
    p_event_title         => format('Document verified: %s', v_doc.document_name),
    p_actor_user_id       => v_user_id,
    p_property_id         => v_doc.property_id,
    p_unit_id             => v_doc.unit_id,
    p_lease_agreement_id  => v_doc.lease_agreement_id,
    p_template_version_id => v_doc.template_version_id,
    p_document_id         => p_document_id
  );

  return jsonb_build_object('document_id', p_document_id, 'status', 'verified', 'verified_at', now());
end;
$$;

-- ─── RPC: app.get_lease_evidence_summary ─────────────────────────────────────
-- Returns the complete evidence state for a lease agreement.
-- Used by the compliance dashboard and the lease detail drawer.

create or replace function app.get_lease_evidence_summary(
  p_lease_agreement_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_lease   record;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select
    l.id, l.property_id, l.unit_id, l.status, l.confirmation_status,
    l.tenant_user_id, l.template_version_id, l.locked_at, l.content_snapshot
  into v_lease
  from app.lease_agreements l
  where l.id = p_lease_agreement_id;

  if v_lease.id is null then
    raise exception 'Lease agreement not found';
  end if;

  -- Either the tenant or a manager can query evidence
  if v_lease.tenant_user_id <> v_user_id
     and not app.has_tenancy_management_access(v_lease.property_id) then
    raise exception 'Forbidden: no access to this lease';
  end if;

  return jsonb_build_object(
    'lease_agreement_id',       p_lease_agreement_id,
    'status',                   v_lease.status::text,
    'confirmation_status',      v_lease.confirmation_status::text,
    'content_locked',           v_lease.locked_at is not null,
    'locked_at',                v_lease.locked_at,
    'has_content_snapshot',     v_lease.content_snapshot is not null,
    'template_version_id',      v_lease.template_version_id,

    -- Acceptance record
    'acceptance_record', (
      select jsonb_build_object(
        'id',                 ar.id,
        'accepted_full_name', ar.accepted_full_name,
        'acceptance_method',  ar.acceptance_method,
        'accepted_at',        ar.accepted_at,
        'ip_address',         ar.ip_address
      )
      from app.lease_acceptance_records ar
      where ar.lease_agreement_id = p_lease_agreement_id
      limit 1
    ),

    -- Documents
    'documents', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'id',              d.id,
          'document_type',   d.document_type::text,
          'document_name',   d.document_name,
          'status',          d.status::text,
          'version_number',  d.version_number,
          'uploaded_at',     d.uploaded_at,
          'verified_at',     d.verified_at
        )
        order by d.uploaded_at desc
      ), '[]'::jsonb)
      from app.lease_documents d
      where d.lease_agreement_id = p_lease_agreement_id
        and d.status not in ('archived')
    ),

    -- Activity events (most recent first, legal events only)
    'activity', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'id',                e.id,
          'event_type',        e.event_type,
          'event_title',       e.event_title,
          'event_description', e.event_description,
          'created_at',        e.created_at
        )
        order by e.created_at desc
      ), '[]'::jsonb)
      from app.lease_activity_events e
      where e.lease_agreement_id = p_lease_agreement_id
    ),

    -- Completeness flags (mirrors the Phase 7 compliance scoring model)
    'completeness', jsonb_build_object(
      'has_lease_document',    exists (
        select 1 from app.lease_documents d
        where d.lease_agreement_id = p_lease_agreement_id
          and d.document_type = 'lease_agreement'
          and d.status not in ('archived', 'superseded')
      ),
      'has_acceptance_record', exists (
        select 1 from app.lease_acceptance_records ar
        where ar.lease_agreement_id = p_lease_agreement_id
      ),
      'has_template_version',  v_lease.template_version_id is not null,
      'has_content_snapshot',  v_lease.content_snapshot is not null,
      'content_is_locked',     v_lease.locked_at is not null
    )
  );
end;
$$;

-- ─── RPC: app.get_lease_activity ─────────────────────────────────────────────
-- Returns the activity timeline for a lease or unit (for dashboard display).

create or replace function app.get_lease_activity(
  p_lease_agreement_id uuid default null,
  p_unit_id            uuid default null,
  p_limit              integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id   uuid := auth.uid();
  v_property_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_lease_agreement_id is null and p_unit_id is null then
    raise exception 'Either p_lease_agreement_id or p_unit_id is required';
  end if;

  -- Get property for access check
  if p_unit_id is not null then
    select u.property_id into v_property_id
    from app.units u where u.id = p_unit_id and u.deleted_at is null limit 1;
  else
    select l.property_id into v_property_id
    from app.lease_agreements l where l.id = p_lease_agreement_id limit 1;
  end if;

  if v_property_id is null then
    raise exception 'Resource not found';
  end if;

  perform app.assert_tenancy_management_access(v_property_id);

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id',                e.id,
        'event_type',        e.event_type,
        'event_title',       e.event_title,
        'event_description', e.event_description,
        'metadata',          e.metadata,
        'created_at',        e.created_at,
        'lease_agreement_id', e.lease_agreement_id,
        'document_id',       e.document_id,
        'invitation_id',     e.tenant_invitation_id
      )
      order by e.created_at desc
    ), '[]'::jsonb)
    from (
      select *
      from app.lease_activity_events e
      where (p_lease_agreement_id is null or e.lease_agreement_id = p_lease_agreement_id)
        and (p_unit_id is null or e.unit_id = p_unit_id)
      order by e.created_at desc
      limit greatest(coalesce(p_limit, 50), 1)
    ) e
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on table app.lease_acceptance_records from public, anon, authenticated;
revoke all on table app.lease_activity_events    from public, anon, authenticated;
revoke all on table app.lease_documents          from public, anon, authenticated;

revoke all on function app.record_lease_activity(text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,jsonb)
  from public, anon, authenticated;
revoke all on function app.record_lease_acceptance(uuid,boolean,text,text,text,jsonb)
  from public, anon, authenticated;
revoke all on function app.upload_lease_document(uuid,text,text,app.lease_document_type_enum,uuid,uuid,bigint,text,text,jsonb)
  from public, anon, authenticated;
revoke all on function app.verify_lease_document(uuid)
  from public, anon, authenticated;
revoke all on function app.get_lease_evidence_summary(uuid)
  from public, anon, authenticated;
revoke all on function app.get_lease_activity(uuid,uuid,integer)
  from public, anon, authenticated;

-- record_lease_acceptance: tenant calls this from the mobile app after confirming
grant execute on function app.record_lease_acceptance(uuid,boolean,text,text,text,jsonb)
  to authenticated;

-- upload/verify: property managers only (security definer checks assert_tenancy_management_access)
grant execute on function app.upload_lease_document(uuid,text,text,app.lease_document_type_enum,uuid,uuid,bigint,text,text,jsonb)
  to authenticated;
grant execute on function app.verify_lease_document(uuid)
  to authenticated;

-- summary and activity: both tenants and managers (security definer checks access)
grant execute on function app.get_lease_evidence_summary(uuid)
  to authenticated;
grant execute on function app.get_lease_activity(uuid,uuid,integer)
  to authenticated;

-- record_lease_activity: internal helper — no direct grant to authenticated
-- (called only via security definer RPCs, not by the client directly)

-- ----------------------------------------------------------------------------
-- Pending invitation lookup and lease content exposure
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- ─── Update get_tenant_invitation_by_token ────────────────────────────────────
-- Adds content_snapshot to the returned payload so the mobile app can display
-- the full rendered lease sections (from V 1 25 template engine).

create or replace function app.get_tenant_invitation_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite              record;
  v_effective_status    app.tenant_invitation_status_enum;
  v_response_status     text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.invited_name,
    i.invited_email,
    i.invited_phone_number,
    i.delivery_channel,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    i.opened_at,
    i.signup_started_at,
    p.display_name  as property_name,
    u.label         as unit_label,
    l.lease_type,
    l.start_date,
    l.end_date,
    l.billing_cycle,
    l.rent_amount,
    l.currency_code,
    l.confirmation_status,
    l.status        as lease_status,
    l.content_snapshot          -- NEW: rendered sections from template engine
  into v_invite
  from app.tenant_invitations i
  join app.properties p on p.id = i.property_id
  join app.units u       on u.id = i.unit_id
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired'   then raise exception 'Invitation has expired';   end if;
  if v_effective_status = 'cancelled' then raise exception 'Invitation has been cancelled'; end if;

  update app.tenant_invitations
     set status    = case
                       when status in ('pending_delivery', 'pending', 'sent') then 'opened'
                       else status
                     end,
         opened_at = coalesce(opened_at, now()),
         updated_at = now()
   where id = v_invite.id;

  v_response_status := case
    when v_effective_status in ('pending_delivery', 'pending', 'sent') then 'opened'
    else v_effective_status::text
  end;

  return jsonb_build_object(
    'tenant_invitation_id',   v_invite.id,
    'property_id',            v_invite.property_id,
    'unit_id',                v_invite.unit_id,
    'lease_agreement_id',     v_invite.lease_agreement_id,
    'property_name',          coalesce(nullif(trim(v_invite.property_name), ''), 'Untitled Property'),
    'unit_label',             coalesce(nullif(trim(v_invite.unit_label), ''), 'Unlabelled Unit'),
    'invited_name',           v_invite.invited_name,
    'invited_email',          v_invite.invited_email,
    'invited_phone_number',   v_invite.invited_phone_number,
    'delivery_channel',       v_invite.delivery_channel::text,
    'status',                 v_response_status,
    'content_snapshot',       v_invite.content_snapshot,   -- NEW
    'lease', jsonb_build_object(
      'lease_type',           v_invite.lease_type::text,
      'start_date',           v_invite.start_date,
      'end_date',             v_invite.end_date,
      'billing_cycle',        v_invite.billing_cycle::text,
      'rent_amount',          v_invite.rent_amount,
      'currency_code',        v_invite.currency_code,
      'confirmation_status',  v_invite.confirmation_status::text,
      'status',               v_invite.lease_status::text
    )
  );
end;
$$;

-- ─── get_pending_tenant_invite ────────────────────────────────────────────────
-- Called on app startup and after login/signup for any authenticated user.
-- Returns the live invite (if any) whose invited_email matches the caller's
-- account email. Returns NULL (not an error) when no pending invite exists.
-- Marks the invite as 'opened' on first lookup.

create or replace function app.get_pending_tenant_invite()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id           uuid := auth.uid();
  v_user_email        text;
  v_invite            record;
  v_effective_status  app.tenant_invitation_status_enum;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select lower(trim(u.email))
    into v_user_email
  from auth.users u
  where u.id = v_user_id
  limit 1;

  if v_user_email is null or v_user_email = '' then
    return null;
  end if;

  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.invited_name,
    i.invited_email,
    i.invited_phone_number,
    i.delivery_channel,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    i.opened_at,
    p.display_name  as property_name,
    u.label         as unit_label,
    l.lease_type,
    l.start_date,
    l.end_date,
    l.billing_cycle,
    l.rent_amount,
    l.currency_code,
    l.confirmation_status,
    l.status        as lease_status,
    l.content_snapshot
  into v_invite
  from app.tenant_invitations i
  join app.properties p       on p.id = i.property_id and p.deleted_at is null
  join app.units u             on u.id = i.unit_id and u.deleted_at is null
  join app.lease_agreements l  on l.id = i.lease_agreement_id
  where lower(trim(coalesce(i.invited_email, ''))) = v_user_email
    and app.get_effective_tenant_invitation_status(
          i.status, i.expires_at, i.accepted_at, i.cancelled_at
        ) in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  order by i.created_at desc
  limit 1;

  -- No pending invite — return null silently (not an error condition)
  if v_invite.id is null then
    return null;
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  -- Mark as opened on first authenticated lookup
  update app.tenant_invitations
     set status     = case
                        when status in ('pending_delivery', 'pending', 'sent') then 'opened'
                        else status
                      end,
         opened_at  = coalesce(opened_at, now()),
         updated_at = now()
   where id = v_invite.id;

  return jsonb_build_object(
    'tenant_invitation_id',   v_invite.id,
    'property_id',            v_invite.property_id,
    'unit_id',                v_invite.unit_id,
    'lease_agreement_id',     v_invite.lease_agreement_id,
    'property_name',          coalesce(nullif(trim(v_invite.property_name), ''), 'Untitled Property'),
    'unit_label',             coalesce(nullif(trim(v_invite.unit_label), ''), 'Unlabelled Unit'),
    'invited_name',           v_invite.invited_name,
    'invited_email',          v_invite.invited_email,
    'invited_phone_number',   v_invite.invited_phone_number,
    'delivery_channel',       v_invite.delivery_channel::text,
    'status',                 case
                                when v_effective_status in ('pending_delivery','pending','sent')
                                then 'opened'
                                else v_effective_status::text
                              end,
    'content_snapshot',       v_invite.content_snapshot,
    'lease', jsonb_build_object(
      'lease_type',           v_invite.lease_type::text,
      'start_date',           v_invite.start_date,
      'end_date',             v_invite.end_date,
      'billing_cycle',        v_invite.billing_cycle::text,
      'rent_amount',          v_invite.rent_amount,
      'currency_code',        v_invite.currency_code,
      'confirmation_status',  v_invite.confirmation_status::text,
      'status',               v_invite.lease_status::text
    )
  );
end;
$$;

-- ─── accept_pending_tenant_invite ─────────────────────────────────────────────
-- Accepts the pending invite for the authenticated user without requiring the
-- plaintext token. Mirrors accept_tenant_invitation() logic exactly, but uses
-- email matching on auth.uid() instead of token_hash matching.
-- Called by the mobile app when a tenant accepts from the in-app flow
-- (i.e. no deep-link token was involved).

create or replace function app.accept_pending_tenant_invite(p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id             uuid := auth.uid();
  v_user_email          text;
  v_invite              record;
  v_tenancy_id          uuid;
  v_target_tenancy_status app.unit_tenancy_status_enum;
  v_effective_status    app.tenant_invitation_status_enum;
  v_action_id           uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select lower(trim(u.email))
    into v_user_email
  from auth.users u
  where u.id = v_user_id
  limit 1;

  if v_user_email is null or v_user_email = '' then
    raise exception 'Could not determine account email for acceptance';
  end if;

  -- Find and lock the pending invite row
  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    l.start_date,
    l.end_date
  into v_invite
  from app.tenant_invitations i
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where lower(trim(coalesce(i.invited_email, ''))) = v_user_email
    and app.get_effective_tenant_invitation_status(
          i.status, i.expires_at, i.accepted_at, i.cancelled_at
        ) in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  order by i.created_at desc
  limit 1
  for update;

  if v_invite.id is null then
    raise exception 'No pending invitation was found for your account.';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired' then
    raise exception 'This invitation has expired. Please request a new one.';
  end if;
  if v_effective_status = 'cancelled' then
    raise exception 'This invitation was cancelled by the property manager.';
  end if;

  -- Guard: unit must not already have a different active tenant
  if exists (
    select 1 from app.unit_tenancies t
    where t.unit_id = v_invite.unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
      and t.tenant_user_id <> v_user_id
  ) then
    raise exception 'This unit already has an active or scheduled tenant.';
  end if;

  v_target_tenancy_status := case
    when v_invite.start_date <= current_date then 'active'
    else 'scheduled'
  end::app.unit_tenancy_status_enum;

  -- Accept the invitation
  update app.tenant_invitations
     set linked_user_id = v_user_id,
         status         = 'accepted',
         accepted_at    = now(),
         updated_at     = now()
   where id = v_invite.id;

  -- Confirm the lease
  update app.lease_agreements
     set tenant_user_id         = v_user_id,
         confirmation_status    = 'confirmed',
         tenant_confirmed_at    = now(),
         tenant_response_notes  = nullif(trim(coalesce(p_notes, '')), ''),
         status                 = case
                                    when start_date <= current_date then 'active'
                                    else 'confirmed'
                                  end,
         updated_at             = now()
   where id = v_invite.lease_agreement_id;

  -- Create or update tenancy
  insert into app.unit_tenancies (
    property_id, unit_id, lease_agreement_id, tenant_invitation_id,
    tenant_user_id, status, starts_on, ends_on, activated_at,
    created_by_user_id, notes
  ) values (
    v_invite.property_id,
    v_invite.unit_id,
    v_invite.lease_agreement_id,
    v_invite.id,
    v_user_id,
    v_target_tenancy_status,
    v_invite.start_date,
    v_invite.end_date,
    case when v_target_tenancy_status = 'active' then now() else null end,
    v_user_id,
    nullif(trim(coalesce(p_notes, '')), '')
  )
  on conflict (lease_agreement_id)
  do update
    set tenant_user_id       = excluded.tenant_user_id,
        tenant_invitation_id = excluded.tenant_invitation_id,
        status               = excluded.status,
        starts_on            = excluded.starts_on,
        ends_on              = excluded.ends_on,
        activated_at         = excluded.activated_at,
        updated_at           = now()
  returning id into v_tenancy_id;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, v_user_id);
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('LEASE_CONFIRMATION_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      v_user_id,
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'lease_agreement_id',   v_invite.lease_agreement_id,
        'tenancy_id',           v_tenancy_id,
        'confirmation_status',  'confirmed',
        'tenancy_status',       v_target_tenancy_status::text,
        'acceptance_method',    'authenticated_user_lookup'
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id',   v_invite.lease_agreement_id,
    'tenancy_id',           v_tenancy_id,
    'unit_id',              v_invite.unit_id,
    'property_id',          v_invite.property_id,
    'tenancy_status',       v_target_tenancy_status::text,
    'lease_status',         case when v_invite.start_date <= current_date then 'active' else 'confirmed' end
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on function app.get_pending_tenant_invite()
  from public, anon, authenticated;
revoke all on function app.accept_pending_tenant_invite(text)
  from public, anon, authenticated;

-- Any authenticated user can check for their own pending invite
grant execute on function app.get_pending_tenant_invite()
  to authenticated;

-- Any authenticated user can accept their own pending invite
grant execute on function app.accept_pending_tenant_invite(text)
  to authenticated;

-- ----------------------------------------------------------------------------
-- Pending invite dispute flow
-- ----------------------------------------------------------------------------

create schema if not exists app;

create or replace function app.dispute_pending_tenant_invite(p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_user_email text;
  v_invite     record;
  v_effective_status app.tenant_invitation_status_enum;
  v_action_id  uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A dispute reason is required';
  end if;

  select lower(trim(u.email))
    into v_user_email
  from auth.users u
  where u.id = v_user_id
  limit 1;

  if v_user_email is null or v_user_email = '' then
    raise exception 'Could not determine account email';
  end if;

  select i.*
    into v_invite
  from app.tenant_invitations i
  where lower(trim(coalesce(i.invited_email, ''))) = v_user_email
    and app.get_effective_tenant_invitation_status(
          i.status, i.expires_at, i.accepted_at, i.cancelled_at
        ) in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  order by i.created_at desc
  limit 1
  for update;

  if v_invite.id is null then
    raise exception 'No pending invitation was found for your account.';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired'   then raise exception 'This invitation has expired.';             end if;
  if v_effective_status = 'cancelled' then raise exception 'This invitation has been cancelled.';      end if;
  if v_effective_status = 'accepted'  then raise exception 'This invitation has already been accepted.'; end if;

  update app.tenant_invitations
     set linked_user_id     = v_user_id,
         status             = 'signup_started'::app.tenant_invitation_status_enum,
         signup_started_at  = coalesce(signup_started_at, now()),
         updated_at         = now()
   where id = v_invite.id;

  update app.lease_agreements
     set tenant_user_id         = v_user_id,
         confirmation_status    = 'disputed'::app.lease_confirmation_status_enum,
         tenant_disputed_at     = now(),
         tenant_response_notes  = trim(p_reason),
         status                 = 'disputed'::app.lease_agreement_status_enum,
         updated_at             = now()
   where id = v_invite.lease_agreement_id;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, v_user_id);
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('LEASE_CONFIRMATION_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      v_user_id,
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'lease_agreement_id',   v_invite.lease_agreement_id,
        'confirmation_status',  'disputed',
        'reason',               trim(p_reason),
        'dispute_method',       'authenticated_user_lookup'
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id',   v_invite.lease_agreement_id,
    'status',               'disputed'
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on function app.dispute_pending_tenant_invite(text)
  from public, anon, authenticated;

grant execute on function app.dispute_pending_tenant_invite(text)
  to authenticated;

-- ----------------------------------------------------------------------------
-- Lease template creation hardening
-- ----------------------------------------------------------------------------

create schema if not exists app;

create or replace function app.create_lease_template(
  p_workspace_id            uuid,
  p_name                    text,
  p_description             text    default null,
  p_lease_type              app.lease_type_enum default 'fixed_term',
  p_property_category       text    default 'apartment',
  p_default_duration_months integer default null,
  p_renewal_behavior        text    default 'manual',
  p_notice_period_days      integer default 30,
  p_property_id             uuid    default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_template_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from app.workspaces w
    where w.id = p_workspace_id
      and (
        w.owner_user_id = auth.uid()
        or exists (
          select 1 from app.workspace_memberships wm
          where wm.workspace_id = p_workspace_id
            and wm.user_id = auth.uid()
            and wm.status = 'active'
        )
      )
  ) then
    raise exception 'Forbidden: you do not have access to this workspace';
  end if;

  -- Fixed: p_property_id IS already the property UUID — no subquery needed.
  if p_property_id is not null and not app.has_tenancy_management_access(p_property_id) then
    raise exception 'Forbidden: you do not have access to this property';
  end if;

  insert into app.lease_templates (
    workspace_id, property_id, name, description, lease_type, property_category,
    default_duration_months, renewal_behavior, notice_period_days, status, created_by
  ) values (
    p_workspace_id,
    p_property_id,
    trim(p_name),
    nullif(trim(coalesce(p_description, '')), ''),
    p_lease_type,
    coalesce(p_property_category, 'apartment'),
    p_default_duration_months,
    coalesce(p_renewal_behavior, 'manual'),
    coalesce(p_notice_period_days, 30),
    'draft',
    auth.uid()
  )
  returning id into v_template_id;

  return jsonb_build_object(
    'template_id', v_template_id,
    'status', 'draft'
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- Render immutable lease content at invitation time
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- ─── format_ordinal ───────────────────────────────────────────────────────────

create or replace function app.format_ordinal(n integer)
returns text
language sql
immutable
set search_path = app, public
as $$
  select n::text || case
    when n % 100 in (11, 12, 13) then 'th'
    when n % 10 = 1              then 'st'
    when n % 10 = 2              then 'nd'
    when n % 10 = 3              then 'rd'
    else                              'th'
  end;
$$;

-- ─── format_money ─────────────────────────────────────────────────────────────

create or replace function app.format_money(p_amount numeric, p_currency text)
returns text
language sql
immutable
set search_path = app, public
as $$
  select coalesce(upper(p_currency), 'KES') || ' ' ||
         to_char(coalesce(p_amount, 0), 'FM999,999,999.00');
$$;

-- ─── render_template_sections ─────────────────────────────────────────────────
-- Takes a JSONB array of section objects and a JSONB substitution map
-- ({"{{token}}": "value"}) and returns the array with all tokens replaced in
-- each section's "content" field. Tokens with empty/null values are skipped.

create or replace function app.render_template_sections(
  p_sections      jsonb,
  p_substitutions jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = app, public
as $$
declare
  v_section  jsonb;
  v_content  text;
  v_key      text;
  v_val      text;
  v_result   jsonb := '[]'::jsonb;
begin
  if p_sections is null or jsonb_array_length(p_sections) = 0 then
    return '[]'::jsonb;
  end if;

  for v_section in select * from jsonb_array_elements(p_sections) loop
    v_content := v_section->>'content';

    if v_content is not null and p_substitutions is not null then
      for v_key, v_val in
        select key, trim(both '"' from value::text)
        from jsonb_each(p_substitutions)
      loop
        if v_val is not null and v_val <> '' and v_val <> 'null' then
          v_content := replace(v_content, v_key, v_val);
        end if;
      end loop;
    end if;

    v_result := v_result || jsonb_set(v_section, '{content}', to_jsonb(v_content));
  end loop;

  return v_result;
end;
$$;

-- ─── create_tenant_invitation (full rewrite with rendering) ──────────────────

create or replace function app.create_tenant_invitation(
  p_unit_id                    uuid,
  p_tenant_phone               text    default null,
  p_tenant_email               text    default null,
  p_delivery_channel           app.tenant_invitation_delivery_channel_enum default 'email',
  p_tenant_name                text    default null,
  p_lease_type                 app.lease_type_enum default 'fixed_term',
  p_start_date                 date    default current_date,
  p_end_date                   date    default null,
  p_rent_amount                numeric default 0,
  p_notes                      text    default null,
  p_billing_cycle              app.lease_billing_cycle_enum default 'monthly',
  p_rent_due_day_of_month      integer default 5,
  p_collection_grace_period_days integer default 2,
  p_currency_code              text    default 'KES',
  p_expires_in_days            integer default 7,
  p_template_id                text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_unit                       record;
  v_snapshot                   record;
  v_tenant_phone               text;
  v_tenant_email               text;
  v_tenant_name                text;
  v_notes                      text;
  v_currency_code              text;
  v_token                      text;
  v_expires_at                 timestamptz;
  v_lease_id                   uuid;
  v_invitation_id              uuid;
  v_lease_action_id            uuid;
  v_invite_action_id           uuid;
  v_existing_tenant_user_id    uuid;
  -- Template resolution
  v_template_uuid              uuid;
  v_template_version_id        uuid;
  v_raw_sections               jsonb;
  v_content_snapshot           jsonb;
  -- Owner profile
  v_owner_name                 text;
  v_owner_email                text;
  -- Duration calculation
  v_duration_months            integer;
  v_duration_text              text;
  -- Substitution map
  v_subs                       jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_tenant_phone   := nullif(trim(coalesce(p_tenant_phone, '')), '');
  v_tenant_email   := nullif(trim(lower(coalesce(p_tenant_email, ''))), '');
  v_tenant_name    := nullif(trim(coalesce(p_tenant_name, '')), '');
  v_notes          := nullif(trim(coalesce(p_notes, '')), '');
  v_currency_code  := upper(coalesce(nullif(trim(p_currency_code), ''), 'KES'));
  v_expires_at     := now() + make_interval(days => greatest(coalesce(p_expires_in_days, 7), 1));

  if p_delivery_channel = 'email' and v_tenant_email is null then
    raise exception 'Tenant email is required for email delivery';
  end if;
  if v_tenant_email is not null then
    select u.id
      into v_existing_tenant_user_id
    from auth.users u
    where lower(trim(coalesce(u.email, ''))) = v_tenant_email
    limit 1;

    if v_existing_tenant_user_id is not null then
      raise exception 'An account with this email already exists. Ask the tenant to sign in with that email instead of sending a new invite.';
    end if;
  end if;
  if p_delivery_channel = 'sms' and v_tenant_phone is null then
    raise exception 'Tenant phone number is required for SMS delivery';
  end if;
  if p_rent_amount is null or p_rent_amount < 0 then
    raise exception 'Rent amount must be zero or greater';
  end if;
  if p_rent_due_day_of_month is null or p_rent_due_day_of_month < 1 or p_rent_due_day_of_month > 28 then
    raise exception 'Rent due day must be between 1 and 28';
  end if;
  if p_collection_grace_period_days is null or p_collection_grace_period_days < 0 or p_collection_grace_period_days > 14 then
    raise exception 'Collection grace period must be between 0 and 14 days';
  end if;

  -- ── Template resolution ───────────────────────────────────────────────────
  if p_template_id is not null and length(trim(p_template_id)) > 0 then
    begin
      v_template_uuid := trim(p_template_id)::uuid;
    exception when invalid_text_representation then
      v_template_uuid := null;
    end;

    if v_template_uuid is not null then
      select ltv.id, ltv.sections
        into v_template_version_id, v_raw_sections
      from app.lease_template_versions ltv
      where ltv.template_id = v_template_uuid
        and ltv.status = 'active'
      order by ltv.version_number desc
      limit 1;
    end if;
  end if;

  -- ── Unit + property fetch (extended to include address fields) ─────────────
  select
    u.id               as unit_id,
    u.property_id,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit')          as unit_label,
    coalesce(u.block, '')                                            as unit_block,
    coalesce(u.floor, '')                                            as unit_floor,
    u.expected_rate,
    p.status           as property_status,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    coalesce(p.address_description, '')                              as property_address,
    coalesce(p.city_town, '')                                        as property_city
  into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.unit_id is null then
    raise exception 'Unit not found or deleted';
  end if;
  if v_unit.property_status <> 'active' then
    raise exception 'Tenant invites can only be created for active properties';
  end if;

  -- ── Owner profile ─────────────────────────────────────────────────────────
  select
    trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')),
    coalesce(email, '')
  into v_owner_name, v_owner_email
  from app.profiles
  where id = auth.uid()
  limit 1;

  v_owner_name  := nullif(trim(coalesce(v_owner_name, '')), '');
  v_owner_email := nullif(trim(coalesce(v_owner_email, '')), '');

  perform app.assert_tenancy_management_access(v_unit.property_id);
  perform app.expire_tenant_invitations(v_unit.property_id, p_unit_id);
  perform app.refresh_lease_agreement_statuses(v_unit.property_id, p_unit_id);
  perform app.refresh_unit_tenancy_statuses(v_unit.property_id, p_unit_id);
  perform app.ensure_unit_occupancy_snapshot_exists(p_unit_id, auth.uid());

  select occupancy_status into v_snapshot
  from app.unit_occupancy_snapshots
  where unit_id = p_unit_id
  limit 1;

  if coalesce(v_snapshot.occupancy_status::text, '') in ('occupied', 'disputed') then
    raise exception 'This unit is not currently available for a new tenant invite';
  end if;

  if exists (
    select 1 from app.tenant_invitations i
    where i.unit_id = p_unit_id
      and app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at)
          in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  ) then
    raise exception 'A live tenant invitation already exists for this unit';
  end if;

  if exists (
    select 1 from app.lease_agreements l
    where l.unit_id = p_unit_id
      and app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date)
          in ('pending_confirmation', 'confirmed', 'active', 'disputed')
  ) then
    raise exception 'A live lease agreement already exists for this unit';
  end if;

  if exists (
    select 1 from app.unit_tenancies t
    where t.unit_id = p_unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
  ) then
    raise exception 'This unit already has an open tenancy';
  end if;

  if p_lease_type = 'fixed_term' and (p_end_date is null or p_end_date <= p_start_date) then
    raise exception 'Fixed-term leases require an end date after the start date';
  end if;
  if p_lease_type <> 'fixed_term' and p_end_date is not null and p_end_date <= p_start_date then
    raise exception 'Lease end date must be after the start date';
  end if;

  -- ── Render template content with real invite data ─────────────────────────
  if v_raw_sections is not null then
    -- Compute lease duration text
    if p_end_date is not null then
      v_duration_months := (
        extract(year from age(p_end_date, p_start_date)) * 12 +
        extract(month from age(p_end_date, p_start_date))
      )::integer;
      v_duration_text := case
        when v_duration_months = 12 then 'Twelve (12) months'
        when v_duration_months = 6  then 'Six (6) months'
        when v_duration_months = 24 then 'Twenty-Four (24) months'
        else v_duration_months::text || ' months'
      end;
    else
      v_duration_text := 'Month-to-month (rolling)';
    end if;

    v_subs := jsonb_build_object(
      -- Tenant
      '{{tenant.full_name}}',   coalesce(v_tenant_name, coalesce(v_tenant_email, 'Tenant')),
      '{{tenant.email}}',       coalesce(v_tenant_email, ''),
      '{{tenant.phone}}',       coalesce(v_tenant_phone, ''),
      -- Owner / Landlord
      '{{owner.full_name}}',    coalesce(v_owner_name, 'Property Manager'),
      '{{owner.email}}',        coalesce(v_owner_email, ''),
      '{{owner.phone}}',        '',
      -- Property
      '{{property.name}}',      v_unit.property_name,
      '{{property.address}}',   case
                                  when v_unit.property_address <> '' and v_unit.property_city <> ''
                                  then v_unit.property_address || ', ' || v_unit.property_city
                                  when v_unit.property_address <> '' then v_unit.property_address
                                  when v_unit.property_city    <> '' then v_unit.property_city
                                  else ''
                                end,
      -- Unit
      '{{unit.number}}',        v_unit.unit_label,
      '{{unit.block}}',         v_unit.unit_block,
      '{{unit.floor}}',         v_unit.unit_floor,
      -- Lease dates & terms
      '{{lease.start_date}}',   to_char(p_start_date, 'FMDDth Month YYYY'),
      '{{lease.end_date}}',     case when p_end_date is not null
                                     then to_char(p_end_date, 'FMDDth Month YYYY')
                                     else 'Open-ended (month-to-month)'
                                end,
      '{{lease.duration}}',     v_duration_text,
      '{{lease.type}}',         initcap(replace(p_lease_type::text, '_', ' ')),
      '{{lease.notice_period}}','Thirty (30) days',
      -- Financial
      '{{rent.monthly_amount}}',app.format_money(p_rent_amount, v_currency_code),
      '{{rent.due_day}}',        app.format_ordinal(p_rent_due_day_of_month)
    );

    v_content_snapshot := app.render_template_sections(v_raw_sections, v_subs);
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  -- ── Create lease draft ────────────────────────────────────────────────────
  insert into app.lease_agreements (
    property_id, unit_id, tenant_name, tenant_phone, entered_by_user_id, lease_type,
    start_date, end_date, billing_cycle, rent_due_day_of_month, collection_grace_period_days,
    rent_amount, currency_code, status, confirmation_status, agreement_notes, terms_snapshot,
    template_version_id, content_snapshot
  )
  values (
    v_unit.property_id, p_unit_id, v_tenant_name, v_tenant_phone, auth.uid(),
    p_lease_type, p_start_date, p_end_date, coalesce(p_billing_cycle, 'monthly'),
    p_rent_due_day_of_month, p_collection_grace_period_days, p_rent_amount,
    v_currency_code, 'pending_confirmation', 'awaiting_tenant', v_notes,
    jsonb_build_object(
      'captured_from',                'owner_web_invite',
      'captured_at',                   now(),
      'expected_rate_at_capture',      v_unit.expected_rate,
      'unit_label',                    v_unit.unit_label,
      'property_name',                 v_unit.property_name,
      'rent_due_day_of_month',         p_rent_due_day_of_month,
      'collection_grace_period_days',  p_collection_grace_period_days,
      'collection_policy_label', format(
        'Rent due by the %s with collection follow-up through day %s of the month.',
        p_rent_due_day_of_month,
        p_rent_due_day_of_month + p_collection_grace_period_days
      ),
      'delivery_channel',              p_delivery_channel::text,
      'tenant_email',                  v_tenant_email
    ),
    v_template_version_id,
    v_content_snapshot
  )
  returning id into v_lease_id;

  -- ── Create invitation ─────────────────────────────────────────────────────
  insert into app.tenant_invitations (
    property_id, unit_id, lease_agreement_id, invited_by_user_id, invited_phone_number,
    invited_email, invited_name, token_hash, delivery_channel, status, sent_at,
    expires_at, template_id, template_version_id, metadata
  )
  values (
    v_unit.property_id, p_unit_id, v_lease_id, auth.uid(),
    v_tenant_phone, v_tenant_email, v_tenant_name,
    app.hash_token(v_token), p_delivery_channel, 'sent', now(), v_expires_at,
    v_template_uuid, v_template_version_id,
    jsonb_build_object(
      'lease_type',                   p_lease_type::text,
      'lease_start_date',             p_start_date,
      'lease_end_date',               p_end_date,
      'rent_amount',                  p_rent_amount,
      'currency_code',                v_currency_code,
      'billing_cycle',                coalesce(p_billing_cycle, 'monthly')::text,
      'rent_due_day_of_month',        p_rent_due_day_of_month,
      'collection_grace_period_days', p_collection_grace_period_days,
      'notes',                        v_notes,
      'template_version_id',          v_template_version_id
    )
  )
  returning id into v_invitation_id;

  perform app.sync_unit_occupancy_snapshot(p_unit_id, auth.uid());
  perform app.touch_property_activity(v_unit.property_id);
  perform app.enqueue_tenant_invitation_notifications(v_invitation_id);

  v_lease_action_id := app.get_audit_action_id_by_code('LEASE_CAPTURED');
  if v_lease_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (v_unit.property_id, p_unit_id, auth.uid(), v_lease_action_id,
      jsonb_build_object(
        'lease_agreement_id',           v_lease_id,
        'lease_type',                   p_lease_type::text,
        'billing_cycle',                coalesce(p_billing_cycle, 'monthly')::text,
        'rent_due_day_of_month',        p_rent_due_day_of_month,
        'collection_grace_period_days', p_collection_grace_period_days,
        'rent_amount',                  p_rent_amount,
        'currency_code',                v_currency_code,
        'template_version_id',          v_template_version_id
      ));
  end if;

  v_invite_action_id := app.get_audit_action_id_by_code('TENANT_INVITE_SENT');
  if v_invite_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (v_unit.property_id, p_unit_id, auth.uid(), v_invite_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invitation_id,
        'lease_agreement_id',   v_lease_id,
        'delivery_channel',     p_delivery_channel::text,
        'expires_at',           v_expires_at,
        'template_version_id',  v_template_version_id
      ));
  end if;

  return jsonb_build_object(
    'property_id',          v_unit.property_id,
    'unit_id',              p_unit_id,
    'lease_agreement_id',   v_lease_id,
    'tenant_invitation_id', v_invitation_id,
    'status',               'sent',
    'delivery_channel',     p_delivery_channel::text,
    'expires_at',           v_expires_at,
    'token',                v_token,
    'template_version_id',  v_template_version_id
  );
end;
$$;

-- Grants carry over from V 1 07 / V 1 31 — no changes needed since function
-- signature is identical.

-- ----------------------------------------------------------------------------
-- Lease directory RPC
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- ─── get_lease_directory ─────────────────────────────────────────────────────

create or replace function app.get_lease_directory(
  p_property_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.start_date desc)
      from (
        select
          l.id,
          l.property_id,
          p.display_name                                           as property_name,
          l.unit_id,
          coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit')  as unit_label,
          coalesce(nullif(trim(u.block), ''), null)               as unit_block,
          coalesce(nullif(trim(u.floor), ''), null)               as unit_floor,

          -- Tenant identity: prefer name from lease, fall back to latest invite
          coalesce(
            nullif(trim(l.tenant_name), ''),
            nullif(trim(i.invited_name), ''),
            coalesce(l.tenant_user_id::text, null)
          )                                                        as tenant_name,
          coalesce(l.tenant_user_id::text, i.linked_user_id::text) as tenant_id,
          coalesce(i.invited_email, '')                            as tenant_email,
          coalesce(i.invited_phone_number, '')                     as tenant_phone,

          l.lease_type::text,
          l.start_date,
          l.end_date,
          l.rent_amount,
          l.currency_code,
          l.billing_cycle::text,
          l.status::text                                           as db_status,
          l.confirmation_status::text,
          l.agreement_notes                                        as special_conditions,

          -- Computed UI status
          case
            when l.confirmation_status = 'disputed'               then 'disputed'
            when l.status in ('terminated_early', 'overstayed')   then 'terminated'
            when l.status = 'disputed'                             then 'disputed'
            when l.end_date is not null
              and l.end_date < current_date
              and l.status not in ('terminated_early', 'disputed') then 'expired'
            when l.lease_type = 'month_to_month'
              and l.status in ('active', 'confirmed')              then 'month_to_month'
            when l.end_date is not null
              and l.end_date between current_date and current_date + interval '60 days'
              and l.status in ('active', 'confirmed')              then 'expiring_soon'
            when l.status in ('active', 'confirmed')               then 'active'
            when l.status = 'pending_confirmation'                 then 'pending_confirmation'
            else l.status::text
          end                                                       as ui_status,

          -- Days remaining (null for month-to-month or no end date)
          case when l.end_date is not null
               then (l.end_date - current_date)::integer
               else null
          end                                                       as days_remaining,

          -- Document count from V 1 26 table
          (
            select count(*)::integer
            from app.lease_documents d
            where d.lease_agreement_id = l.id
              and d.status = 'uploaded'
          )                                                         as document_count,

          -- Has formal acceptance record (V 1 26)
          exists (
            select 1 from app.lease_acceptance_records ar
            where ar.lease_agreement_id = l.id
          )                                                         as has_acceptance_record,

          -- Accepted full name (for evidence display)
          (
            select ar.accepted_full_name
            from app.lease_acceptance_records ar
            where ar.lease_agreement_id = l.id
            limit 1
          )                                                         as accepted_full_name,

          -- Accepted at timestamp
          (
            select ar.recorded_at
            from app.lease_acceptance_records ar
            where ar.lease_agreement_id = l.id
            limit 1
          )                                                         as accepted_at,

          -- Template info
          ltv.version_label                                         as template_version_label,
          lt.name                                                   as template_name,
          lt.id                                                     as template_id,

          -- Renewal: is there a newer active lease for the same unit?
          exists (
            select 1 from app.lease_agreements l2
            where l2.unit_id = l.unit_id
              and l2.id <> l.id
              and l2.created_at > l.created_at
              and l2.status in ('active', 'confirmed', 'pending_confirmation')
          )                                                         as is_renewed,

          l.created_at,
          l.updated_at

        from app.lease_agreements l
        join app.units u       on u.id = l.unit_id     and u.deleted_at is null
        join app.properties p  on p.id = l.property_id and p.deleted_at is null
        -- Latest invite for this lease (lateral)
        left join lateral (
          select invited_name, invited_email, invited_phone_number, linked_user_id
          from app.tenant_invitations ti
          where ti.lease_agreement_id = l.id
          order by ti.created_at desc
          limit 1
        ) i on true
        -- Template version
        left join app.lease_template_versions ltv on ltv.id = l.template_version_id
        left join app.lease_templates lt           on lt.id = ltv.template_id

        where p.deleted_at is null
          and (p_property_id is null or l.property_id = p_property_id)
          and (
            p.workspace_id in (
              select w.id from app.workspaces w
              where w.owner_user_id = auth.uid()
            )
            or exists (
              select 1 from app.workspace_memberships wm
              where wm.workspace_id = p.workspace_id
                and wm.user_id = auth.uid()
                and wm.status = 'active'
            )
          )
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

-- ─── get_lease_portfolio_summary ─────────────────────────────────────────────

create or replace function app.get_lease_portfolio_summary(
  p_property_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_total_active        integer := 0;
  v_expiring_30         integer := 0;
  v_expiring_60         integer := 0;
  v_expiring_90         integer := 0;
  v_expired             integer := 0;
  v_disputed            integer := 0;
  v_month_to_month      integer := 0;
  v_documents_on_file   integer := 0;
  v_pending_accept      integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and (l.end_date is null or l.end_date >= current_date)
        and l.confirmation_status <> 'disputed'
        and l.lease_type <> 'month_to_month'
    ),
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and l.end_date between current_date and current_date + interval '30 days'
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and l.end_date between current_date + interval '1 day' and current_date + interval '60 days'
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and l.end_date between current_date + interval '1 day' and current_date + interval '90 days'
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where (l.end_date is not null and l.end_date < current_date
             and l.status not in ('terminated_early', 'disputed'))
        or l.status = 'expired'
    ),
    count(*) filter (
      where l.confirmation_status = 'disputed' or l.status = 'disputed'
    ),
    count(*) filter (
      where l.lease_type = 'month_to_month'
        and l.status in ('active', 'confirmed')
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where l.status = 'pending_confirmation'
    )
  into
    v_total_active,
    v_expiring_30,
    v_expiring_60,
    v_expiring_90,
    v_expired,
    v_disputed,
    v_month_to_month,
    v_pending_accept
  from app.lease_agreements l
  join app.properties p on p.id = l.property_id and p.deleted_at is null
  where (p_property_id is null or l.property_id = p_property_id)
    and (
      p.workspace_id in (select w.id from app.workspaces w where w.owner_user_id = auth.uid())
      or exists (
        select 1 from app.workspace_memberships wm
        where wm.workspace_id = p.workspace_id
          and wm.user_id = auth.uid()
          and wm.status = 'active'
      )
    );

  -- Count leases that have at least one uploaded document
  select count(distinct d.lease_agreement_id)::integer
  into v_documents_on_file
  from app.lease_documents d
  join app.lease_agreements l on l.id = d.lease_agreement_id
  join app.properties p        on p.id = l.property_id and p.deleted_at is null
  where d.status = 'uploaded'
    and (p_property_id is null or l.property_id = p_property_id)
    and (
      p.workspace_id in (select w.id from app.workspaces w where w.owner_user_id = auth.uid())
      or exists (
        select 1 from app.workspace_memberships wm
        where wm.workspace_id = p.workspace_id
          and wm.user_id = auth.uid()
          and wm.status = 'active'
      )
    );

  return jsonb_build_object(
    'total_active',      v_total_active,
    'expiring_in_30',    v_expiring_30,
    'expiring_in_60',    v_expiring_60,
    'expiring_in_90',    v_expiring_90,
    'expired',           v_expired,
    'disputed',          v_disputed,
    'month_to_month',    v_month_to_month,
    'pending_accept',    v_pending_accept,
    'documents_on_file', v_documents_on_file
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on function app.get_lease_directory(uuid)         from public, anon, authenticated;
revoke all on function app.get_lease_portfolio_summary(uuid) from public, anon, authenticated;

grant execute on function app.get_lease_directory(uuid)         to authenticated;
grant execute on function app.get_lease_portfolio_summary(uuid) to authenticated;
