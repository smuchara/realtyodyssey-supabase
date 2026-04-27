-- ============================================================================
-- V 1 25: Lease Template Engine
-- ============================================================================
-- Purpose
--   - Introduce reusable lease templates and immutable version snapshots
--   - Templates provide the structured clause content that gets rendered
--     (placeholders replaced) when create_tenant_invitation() is called
--   - Template versions are immutable once referenced by any invitation or
--     lease agreement — changes require a new version
--   - Adds template linkage columns to existing lease_agreements and
--     tenant_invitations tables (additive, nullable, backwards-compatible)
--
-- Integration with existing flow (V 1 07)
--   - create_tenant_invitation() already creates the lease_agreement first
--     then the invitation, with lease_agreement_id as the FK. Template
--     rendering happens server-side (Edge Function) before calling the RPC.
--     The rendered sections are passed as p_content_snapshot to the lease.
--   - New column: lease_agreements.template_version_id (nullable FK)
--   - New column: lease_agreements.content_snapshot (rendered JSONB sections)
--   - New column: lease_agreements.locked_at / locked_by (immutability anchor)
--   - New column: tenant_invitations.template_id / template_version_id
-- ============================================================================

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
            'placeholder_keys', ltv.placeholder_keys
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
