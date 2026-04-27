-- ============================================================================
-- V 1 26: Lease Documents and Evidence
-- ============================================================================
-- Purpose
--   - Introduce formal acceptance records as immutable legal proof
--   - Introduce a unified lease activity event log (append-only audit trail)
--   - Introduce lease document metadata tracking (files in Supabase Storage)
--   - Provide RPCs for recording acceptance evidence, uploading documents,
--     and querying the lease evidence summary for a given unit or tenant
--
-- Integration with existing flow (V 1 07 / V 1 25)
--   - accept_tenant_invitation() (V 1 07) handles the core confirmation flow
--     (updates lease_agreements, creates unit_tenancies, syncs occupancy).
--   - record_lease_acceptance() (this migration) is called AFTER
--     accept_tenant_invitation() to capture the formal checkbox + full name
--     evidence, lock the content_snapshot, and write activity events.
--   - This separation keeps the existing RPC contract intact while adding
--     the formal evidence layer on top.
-- ============================================================================

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
