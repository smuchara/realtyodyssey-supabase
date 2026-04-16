-- ============================================================================
-- V 1 09: Payments and Collections
-- ============================================================================
-- Purpose
--   - Define versioned payment routing configuration
--   - Model expected rent charge periods
--   - Record payment evidence without custodial wallet semantics
--   - Support payment allocation and financial access controls
--
-- Notes
--   - Product "portfolio" maps to workspace scope in the current schema.
--   - Product "building" maps to property scope; there is no first-class
--     building table in the current domain model.
--   - M-Pesa callback registration and Daraja integration are kept for V 1 10.
-- ============================================================================

create schema if not exists app;

do $$ begin
  create type app.payment_scope_enum as enum ('workspace', 'property', 'unit');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_method_type_enum as enum (
    'mpesa_paybill',
    'mpesa_till',
    'mpesa_send_money',
    'bank_transfer',
    'cash',
    'cheque',
    'other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_collection_setup_status_enum as enum (
    'draft', 'active', 'inactive', 'superseded'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.rent_charge_status_enum as enum (
    'scheduled', 'partially_paid', 'paid', 'overdue', 'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_record_source_enum as enum (
    'manual_entry',
    'tenant_submission',
    'mobile_money_import',
    'bank_statement_import',
    'backfill_import'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_record_status_enum as enum ('recorded', 'voided');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_allocation_status_enum as enum (
    'unapplied', 'partially_applied', 'fully_applied'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_allocation_source_enum as enum ('manual', 'automatic');
exception when duplicate_object then null; end $$;

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('PAYMENT_SETUP_CREATED', 'Payment Setup Created', 200),
  ('PAYMENT_SETUP_UPDATED', 'Payment Setup Updated', 201),
  ('PAYMENT_SETUP_SUPERSEDED', 'Payment Setup Superseded', 202),
  ('PAYMENT_RECORDED', 'Payment Recorded', 203),
  ('PAYMENT_ALLOCATED', 'Payment Allocated', 204),
  ('RENT_CHARGE_CREATED', 'Rent Charge Created', 205)
on conflict (code) do update
set label = excluded.label, sort_order = excluded.sort_order;

create table if not exists app.payment_collection_setups (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_id uuid references app.properties(id) on delete cascade,
  unit_id uuid references app.units(id) on delete cascade,
  scope_type app.payment_scope_enum not null,
  payment_method_type app.payment_method_type_enum not null,
  lifecycle_status app.payment_collection_setup_status_enum not null default 'draft',
  is_default boolean not null default false,
  priority_rank integer not null default 100,
  display_name text not null,
  account_name text not null,
  paybill_number text,
  till_number text,
  send_money_phone_number text,
  account_reference_hint text,
  collection_instructions text,
  metadata jsonb not null default '{}'::jsonb,
  activated_at timestamptz,
  deactivated_at timestamptz,
  replaced_by_setup_id uuid references app.payment_collection_setups(id) on delete set null deferrable initially deferred,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_payment_collection_setups_scope
    check (
      (scope_type = 'workspace' and property_id is null and unit_id is null)
      or
      (scope_type = 'property' and property_id is not null and unit_id is null)
      or
      (scope_type = 'unit' and property_id is not null and unit_id is not null)
    ),
  constraint chk_payment_collection_setups_supported_methods
    check (payment_method_type in ('mpesa_paybill', 'mpesa_till', 'mpesa_send_money')),
  constraint chk_payment_collection_setups_method_details
    check (
      (payment_method_type = 'mpesa_paybill'
        and paybill_number is not null
        and till_number is null
        and send_money_phone_number is null)
      or
      (payment_method_type = 'mpesa_till'
        and paybill_number is null
        and till_number is not null
        and send_money_phone_number is null)
      or
      (payment_method_type = 'mpesa_send_money'
        and paybill_number is null
        and till_number is null
        and send_money_phone_number is not null)
    ),
  constraint chk_payment_collection_setups_priority_rank check (priority_rank > 0),
  constraint chk_payment_collection_setups_display_name_len
    check (char_length(trim(display_name)) between 2 and 160),
  constraint chk_payment_collection_setups_account_name_len
    check (char_length(trim(account_name)) between 2 and 160),
  constraint chk_payment_collection_setups_paybill_len
    check (paybill_number is null or char_length(trim(paybill_number)) between 5 and 20),
  constraint chk_payment_collection_setups_till_len
    check (till_number is null or char_length(trim(till_number)) between 5 and 20),
  constraint chk_payment_collection_setups_send_money_len
    check (send_money_phone_number is null or char_length(trim(send_money_phone_number)) between 7 and 20),
  constraint chk_payment_collection_setups_account_reference_hint_len
    check (
      account_reference_hint is null
      or char_length(trim(account_reference_hint)) between 1 and 120
    ),
  constraint chk_payment_collection_setups_default_requires_active
    check (not is_default or lifecycle_status = 'active'),
  constraint chk_payment_collection_setups_superseded_replacement
    check (lifecycle_status <> 'superseded' or replaced_by_setup_id is not null),
  constraint chk_payment_collection_setups_self_replacement
    check (replaced_by_setup_id is null or replaced_by_setup_id <> id)
);

comment on table app.payment_collection_setups is
  'Versioned payment destination configuration. Product portfolio scope maps to workspace scope.';

comment on column app.payment_collection_setups.scope_type is
  'workspace = portfolio, property = building/property, unit = unit-specific override.';

create or replace function app.prepare_payment_collection_setup()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_workspace_id uuid;
  v_existing_activated_at timestamptz;
  v_existing_deactivated_at timestamptz;
begin
  if tg_op = 'UPDATE' then
    v_existing_activated_at := old.activated_at;
    v_existing_deactivated_at := old.deactivated_at;
  end if;

  if new.scope_type = 'workspace' then
    if new.workspace_id is null then
      raise exception 'workspace_id is required for workspace payment setup';
    end if;
    new.property_id := null;
    new.unit_id := null;
  elsif new.scope_type = 'property' then
    if new.property_id is null then
      raise exception 'property_id is required for property payment setup';
    end if;
    if new.unit_id is not null then
      raise exception 'unit_id must be null for property payment setup';
    end if;

    select p.workspace_id
      into v_workspace_id
    from app.properties p
    where p.id = new.property_id
      and p.deleted_at is null
    limit 1;

    if v_workspace_id is null then
      raise exception 'Property not found or deleted';
    end if;

    new.workspace_id := v_workspace_id;
  elsif new.scope_type = 'unit' then
    if new.unit_id is null then
      raise exception 'unit_id is required for unit payment setup';
    end if;

    select u.property_id, p.workspace_id
      into v_property_id, v_workspace_id
    from app.units u
    join app.properties p on p.id = u.property_id
    where u.id = new.unit_id
      and u.deleted_at is null
      and p.deleted_at is null
    limit 1;

    if v_property_id is null or v_workspace_id is null then
      raise exception 'Unit not found or deleted';
    end if;

    if new.property_id is not null and new.property_id <> v_property_id then
      raise exception 'unit_id does not belong to the provided property_id';
    end if;

    new.property_id := v_property_id;
    new.workspace_id := v_workspace_id;
  else
    raise exception 'Unsupported payment setup scope: %', new.scope_type;
  end if;

  if new.lifecycle_status = 'draft' then
    new.activated_at := null;
    new.deactivated_at := null;
    new.is_default := false;
  elsif new.lifecycle_status = 'active' then
    new.activated_at := coalesce(new.activated_at, v_existing_activated_at, now());
    new.deactivated_at := null;
  elsif new.lifecycle_status = 'inactive' then
    new.activated_at := coalesce(new.activated_at, v_existing_activated_at, now());
    new.deactivated_at := coalesce(new.deactivated_at, v_existing_deactivated_at, now());
    new.is_default := false;
  elsif new.lifecycle_status = 'superseded' then
    if new.replaced_by_setup_id is null then
      raise exception 'Superseded payment setup must reference replaced_by_setup_id';
    end if;
    new.activated_at := coalesce(new.activated_at, v_existing_activated_at, now());
    new.deactivated_at := coalesce(new.deactivated_at, v_existing_deactivated_at, now());
    new.is_default := false;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_payment_collection_setups_prepare on app.payment_collection_setups;
create trigger trg_payment_collection_setups_prepare
before insert or update on app.payment_collection_setups
for each row
execute function app.prepare_payment_collection_setup();

drop trigger if exists trg_payment_collection_setups_updated_at on app.payment_collection_setups;
create trigger trg_payment_collection_setups_updated_at
before update on app.payment_collection_setups
for each row
execute function app.set_updated_at();

create index if not exists idx_payment_collection_setups_workspace_status
  on app.payment_collection_setups(workspace_id, lifecycle_status, scope_type)
  where deleted_at is null;
create index if not exists idx_payment_collection_setups_property_status
  on app.payment_collection_setups(property_id, lifecycle_status)
  where deleted_at is null and property_id is not null;
create index if not exists idx_payment_collection_setups_unit_status
  on app.payment_collection_setups(unit_id, lifecycle_status)
  where deleted_at is null and unit_id is not null;
create unique index if not exists uq_payment_collection_setups_workspace_method_active
  on app.payment_collection_setups(workspace_id, payment_method_type)
  where deleted_at is null and scope_type = 'workspace' and lifecycle_status = 'active';
create unique index if not exists uq_payment_collection_setups_property_method_active
  on app.payment_collection_setups(property_id, payment_method_type)
  where deleted_at is null and scope_type = 'property' and lifecycle_status = 'active';
create unique index if not exists uq_payment_collection_setups_unit_method_active
  on app.payment_collection_setups(unit_id, payment_method_type)
  where deleted_at is null and scope_type = 'unit' and lifecycle_status = 'active';
create unique index if not exists uq_payment_collection_setups_workspace_default_active
  on app.payment_collection_setups(workspace_id)
  where deleted_at is null and scope_type = 'workspace' and lifecycle_status = 'active' and is_default = true;
create unique index if not exists uq_payment_collection_setups_property_default_active
  on app.payment_collection_setups(property_id)
  where deleted_at is null and scope_type = 'property' and lifecycle_status = 'active' and is_default = true;
create unique index if not exists uq_payment_collection_setups_unit_default_active
  on app.payment_collection_setups(unit_id)
  where deleted_at is null and scope_type = 'unit' and lifecycle_status = 'active' and is_default = true;

create table if not exists app.rent_charge_periods (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid not null references app.units(id) on delete cascade,
  lease_agreement_id uuid not null references app.lease_agreements(id) on delete restrict,
  unit_tenancy_id uuid references app.unit_tenancies(id) on delete set null,
  charge_status app.rent_charge_status_enum not null default 'scheduled',
  billing_period_start date not null,
  billing_period_end date not null,
  due_on date not null,
  charge_label text,
  scheduled_amount numeric(12,2) not null,
  amount_paid numeric(12,2) not null default 0,
  outstanding_amount numeric(12,2) not null default 0,
  currency_code text not null default 'KES',
  last_payment_at timestamptz,
  fully_paid_at timestamptz,
  full_collection_delay_days integer,
  notes text,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_rent_charge_periods_dates check (billing_period_end >= billing_period_start),
  constraint chk_rent_charge_periods_scheduled_amount check (scheduled_amount >= 0),
  constraint chk_rent_charge_periods_amount_paid check (amount_paid >= 0),
  constraint chk_rent_charge_periods_outstanding_amount check (outstanding_amount >= 0),
  constraint chk_rent_charge_periods_currency_code check (char_length(trim(currency_code)) = 3),
  constraint chk_rent_charge_periods_charge_label_len
    check (charge_label is null or char_length(trim(charge_label)) between 2 and 160)
);

comment on table app.rent_charge_periods is
  'One expected rent receivable per billing period, tied to a lease and unit.';

create or replace function app.prepare_rent_charge_period()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_workspace_id uuid;
  v_lease_unit_id uuid;
  v_lease_property_id uuid;
  v_lease_currency_code text;
  v_tenancy_unit_id uuid;
begin
  select u.property_id, p.workspace_id
    into v_property_id, v_workspace_id
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = new.unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_property_id is null or v_workspace_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  new.property_id := v_property_id;
  new.workspace_id := v_workspace_id;

  select l.unit_id, l.property_id, l.currency_code
    into v_lease_unit_id, v_lease_property_id, v_lease_currency_code
  from app.lease_agreements l
  where l.id = new.lease_agreement_id
  limit 1;

  if v_lease_unit_id is null then
    raise exception 'Lease agreement not found';
  end if;
  if v_lease_unit_id <> new.unit_id or v_lease_property_id <> new.property_id then
    raise exception 'lease_agreement_id does not match the provided unit_id';
  end if;

  if new.unit_tenancy_id is not null then
    select t.unit_id
      into v_tenancy_unit_id
    from app.unit_tenancies t
    where t.id = new.unit_tenancy_id
    limit 1;

    if v_tenancy_unit_id is null then
      raise exception 'Unit tenancy not found';
    end if;
    if v_tenancy_unit_id <> new.unit_id then
      raise exception 'unit_tenancy_id does not belong to the provided unit_id';
    end if;
  end if;

  new.currency_code := coalesce(nullif(trim(new.currency_code), ''), v_lease_currency_code, 'KES');
  new.amount_paid := greatest(coalesce(new.amount_paid, 0), 0);
  new.outstanding_amount := greatest(coalesce(new.scheduled_amount, 0) - new.amount_paid, 0);

  if new.charge_status <> 'cancelled' then
    if new.amount_paid >= new.scheduled_amount and new.scheduled_amount > 0 then
      new.charge_status := 'paid';
      new.fully_paid_at := coalesce(new.fully_paid_at, now());
      new.full_collection_delay_days := coalesce(new.full_collection_delay_days, (new.fully_paid_at::date - new.due_on));
    elsif new.amount_paid > 0 then
      new.charge_status := case when new.due_on < current_date then 'overdue' else 'partially_paid' end;
      new.fully_paid_at := null;
      new.full_collection_delay_days := null;
    else
      new.charge_status := case when new.due_on < current_date then 'overdue' else 'scheduled' end;
      new.fully_paid_at := null;
      new.full_collection_delay_days := null;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_rent_charge_periods_prepare on app.rent_charge_periods;
create trigger trg_rent_charge_periods_prepare
before insert or update on app.rent_charge_periods
for each row
execute function app.prepare_rent_charge_period();

drop trigger if exists trg_rent_charge_periods_updated_at on app.rent_charge_periods;
create trigger trg_rent_charge_periods_updated_at
before update on app.rent_charge_periods
for each row
execute function app.set_updated_at();

create index if not exists idx_rent_charge_periods_workspace_period
  on app.rent_charge_periods(workspace_id, billing_period_start, billing_period_end)
  where deleted_at is null;
create index if not exists idx_rent_charge_periods_property_due_status
  on app.rent_charge_periods(property_id, due_on, charge_status)
  where deleted_at is null;
create index if not exists idx_rent_charge_periods_unit_due_status
  on app.rent_charge_periods(unit_id, due_on, charge_status)
  where deleted_at is null;
create index if not exists idx_rent_charge_periods_lease
  on app.rent_charge_periods(lease_agreement_id)
  where deleted_at is null;
create unique index if not exists uq_rent_charge_periods_lease_period_active
  on app.rent_charge_periods(lease_agreement_id, billing_period_start, billing_period_end)
  where deleted_at is null and charge_status <> 'cancelled';

create table if not exists app.payment_records (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_id uuid references app.properties(id) on delete set null,
  unit_id uuid references app.units(id) on delete set null,
  lease_agreement_id uuid references app.lease_agreements(id) on delete set null,
  unit_tenancy_id uuid references app.unit_tenancies(id) on delete set null,
  collection_setup_id uuid references app.payment_collection_setups(id) on delete set null,
  recorded_status app.payment_record_status_enum not null default 'recorded',
  record_source app.payment_record_source_enum not null default 'manual_entry',
  allocation_status app.payment_allocation_status_enum not null default 'unapplied',
  payment_method_type app.payment_method_type_enum not null,
  amount numeric(12,2) not null,
  allocated_amount numeric(12,2) not null default 0,
  currency_code text not null default 'KES',
  paid_at timestamptz not null,
  payer_name text,
  payer_phone text,
  payer_user_id uuid references auth.users(id) on delete set null,
  reference_code text,
  external_receipt_number text,
  proof_bucket text,
  proof_path text,
  proof_file_name text,
  proof_mime_type text,
  proof_size_bytes bigint,
  proof_external_url text,
  collection_setup_snapshot jsonb not null default '{}'::jsonb,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  verification_status_id uuid references app.lookup_verification_statuses(id) on delete set null,
  verified_by_user_id uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  recorded_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_payment_records_amount check (amount > 0),
  constraint chk_payment_records_allocated_amount check (allocated_amount >= 0 and allocated_amount <= amount),
  constraint chk_payment_records_currency_code check (char_length(trim(currency_code)) = 3),
  constraint chk_payment_records_payer_name_len
    check (payer_name is null or char_length(trim(payer_name)) between 2 and 160),
  constraint chk_payment_records_payer_phone_len
    check (payer_phone is null or char_length(trim(payer_phone)) between 7 and 32),
  constraint chk_payment_records_reference_code_len
    check (reference_code is null or char_length(trim(reference_code)) between 3 and 80),
  constraint chk_payment_records_proof_path_requires_bucket
    check (proof_path is null or proof_bucket is not null),
  constraint chk_payment_records_voided_unallocated
    check (recorded_status <> 'voided' or allocated_amount = 0)
);

comment on table app.payment_records is
  'Record-only payment evidence and transaction ledger. RealtyOdyssey records proof and matching state, not custodial balances.';

create or replace function app.prepare_payment_record()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_property_id uuid;
  v_setup_workspace_id uuid;
  v_setup_property_id uuid;
  v_setup_unit_id uuid;
  v_setup_payment_method_type app.payment_method_type_enum;
  v_setup_scope_type app.payment_scope_enum;
  v_setup_display_name text;
  v_setup_account_name text;
  v_setup_paybill_number text;
  v_setup_till_number text;
  v_setup_send_money_phone_number text;
  v_setup_account_reference_hint text;
  v_setup_collection_instructions text;
  v_lease record;
  v_tenancy record;
begin
  if new.collection_setup_id is not null then
    select
      s.workspace_id, s.property_id, s.unit_id, s.payment_method_type, s.scope_type,
      s.display_name, s.account_name, s.paybill_number, s.till_number,
      s.send_money_phone_number, s.account_reference_hint, s.collection_instructions
    into
      v_setup_workspace_id, v_setup_property_id, v_setup_unit_id, v_setup_payment_method_type,
      v_setup_scope_type, v_setup_display_name, v_setup_account_name, v_setup_paybill_number,
      v_setup_till_number, v_setup_send_money_phone_number, v_setup_account_reference_hint,
      v_setup_collection_instructions
    from app.payment_collection_setups s
    where s.id = new.collection_setup_id
      and s.deleted_at is null
    limit 1;

    if v_setup_workspace_id is null then
      raise exception 'Payment collection setup not found or deleted';
    end if;
    if new.workspace_id is not null and new.workspace_id <> v_setup_workspace_id then
      raise exception 'collection_setup_id does not belong to the provided workspace_id';
    end if;
    if new.property_id is not null and v_setup_property_id is not null and new.property_id <> v_setup_property_id then
      raise exception 'collection_setup_id does not belong to the provided property_id';
    end if;
    if new.unit_id is not null and v_setup_unit_id is not null and new.unit_id <> v_setup_unit_id then
      raise exception 'collection_setup_id does not belong to the provided unit_id';
    end if;
    if new.payment_method_type is not null and new.payment_method_type <> v_setup_payment_method_type then
      raise exception 'payment_method_type must match the linked collection_setup_id';
    end if;

    if new.collection_setup_snapshot = '{}'::jsonb then
      new.collection_setup_snapshot := jsonb_build_object(
        'scope_type', v_setup_scope_type,
        'payment_method_type', v_setup_payment_method_type,
        'display_name', v_setup_display_name,
        'account_name', v_setup_account_name,
        'paybill_number', v_setup_paybill_number,
        'till_number', v_setup_till_number,
        'send_money_phone_number', v_setup_send_money_phone_number,
        'account_reference_hint', v_setup_account_reference_hint,
        'collection_instructions', v_setup_collection_instructions
      );
    end if;
  end if;

  if new.lease_agreement_id is not null then
    select l.property_id, l.unit_id, l.currency_code
      into v_lease
    from app.lease_agreements l
    where l.id = new.lease_agreement_id
    limit 1;

    if v_lease.unit_id is null then
      raise exception 'Lease agreement not found';
    end if;
    if new.unit_id is null then
      new.unit_id := v_lease.unit_id;
    elsif new.unit_id <> v_lease.unit_id then
      raise exception 'lease_agreement_id does not match the provided unit_id';
    end if;
    if new.property_id is null then
      new.property_id := v_lease.property_id;
    elsif new.property_id <> v_lease.property_id then
      raise exception 'lease_agreement_id does not match the provided property_id';
    end if;

    new.currency_code := coalesce(nullif(trim(new.currency_code), ''), v_lease.currency_code, 'KES');
  end if;

  if new.unit_tenancy_id is not null then
    select t.property_id, t.unit_id
      into v_tenancy
    from app.unit_tenancies t
    where t.id = new.unit_tenancy_id
    limit 1;

    if v_tenancy.unit_id is null then
      raise exception 'Unit tenancy not found';
    end if;
    if new.unit_id is null then
      new.unit_id := v_tenancy.unit_id;
    elsif new.unit_id <> v_tenancy.unit_id then
      raise exception 'unit_tenancy_id does not match the provided unit_id';
    end if;
    if new.property_id is null then
      new.property_id := v_tenancy.property_id;
    elsif new.property_id <> v_tenancy.property_id then
      raise exception 'unit_tenancy_id does not match the provided property_id';
    end if;
  end if;

  if new.unit_id is not null then
    select u.property_id, p.workspace_id
      into v_property_id, v_workspace_id
    from app.units u
    join app.properties p on p.id = u.property_id
    where u.id = new.unit_id
      and u.deleted_at is null
      and p.deleted_at is null
    limit 1;

    if v_property_id is null or v_workspace_id is null then
      raise exception 'Unit not found or deleted';
    end if;
    if new.property_id is not null and new.property_id <> v_property_id then
      raise exception 'unit_id does not belong to the provided property_id';
    end if;

    new.property_id := v_property_id;
    new.workspace_id := v_workspace_id;
  elsif new.property_id is not null then
    select p.workspace_id
      into v_workspace_id
    from app.properties p
    where p.id = new.property_id
      and p.deleted_at is null
    limit 1;

    if v_workspace_id is null then
      raise exception 'Property not found or deleted';
    end if;
    new.workspace_id := v_workspace_id;
  elsif v_setup_workspace_id is not null then
    new.workspace_id := coalesce(new.workspace_id, v_setup_workspace_id);
    new.property_id := coalesce(new.property_id, v_setup_property_id);
    new.unit_id := coalesce(new.unit_id, v_setup_unit_id);
  elsif new.workspace_id is null then
    raise exception 'workspace_id is required when property_id, unit_id, and collection_setup_id are null';
  end if;

  if v_setup_workspace_id is not null and new.workspace_id <> v_setup_workspace_id then
    raise exception 'Resolved workspace_id does not match the linked collection_setup_id';
  end if;
  if v_setup_property_id is not null and new.property_id is not null and new.property_id <> v_setup_property_id then
    raise exception 'Resolved property_id does not match the linked collection_setup_id';
  end if;
  if v_setup_unit_id is not null and new.unit_id is not null and new.unit_id <> v_setup_unit_id then
    raise exception 'Resolved unit_id does not match the linked collection_setup_id';
  end if;

  if v_setup_payment_method_type is not null then
    new.payment_method_type := coalesce(new.payment_method_type, v_setup_payment_method_type);
  end if;

  if tg_op = 'INSERT' then
    new.allocated_amount := coalesce(new.allocated_amount, 0);
    new.allocation_status := case
      when coalesce(new.allocated_amount, 0) = 0 then 'unapplied'
      when new.allocated_amount < new.amount then 'partially_applied'
      else 'fully_applied'
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_payment_records_prepare on app.payment_records;
create trigger trg_payment_records_prepare
before insert or update on app.payment_records
for each row
execute function app.prepare_payment_record();

drop trigger if exists trg_payment_records_updated_at on app.payment_records;
create trigger trg_payment_records_updated_at
before update on app.payment_records
for each row
execute function app.set_updated_at();

create index if not exists idx_payment_records_workspace_paid_at
  on app.payment_records(workspace_id, paid_at desc)
  where deleted_at is null;
create index if not exists idx_payment_records_property_paid_at
  on app.payment_records(property_id, paid_at desc)
  where deleted_at is null and property_id is not null;
create index if not exists idx_payment_records_unit_paid_at
  on app.payment_records(unit_id, paid_at desc)
  where deleted_at is null and unit_id is not null;
create index if not exists idx_payment_records_allocation_status
  on app.payment_records(allocation_status, paid_at desc)
  where deleted_at is null;
create index if not exists idx_payment_records_collection_setup
  on app.payment_records(collection_setup_id)
  where deleted_at is null and collection_setup_id is not null;
create unique index if not exists uq_payment_records_workspace_reference_active
  on app.payment_records(workspace_id, lower(reference_code))
  where deleted_at is null and reference_code is not null;

create table if not exists app.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid not null references app.units(id) on delete cascade,
  payment_record_id uuid not null references app.payment_records(id) on delete cascade,
  rent_charge_period_id uuid not null references app.rent_charge_periods(id) on delete restrict,
  allocation_source app.payment_allocation_source_enum not null default 'manual',
  allocated_amount numeric(12,2) not null,
  allocated_by_user_id uuid references auth.users(id) on delete set null,
  allocated_at timestamptz not null default now(),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint chk_payment_allocations_allocated_amount check (allocated_amount > 0)
);

comment on table app.payment_allocations is
  'Application of recorded payments to expected rent charge periods. Supports partial and split matching.';

drop trigger if exists trg_payment_allocations_updated_at on app.payment_allocations;
create trigger trg_payment_allocations_updated_at
before update on app.payment_allocations
for each row
execute function app.set_updated_at();

create index if not exists idx_payment_allocations_payment_record
  on app.payment_allocations(payment_record_id)
  where deleted_at is null;
create index if not exists idx_payment_allocations_rent_charge_period
  on app.payment_allocations(rent_charge_period_id)
  where deleted_at is null;
create index if not exists idx_payment_allocations_property_allocated_at
  on app.payment_allocations(property_id, allocated_at desc)
  where deleted_at is null;
create unique index if not exists uq_payment_allocations_payment_charge_active
  on app.payment_allocations(payment_record_id, rent_charge_period_id)
  where deleted_at is null;

create or replace function app.refresh_payment_record_allocation_state(
  p_payment_record_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_total_allocated numeric(12,2);
begin
  select coalesce(sum(pa.allocated_amount), 0)::numeric(12,2)
    into v_total_allocated
  from app.payment_allocations pa
  where pa.payment_record_id = p_payment_record_id
    and pa.deleted_at is null;

  update app.payment_records pr
     set allocated_amount = v_total_allocated,
         allocation_status = case
           when v_total_allocated <= 0 then 'unapplied'::app.payment_allocation_status_enum
           when v_total_allocated < pr.amount then 'partially_applied'::app.payment_allocation_status_enum
           else 'fully_applied'::app.payment_allocation_status_enum
         end
   where pr.id = p_payment_record_id;
end;
$$;

create or replace function app.refresh_rent_charge_period_payment_state(
  p_rent_charge_period_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_total_paid numeric(12,2);
  v_last_payment_at timestamptz;
begin
  select
    coalesce(sum(pa.allocated_amount), 0)::numeric(12,2),
    max(pr.paid_at)
    into v_total_paid, v_last_payment_at
  from app.payment_allocations pa
  join app.payment_records pr
    on pr.id = pa.payment_record_id
   and pr.deleted_at is null
   and pr.recorded_status = 'recorded'
  where pa.rent_charge_period_id = p_rent_charge_period_id
    and pa.deleted_at is null;

  update app.rent_charge_periods rc
     set amount_paid = v_total_paid,
         outstanding_amount = greatest(rc.scheduled_amount - v_total_paid, 0),
         last_payment_at = v_last_payment_at,
         fully_paid_at = case
           when rc.charge_status = 'cancelled' then rc.fully_paid_at
           when v_total_paid >= rc.scheduled_amount and rc.scheduled_amount > 0 then v_last_payment_at
           else null
         end,
         full_collection_delay_days = case
           when rc.charge_status = 'cancelled' then rc.full_collection_delay_days
           when v_total_paid >= rc.scheduled_amount and rc.scheduled_amount > 0 and v_last_payment_at is not null
             then (v_last_payment_at::date - rc.due_on)
           else null
         end,
         charge_status = case
           when rc.charge_status = 'cancelled' then 'cancelled'::app.rent_charge_status_enum
           when v_total_paid >= rc.scheduled_amount and rc.scheduled_amount > 0 then 'paid'::app.rent_charge_status_enum
           when v_total_paid > 0 and rc.due_on < current_date then 'overdue'::app.rent_charge_status_enum
           when v_total_paid > 0 then 'partially_paid'::app.rent_charge_status_enum
           when rc.due_on < current_date then 'overdue'::app.rent_charge_status_enum
           else 'scheduled'::app.rent_charge_status_enum
         end
   where rc.id = p_rent_charge_period_id;
end;
$$;

create or replace function app.validate_payment_allocation()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_payment record;
  v_charge record;
  v_existing_payment_total numeric(12,2);
  v_existing_charge_total numeric(12,2);
begin
  select pr.id, pr.workspace_id, pr.property_id, pr.unit_id, pr.amount, pr.recorded_status
    into v_payment
  from app.payment_records pr
  where pr.id = new.payment_record_id
    and pr.deleted_at is null
  limit 1;

  if v_payment.id is null then
    raise exception 'Payment record not found or deleted';
  end if;
  if v_payment.recorded_status = 'voided' then
    raise exception 'Cannot allocate a voided payment record';
  end if;

  select rc.id, rc.workspace_id, rc.property_id, rc.unit_id, rc.scheduled_amount, rc.charge_status
    into v_charge
  from app.rent_charge_periods rc
  where rc.id = new.rent_charge_period_id
    and rc.deleted_at is null
  limit 1;

  if v_charge.id is null then
    raise exception 'Rent charge period not found or deleted';
  end if;
  if v_charge.charge_status = 'cancelled' then
    raise exception 'Cannot allocate against a cancelled rent charge period';
  end if;
  if v_payment.workspace_id <> v_charge.workspace_id then
    raise exception 'Payment record and rent charge period must belong to the same workspace';
  end if;
  if v_payment.property_id is not null and v_payment.property_id <> v_charge.property_id then
    raise exception 'Payment record and rent charge period must belong to the same property';
  end if;
  if v_payment.unit_id is not null and v_payment.unit_id <> v_charge.unit_id then
    raise exception 'Unit-scoped payment record cannot be allocated to another unit';
  end if;

  select coalesce(sum(pa.allocated_amount), 0)::numeric(12,2)
    into v_existing_payment_total
  from app.payment_allocations pa
  where pa.payment_record_id = new.payment_record_id
    and pa.deleted_at is null
    and (tg_op <> 'UPDATE' or pa.id <> new.id);

  if v_existing_payment_total + new.allocated_amount > v_payment.amount then
    raise exception 'Allocation exceeds the remaining payment amount';
  end if;

  select coalesce(sum(pa.allocated_amount), 0)::numeric(12,2)
    into v_existing_charge_total
  from app.payment_allocations pa
  where pa.rent_charge_period_id = new.rent_charge_period_id
    and pa.deleted_at is null
    and (tg_op <> 'UPDATE' or pa.id <> new.id);

  if v_existing_charge_total + new.allocated_amount > v_charge.scheduled_amount then
    raise exception 'Allocation exceeds the remaining rent charge amount';
  end if;

  new.workspace_id := v_charge.workspace_id;
  new.property_id := v_charge.property_id;
  new.unit_id := v_charge.unit_id;

  return new;
end;
$$;

create or replace function app.sync_payment_allocation_rollups()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    perform app.refresh_payment_record_allocation_state(new.payment_record_id);
    perform app.refresh_rent_charge_period_payment_state(new.rent_charge_period_id);
  end if;

  if tg_op = 'DELETE' then
    perform app.refresh_payment_record_allocation_state(old.payment_record_id);
    perform app.refresh_rent_charge_period_payment_state(old.rent_charge_period_id);
  end if;

  if tg_op = 'UPDATE' then
    if old.payment_record_id is distinct from new.payment_record_id then
      perform app.refresh_payment_record_allocation_state(old.payment_record_id);
    end if;
    if old.rent_charge_period_id is distinct from new.rent_charge_period_id then
      perform app.refresh_rent_charge_period_payment_state(old.rent_charge_period_id);
    end if;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_payment_allocations_validate on app.payment_allocations;
create trigger trg_payment_allocations_validate
before insert or update of payment_record_id, rent_charge_period_id, allocated_amount
on app.payment_allocations
for each row
execute function app.validate_payment_allocation();

drop trigger if exists trg_payment_allocations_rollups on app.payment_allocations;
create trigger trg_payment_allocations_rollups
after insert or update or delete on app.payment_allocations
for each row
execute function app.sync_payment_allocation_rollups();

create or replace function app.has_financial_management_access(p_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select
    app.is_property_workspace_owner(p_property_id)
    or exists (
      select 1
      from app.property_memberships pm
      join app.roles r on r.id = pm.role_id and r.deleted_at is null
      join app.lookup_domain_scopes ds on ds.id = pm.domain_scope_id and ds.deleted_at is null
      where pm.property_id = p_property_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.deleted_at is null
        and (pm.ends_at is null or pm.ends_at > now())
        and upper(coalesce(r.key, '')) in ('OWNER', 'PROPERTY_MANAGER')
        and ds.code in ('FINANCIAL', 'FULL_PROPERTY')
    );
$$;

create or replace function app.assert_financial_management_access(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if not app.has_financial_management_access(p_property_id) then
    raise exception 'Forbidden: requires owner or authorized financial management access';
  end if;
end;
$$;

create or replace function app.get_effective_payment_collection_setups(
  p_unit_id uuid,
  p_as_of timestamptz default now()
)
returns table (
  setup_id uuid,
  scope_type app.payment_scope_enum,
  payment_method_type app.payment_method_type_enum,
  is_default boolean,
  priority_rank integer,
  display_name text,
  account_name text,
  paybill_number text,
  till_number text,
  send_money_phone_number text,
  account_reference_hint text,
  collection_instructions text
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_workspace_id uuid;
  v_effective_scope app.payment_scope_enum := 'workspace';
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select u.property_id, p.workspace_id
    into v_property_id, v_workspace_id
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_property_id is null or v_workspace_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  perform app.assert_financial_management_access(v_property_id);

  if exists (
    select 1
    from app.payment_collection_setups s
    where s.unit_id = p_unit_id
      and s.deleted_at is null
      and s.lifecycle_status = 'active'
      and s.activated_at <= p_as_of
      and (s.deactivated_at is null or s.deactivated_at > p_as_of)
  ) then
    v_effective_scope := 'unit';
  elsif exists (
    select 1
    from app.payment_collection_setups s
    where s.property_id = v_property_id
      and s.scope_type = 'property'
      and s.deleted_at is null
      and s.lifecycle_status = 'active'
      and s.activated_at <= p_as_of
      and (s.deactivated_at is null or s.deactivated_at > p_as_of)
  ) then
    v_effective_scope := 'property';
  end if;

  return query
  select
    s.id,
    s.scope_type,
    s.payment_method_type,
    s.is_default,
    s.priority_rank,
    s.display_name,
    s.account_name,
    s.paybill_number,
    s.till_number,
    s.send_money_phone_number,
    s.account_reference_hint,
    s.collection_instructions
  from app.payment_collection_setups s
  where s.deleted_at is null
    and s.lifecycle_status = 'active'
    and s.activated_at <= p_as_of
    and (s.deactivated_at is null or s.deactivated_at > p_as_of)
    and (
      (v_effective_scope = 'unit' and s.unit_id = p_unit_id)
      or
      (v_effective_scope = 'property' and s.scope_type = 'property' and s.property_id = v_property_id)
      or
      (v_effective_scope = 'workspace' and s.scope_type = 'workspace' and s.workspace_id = v_workspace_id)
    )
  order by s.is_default desc, s.priority_rank asc, s.created_at desc;
end;
$$;

alter table app.payment_collection_setups enable row level security;
alter table app.rent_charge_periods enable row level security;
alter table app.payment_records enable row level security;
alter table app.payment_allocations enable row level security;

alter table app.payment_collection_setups force row level security;
alter table app.rent_charge_periods force row level security;
alter table app.payment_records force row level security;
alter table app.payment_allocations force row level security;

drop policy if exists payment_collection_setups_select_financial_control on app.payment_collection_setups;
create policy payment_collection_setups_select_financial_control
on app.payment_collection_setups
for select
to authenticated
using (
  deleted_at is null
  and (
    (
      scope_type = 'workspace'
      and (
        app.is_workspace_owner(workspace_id)
        or app.is_workspace_admin(workspace_id)
      )
    )
    or
    (
      property_id is not null
      and app.has_financial_management_access(property_id)
    )
  )
);

drop policy if exists rent_charge_periods_select_financial_control on app.rent_charge_periods;
create policy rent_charge_periods_select_financial_control
on app.rent_charge_periods
for select
to authenticated
using (
  deleted_at is null
  and app.has_financial_management_access(property_id)
);

drop policy if exists payment_records_select_financial_control on app.payment_records;
create policy payment_records_select_financial_control
on app.payment_records
for select
to authenticated
using (
  deleted_at is null
  and (
    (property_id is not null and app.has_financial_management_access(property_id))
    or
    (
      property_id is null
      and (
        app.is_workspace_owner(workspace_id)
        or app.is_workspace_admin(workspace_id)
      )
    )
  )
);

drop policy if exists payment_allocations_select_financial_control on app.payment_allocations;
create policy payment_allocations_select_financial_control
on app.payment_allocations
for select
to authenticated
using (
  deleted_at is null
  and app.has_financial_management_access(property_id)
);

revoke all on function app.refresh_payment_record_allocation_state(uuid) from public, anon, authenticated;
revoke all on function app.refresh_rent_charge_period_payment_state(uuid) from public, anon, authenticated;
revoke all on function app.validate_payment_allocation() from public, anon, authenticated;
revoke all on function app.sync_payment_allocation_rollups() from public, anon, authenticated;
revoke all on function app.has_financial_management_access(uuid) from public;
revoke all on function app.assert_financial_management_access(uuid) from public, anon, authenticated;
revoke all on function app.get_effective_payment_collection_setups(uuid, timestamptz) from public, anon, authenticated;

grant execute on function app.has_financial_management_access(uuid) to authenticated;
grant execute on function app.get_effective_payment_collection_setups(uuid, timestamptz) to authenticated;
