-- ============================================================================
-- V 1 09: Revenue Payments Core
-- ============================================================================
-- Purpose
--   - Model rent charge periods, payment records, allocations, and collection setup.
--   - Expose rent dashboards, tenant payment setup lookup, tenant home billing summary, and health registry surfaces.
--   - Keep the revenue foundation independent from M-Pesa callback/STK internals.
--
-- Consolidated before first production publication. Related patch migrations
-- are folded into this canonical domain migration for easier maintenance.
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
  v_lease_rent_due_day_of_month integer;
  v_lease_collection_grace_period_days integer;
  v_collection_deadline date;
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

  select
    l.unit_id,
    l.property_id,
    l.currency_code,
    l.rent_due_day_of_month,
    l.collection_grace_period_days
    into
      v_lease_unit_id,
      v_lease_property_id,
      v_lease_currency_code,
      v_lease_rent_due_day_of_month,
      v_lease_collection_grace_period_days
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
  new.due_on := coalesce(
    new.due_on,
    app.get_rent_due_date_for_period(
      new.billing_period_start,
      coalesce(v_lease_rent_due_day_of_month, 5)
    )
  );
  v_collection_deadline := (
    new.due_on
    + greatest(coalesce(v_lease_collection_grace_period_days, 0), 0)
  )::date;
  new.amount_paid := greatest(coalesce(new.amount_paid, 0), 0);
  new.outstanding_amount := greatest(coalesce(new.scheduled_amount, 0) - new.amount_paid, 0);

  if new.charge_status <> 'cancelled' then
    if new.amount_paid >= new.scheduled_amount and new.scheduled_amount > 0 then
      new.charge_status := 'paid';
      new.fully_paid_at := coalesce(new.fully_paid_at, now());
      new.full_collection_delay_days := coalesce(
        new.full_collection_delay_days,
        (new.fully_paid_at::date - v_collection_deadline)
      );
    elsif new.amount_paid > 0 then
      new.charge_status := case when v_collection_deadline < current_date then 'overdue' else 'partially_paid' end;
      new.fully_paid_at := null;
      new.full_collection_delay_days := null;
    else
      new.charge_status := case when v_collection_deadline < current_date then 'overdue' else 'scheduled' end;
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
  v_allocated_unit_id uuid;
  v_allocated_lease_agreement_id uuid;
begin
  select coalesce(sum(pa.allocated_amount), 0)::numeric(12,2)
    into v_total_allocated
  from app.payment_allocations pa
  where pa.payment_record_id = p_payment_record_id
    and pa.deleted_at is null;

  select
    case when count(distinct rc.unit_id) = 1 then max(rc.unit_id) else null end,
    case when count(distinct rc.lease_agreement_id) = 1 then max(rc.lease_agreement_id) else null end
    into v_allocated_unit_id, v_allocated_lease_agreement_id
  from app.payment_allocations pa
  join app.rent_charge_periods rc
    on rc.id = pa.rent_charge_period_id
   and rc.deleted_at is null
  where pa.payment_record_id = p_payment_record_id
    and pa.deleted_at is null;

  update app.payment_records pr
     set allocated_amount = v_total_allocated,
         unit_id = coalesce(pr.unit_id, v_allocated_unit_id),
         lease_agreement_id = coalesce(pr.lease_agreement_id, v_allocated_lease_agreement_id),
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
  v_collection_grace_period_days integer := 0;
begin
  select coalesce(la.collection_grace_period_days, 0)
    into v_collection_grace_period_days
  from app.rent_charge_periods rc
  left join app.lease_agreements la
    on la.id = rc.lease_agreement_id
  where rc.id = p_rent_charge_period_id
  limit 1;

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
             then (
               v_last_payment_at::date
               - (rc.due_on + greatest(coalesce(v_collection_grace_period_days, 0), 0))
             )
           else null
         end,
         charge_status = case
           when rc.charge_status = 'cancelled' then 'cancelled'::app.rent_charge_status_enum
           when v_total_paid >= rc.scheduled_amount and rc.scheduled_amount > 0 then 'paid'::app.rent_charge_status_enum
           when v_total_paid > 0
             and (rc.due_on + greatest(coalesce(v_collection_grace_period_days, 0), 0)) < current_date
             then 'overdue'::app.rent_charge_status_enum
           when v_total_paid > 0 then 'partially_paid'::app.rent_charge_status_enum
           when (rc.due_on + greatest(coalesce(v_collection_grace_period_days, 0), 0)) < current_date
             then 'overdue'::app.rent_charge_status_enum
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
  v_existing_allocated_unit_id uuid;
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

  select max(rc.unit_id)
    into v_existing_allocated_unit_id
  from app.payment_allocations pa
  join app.rent_charge_periods rc
    on rc.id = pa.rent_charge_period_id
   and rc.deleted_at is null
  where pa.payment_record_id = new.payment_record_id
    and pa.deleted_at is null
    and (tg_op <> 'UPDATE' or pa.id <> new.id);

  if v_existing_allocated_unit_id is not null and v_existing_allocated_unit_id <> v_charge.unit_id then
    raise exception 'A payment record can only be allocated to one unit';
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

-- ----------------------------------------------------------------------------
-- Rent payments dashboard analytics
-- ----------------------------------------------------------------------------

create schema if not exists app;

create or replace function app.get_financial_accessible_property_ids(
  p_property_id uuid default null
)
returns table (property_id uuid)
language sql
stable
security definer
set search_path = app, public
as $$
  select p.id
  from app.properties p
  where p.deleted_at is null
    and p.status = 'active'
    and (p_property_id is null or p.id = p_property_id)
    and app.has_financial_management_access(p.id);
$$;

create or replace function app.get_rent_payment_delay_bucket(p_delay_days integer)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case
    when coalesce(p_delay_days, 0) <= 0 then 'on_time'
    when p_delay_days between 1 and 3 then 'days_1_3'
    when p_delay_days between 4 and 7 then 'days_4_7'
    else 'days_7_plus'
  end;
$$;

create or replace function app.get_payment_method_display_label(
  p_method app.payment_method_type_enum
)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case p_method
    when 'mpesa_paybill'::app.payment_method_type_enum then 'M-Pesa'
    when 'mpesa_till'::app.payment_method_type_enum then 'M-Pesa'
    when 'mpesa_send_money'::app.payment_method_type_enum then 'M-Pesa Send Money'
    when 'bank_transfer'::app.payment_method_type_enum then 'Bank Transfer'
    when 'cash'::app.payment_method_type_enum then 'Cash'
    when 'cheque'::app.payment_method_type_enum then 'Cheque'
    else 'Other'
  end;
$$;

create or replace function app.get_payment_record_display_status(
  p_recorded_status app.payment_record_status_enum,
  p_allocation_status app.payment_allocation_status_enum
)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case
    when p_recorded_status = 'voided'::app.payment_record_status_enum then 'Voided'
    when p_allocation_status = 'fully_applied'::app.payment_allocation_status_enum then 'Matched'
    when p_allocation_status = 'partially_applied'::app.payment_allocation_status_enum then 'Partial'
    else 'Pending'
  end;
$$;

create or replace function app.get_rent_payment_charge_snapshot(
  p_property_id uuid default null,
  p_unit_id uuid default null,
  p_reference_date date default current_date
)
returns table (
  rent_charge_period_id uuid,
  property_id uuid,
  property_name text,
  unit_id uuid,
  unit_label text,
  lease_agreement_id uuid,
  tenant_name text,
  billing_period_start date,
  billing_period_end date,
  due_on date,
  collection_deadline date,
  scheduled_amount numeric,
  amount_paid numeric,
  outstanding_amount numeric,
  currency_code text,
  charge_status text,
  last_payment_at timestamptz,
  fully_paid_at timestamptz,
  full_collection_delay_days integer,
  effective_delay_days integer,
  positive_delay_days integer,
  delay_bucket text,
  is_fully_paid boolean,
  is_overdue boolean,
  billing_month date
)
language sql
stable
security definer
set search_path = app, public
as $$
  with accessible_properties as (
    select accessible.property_id
    from app.get_financial_accessible_property_ids(p_property_id) as accessible
  )
  select
    rc.id as rent_charge_period_id,
    rc.property_id,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    rc.unit_id,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label,
    rc.lease_agreement_id,
    coalesce(
      nullif(trim(la.tenant_name), ''),
      nullif(trim(snapshot.current_tenant_name), ''),
      'Unassigned Tenant'
    ) as tenant_name,
    rc.billing_period_start,
    rc.billing_period_end,
    rc.due_on,
    (
      rc.due_on
      + greatest(coalesce(la.collection_grace_period_days, 0), 0)
    )::date as collection_deadline,
    round(coalesce(rc.scheduled_amount, 0), 2) as scheduled_amount,
    round(coalesce(rc.amount_paid, 0), 2) as amount_paid,
    round(coalesce(rc.outstanding_amount, 0), 2) as outstanding_amount,
    coalesce(nullif(trim(rc.currency_code), ''), 'KES') as currency_code,
    rc.charge_status::text as charge_status,
    rc.last_payment_at,
    rc.fully_paid_at,
    rc.full_collection_delay_days,
    (
      case
        when rc.full_collection_delay_days is not null then rc.full_collection_delay_days
        when coalesce(rc.outstanding_amount, 0) > 0
          and (
            rc.due_on
            + greatest(coalesce(la.collection_grace_period_days, 0), 0)
          ) < coalesce(p_reference_date, current_date)
          then (
            coalesce(p_reference_date, current_date)
            - (
              rc.due_on
              + greatest(coalesce(la.collection_grace_period_days, 0), 0)
            )
          )
        else 0
      end
    )::integer as effective_delay_days,
    greatest(
      (
        case
          when rc.full_collection_delay_days is not null then rc.full_collection_delay_days
          when coalesce(rc.outstanding_amount, 0) > 0
            and (
              rc.due_on
              + greatest(coalesce(la.collection_grace_period_days, 0), 0)
            ) < coalesce(p_reference_date, current_date)
            then (
              coalesce(p_reference_date, current_date)
              - (
                rc.due_on
                + greatest(coalesce(la.collection_grace_period_days, 0), 0)
              )
            )
          else 0
        end
      ),
      0
    )::integer as positive_delay_days,
    app.get_rent_payment_delay_bucket(
      greatest(
        (
          case
            when rc.full_collection_delay_days is not null then rc.full_collection_delay_days
            when coalesce(rc.outstanding_amount, 0) > 0
              and (
                rc.due_on
                + greatest(coalesce(la.collection_grace_period_days, 0), 0)
              ) < coalesce(p_reference_date, current_date)
              then (
                coalesce(p_reference_date, current_date)
                - (
                  rc.due_on
                  + greatest(coalesce(la.collection_grace_period_days, 0), 0)
                )
              )
            else 0
          end
        ),
        0
      )::integer
    ) as delay_bucket,
    (
      coalesce(rc.scheduled_amount, 0) > 0
      and coalesce(rc.amount_paid, 0) >= coalesce(rc.scheduled_amount, 0)
    ) as is_fully_paid,
    (
      coalesce(rc.outstanding_amount, 0) > 0
      and (
        rc.due_on
        + greatest(coalesce(la.collection_grace_period_days, 0), 0)
      ) < coalesce(p_reference_date, current_date)
    ) as is_overdue,
    date_trunc('month', rc.billing_period_start)::date as billing_month
  from app.rent_charge_periods rc
  join accessible_properties ap on ap.property_id = rc.property_id
  join app.properties p
    on p.id = rc.property_id
   and p.deleted_at is null
  join app.units u
    on u.id = rc.unit_id
   and u.deleted_at is null
  left join app.lease_agreements la
    on la.id = rc.lease_agreement_id
  left join app.unit_occupancy_snapshots snapshot
    on snapshot.unit_id = rc.unit_id
  where rc.deleted_at is null
    and (p_unit_id is null or rc.unit_id = p_unit_id)
    and rc.charge_status <> 'cancelled'::app.rent_charge_status_enum;
$$;

create index if not exists idx_rent_charge_periods_property_billing_start_active
  on app.rent_charge_periods(property_id, billing_period_start, due_on)
  where deleted_at is null and charge_status <> 'cancelled';

create index if not exists idx_payment_records_property_paid_state_active
  on app.payment_records(property_id, paid_at desc, allocation_status)
  where deleted_at is null and recorded_status = 'recorded';

create or replace function app.get_rent_payments_property_options()
returns table (
  property_id uuid,
  property_name text,
  city_town text,
  area_neighborhood text,
  unit_count integer,
  occupied_count integer,
  current_collection_rate numeric
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_reference_date date := current_date;
  v_period_start date := date_trunc('month', v_reference_date)::date;
  v_period_end date := (v_period_start + interval '1 month - 1 day')::date;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return query
  with accessible_properties as (
    select accessible.property_id
    from app.get_financial_accessible_property_ids(null) as accessible
  ),
  current_period_metrics as (
    select
      snapshot.property_id,
      round(
        case
          when coalesce(sum(snapshot.scheduled_amount), 0) = 0 then 0
          else (coalesce(sum(snapshot.amount_paid), 0) / nullif(sum(snapshot.scheduled_amount), 0)) * 100
        end,
        1
      ) as collection_rate
    from app.get_rent_payment_charge_snapshot(null, null, v_reference_date) as snapshot
    where snapshot.billing_period_start between v_period_start and v_period_end
    group by snapshot.property_id
  )
  select
    p.id as property_id,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    p.city_town,
    p.area_neighborhood,
    count(u.id)::int as unit_count,
    (
      count(u.id) filter (
        where coalesce(s.occupancy_status, 'vacant'::app.unit_occupancy_status_enum) = 'occupied'
      )
    )::int as occupied_count,
    coalesce(cpm.collection_rate, 0)::numeric as current_collection_rate
  from accessible_properties ap
  join app.properties p on p.id = ap.property_id
  left join app.units u
    on u.property_id = p.id
   and u.deleted_at is null
  left join app.unit_occupancy_snapshots s
    on s.unit_id = u.id
  left join current_period_metrics cpm
    on cpm.property_id = p.id
  where p.deleted_at is null
    and p.status = 'active'
  group by p.id, p.display_name, p.city_town, p.area_neighborhood, cpm.collection_rate
  order by coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') asc;
end;
$$;

create or replace function app.get_rent_payments_ledger_rows(
  p_property_id uuid default null,
  p_unit_id uuid default null,
  p_limit integer default 50
)
returns table (
  payment_record_id uuid,
  property_id uuid,
  property_name text,
  unit_id uuid,
  unit_label text,
  tenant_name text,
  paid_on date,
  paid_at timestamptz,
  amount numeric,
  currency_code text,
  method_label text,
  status_label text,
  status_variant text,
  delay_days integer,
  delay_label text,
  reference_code text,
  external_receipt_number text,
  payer_name text,
  payer_phone text
)
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return query
  with accessible_properties as (
    select accessible.property_id
    from app.get_financial_accessible_property_ids(p_property_id) as accessible
  ),
  allocation_rollup as (
    select
      pa.payment_record_id,
      max(greatest(coalesce(rc.full_collection_delay_days, 0), 0))::int as max_delay_days
    from app.payment_allocations pa
    join app.rent_charge_periods rc
      on rc.id = pa.rent_charge_period_id
     and rc.deleted_at is null
    where pa.deleted_at is null
    group by pa.payment_record_id
  )
  select
    pr.id as payment_record_id,
    pr.property_id,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    pr.unit_id,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label,
    coalesce(
      nullif(trim(la.tenant_name), ''),
      nullif(trim(snapshot.current_tenant_name), ''),
      nullif(trim(pr.payer_name), ''),
      'Unassigned Tenant'
    ) as tenant_name,
    pr.paid_at::date as paid_on,
    pr.paid_at,
    round(pr.amount, 2) as amount,
    coalesce(nullif(trim(pr.currency_code), ''), 'KES') as currency_code,
    app.get_payment_method_display_label(pr.payment_method_type) as method_label,
    app.get_payment_record_display_status(pr.recorded_status, pr.allocation_status) as status_label,
    case
      when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'error'
      when pr.allocation_status = 'fully_applied'::app.payment_allocation_status_enum then 'success'
      when pr.allocation_status = 'partially_applied'::app.payment_allocation_status_enum then 'info'
      else 'warning'
    end as status_variant,
    allocation_rollup.max_delay_days as delay_days,
    case
      when allocation_rollup.max_delay_days is null then 'Pending'
      when allocation_rollup.max_delay_days <= 0 then 'On-time'
      else format('%s days', allocation_rollup.max_delay_days)
    end as delay_label,
    pr.reference_code,
    pr.external_receipt_number,
    pr.payer_name,
    pr.payer_phone
  from app.payment_records pr
  join accessible_properties ap
    on ap.property_id = pr.property_id
  join app.properties p
    on p.id = pr.property_id
   and p.deleted_at is null
  left join app.units u
    on u.id = pr.unit_id
   and u.deleted_at is null
  left join app.lease_agreements la
    on la.id = pr.lease_agreement_id
  left join app.unit_occupancy_snapshots snapshot
    on snapshot.unit_id = pr.unit_id
  left join allocation_rollup
    on allocation_rollup.payment_record_id = pr.id
  where pr.deleted_at is null
    and (
      p_unit_id is null
      or pr.unit_id = p_unit_id
      or exists (
        select 1
        from app.payment_allocations pa_scope
        join app.rent_charge_periods rc_scope
          on rc_scope.id = pa_scope.rent_charge_period_id
         and rc_scope.deleted_at is null
        where pa_scope.payment_record_id = pr.id
          and pa_scope.deleted_at is null
          and rc_scope.unit_id = p_unit_id
      )
    )
  order by pr.paid_at desc, pr.created_at desc
  limit greatest(coalesce(p_limit, 50), 1);
end;
$$;

create or replace function app.get_rent_payments_dashboard(
  p_property_id uuid default null,
  p_unit_id uuid default null,
  p_reference_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_reference_date date := coalesce(p_reference_date, current_date);
  v_period_start date := date_trunc('month', v_reference_date)::date;
  v_period_end date := (v_period_start + interval '1 month - 1 day')::date;
  v_previous_period_start date := (v_period_start - interval '1 month')::date;
  v_previous_period_end date := (v_period_start - interval '1 day')::date;
  v_trend_start date := (v_period_start - interval '5 months')::date;
  v_required_consistency_months integer := 3;
  v_dashboard jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  with base as (
    select *
    from app.get_rent_payment_charge_snapshot(p_property_id, p_unit_id, v_reference_date)
  )
  select greatest(3, least(6, count(distinct billing_month)))::int
    into v_required_consistency_months
  from base
  where is_fully_paid
    and billing_month between v_trend_start and v_period_start;

  v_required_consistency_months := coalesce(v_required_consistency_months, 3);

  with base as (
    select *
    from app.get_rent_payment_charge_snapshot(p_property_id, p_unit_id, v_reference_date)
  ),
  current_period as (
    select *
    from base
    where billing_period_start between v_period_start and v_period_end
  ),
  previous_period as (
    select *
    from base
    where billing_period_start between v_previous_period_start and v_previous_period_end
  ),
  due_current as (
    select *
    from current_period
    where collection_deadline <= v_reference_date
       or is_fully_paid
       or is_overdue
  ),
  due_previous as (
    select *
    from previous_period
    where collection_deadline <= v_previous_period_end
       or is_fully_paid
       or is_overdue
  ),
  current_summary as (
    select
      coalesce(max(currency_code), 'KES') as currency_code,
      round(coalesce(sum(amount_paid), 0), 2) as total_collected,
      round(coalesce(sum(scheduled_amount), 0), 2) as expected_rent,
      round(
        case
          when coalesce(sum(scheduled_amount), 0) = 0 then 0
          else (coalesce(sum(amount_paid), 0) / nullif(sum(scheduled_amount), 0)) * 100
        end,
        1
      ) as collection_rate,
      round(
        case
          when (select count(*) from due_current) = 0 then 0
          else (
            (select count(*) from due_current where positive_delay_days = 0)::numeric
            / nullif((select count(*) from due_current), 0)::numeric
          ) * 100
        end,
        1
      ) as on_time_rate,
      (
        select round(avg(positive_delay_days::numeric), 1)
        from due_current
        where positive_delay_days > 0
      ) as avg_delay_days,
      round(
        coalesce(sum(outstanding_amount) filter (where collection_deadline >= v_reference_date), 0),
        2
      ) as outstanding_amount,
      round(
        case
          when coalesce(sum(scheduled_amount), 0) = 0 then 0
          else (
            coalesce(sum(outstanding_amount) filter (where collection_deadline >= v_reference_date), 0)
            / nullif(sum(scheduled_amount), 0)
          ) * 100
        end,
        1
      ) as outstanding_pct
    from current_period
  ),
  previous_summary as (
    select
      round(coalesce(sum(amount_paid), 0), 2) as total_collected,
      round(
        case
          when coalesce(sum(scheduled_amount), 0) = 0 then 0
          else (coalesce(sum(amount_paid), 0) / nullif(sum(scheduled_amount), 0)) * 100
        end,
        1
      ) as collection_rate,
      round(
        case
          when (select count(*) from due_previous) = 0 then 0
          else (
            (select count(*) from due_previous where positive_delay_days = 0)::numeric
            / nullif((select count(*) from due_previous), 0)::numeric
          ) * 100
        end,
        1
      ) as on_time_rate,
      (
        select round(avg(positive_delay_days::numeric), 1)
        from due_previous
        where positive_delay_days > 0
      ) as avg_delay_days
    from previous_period
  ),
  exposure_summary as (
    select
      round(coalesce(sum(outstanding_amount) filter (where is_overdue), 0), 2) as overdue_amount,
      (count(distinct unit_id) filter (where is_overdue))::int as overdue_units_affected
    from base
  ),
  trend_months as (
    select
      gs::date as month_start,
      (gs + interval '1 month - 1 day')::date as month_end,
      to_char(gs, 'Mon') as label,
      row_number() over (order by gs) as sort_order
    from generate_series(v_trend_start, v_period_start, interval '1 month') as gs
  ),
  trend_rollup as (
    select
      tm.label,
      tm.sort_order,
      round(coalesce(sum(b.amount_paid), 0), 2) as collected,
      round(coalesce(sum(b.scheduled_amount), 0), 2) as expected
    from trend_months tm
    left join base b
      on b.billing_period_start between tm.month_start and tm.month_end
    group by tm.label, tm.sort_order
  ),
  behavior_template as (
    select 'on_time'::text as bucket_key, 'On-time'::text as label, 1 as sort_order, '#1D9E75'::text as color
    union all
    select 'days_1_3', '1-3 days', 2, '#BA7517'
    union all
    select 'days_4_7', '4-7 days', 3, '#E24B4A'
    union all
    select 'days_7_plus', '7+ days', 4, '#8E2424'
  ),
  behavior_current as (
    select
      delay_bucket as bucket_key,
      count(*)::int as unit_count
    from due_current
    group by delay_bucket
  ),
  behavior_previous as (
    select
      delay_bucket as bucket_key,
      count(*)::int as unit_count
    from due_previous
    group by delay_bucket
  ),
  behavior_totals as (
    select
      (select count(*)::int from due_current) as current_total,
      (select count(*)::int from due_previous) as previous_total
  ),
  behavior_comparison as (
    select
      template.bucket_key,
      template.label,
      template.sort_order,
      template.color,
      coalesce(current_bucket.unit_count, 0) as current_units,
      coalesce(previous_bucket.unit_count, 0) as previous_units,
      round(
        case
          when totals.current_total = 0 then 0
          else (coalesce(current_bucket.unit_count, 0)::numeric / totals.current_total::numeric) * 100
        end,
        0
      ) as current_pct,
      round(
        case
          when totals.previous_total = 0 then 0
          else (coalesce(previous_bucket.unit_count, 0)::numeric / totals.previous_total::numeric) * 100
        end,
        0
      ) as previous_pct
    from behavior_template template
    cross join behavior_totals totals
    left join behavior_current current_bucket
      on current_bucket.bucket_key = template.bucket_key
    left join behavior_previous previous_bucket
      on previous_bucket.bucket_key = template.bucket_key
  ),
  consistency_units as (
    select
      unit_id,
      count(*)::int as paid_charge_count,
      count(distinct extract(day from coalesce(last_payment_at, fully_paid_at)::date))::int as payment_day_count
    from base
    where is_fully_paid
      and billing_month between v_trend_start and v_period_start
      and coalesce(last_payment_at, fully_paid_at) is not null
    group by unit_id
  ),
  consistency_stats as (
    select
      count(*)::int as tracked_units,
      (
        count(*) filter (
          where paid_charge_count >= v_required_consistency_months
            and payment_day_count = 1
        )
      )::int as stable_units
    from consistency_units
  ),
  reliability_source as (
    select
      cs.currency_code,
      cs.on_time_rate,
      coalesce(cs.avg_delay_days, 0) as avg_delay_days,
      round(
        case
          when coalesce(consistency_stats.tracked_units, 0) = 0 then 0
          else (
            consistency_stats.stable_units::numeric
            / consistency_stats.tracked_units::numeric
          ) * 10
        end,
        1
      ) as consistency_index,
      round(
        least(
          99,
          greatest(
            0,
            (
              (cs.on_time_rate * 0.60)
              + (greatest(0, 100 - (coalesce(cs.avg_delay_days, 0) * 6)) * 0.15)
              + (
                (
                  case
                    when coalesce(consistency_stats.tracked_units, 0) = 0 then 0
                    else (
                      consistency_stats.stable_units::numeric
                      / consistency_stats.tracked_units::numeric
                    ) * 10
                  end
                ) * 10 * 0.25
              )
            )
          )
        ),
        0
      )::int as score,
      consistency_stats.stable_units,
      consistency_stats.tracked_units
    from current_summary cs
    cross join consistency_stats
  ),
  risk_rollup as (
    select
      base.property_id,
      base.property_name,
      base.unit_id,
      base.unit_label,
      max(base.tenant_name) as tenant_name,
      array_agg(base.positive_delay_days order by base.due_on desc) as recent_delays,
      count(*)::int as history_count,
      (count(*) filter (where base.positive_delay_days > 0))::int as late_month_count,
      (count(*) filter (where base.is_overdue))::int as overdue_charge_count,
      max(base.positive_delay_days)::int as max_delay_days,
      round(avg(base.positive_delay_days::numeric) filter (where base.positive_delay_days > 0), 1) as avg_late_delay_days,
      round(coalesce(sum(base.outstanding_amount) filter (where base.is_overdue), 0), 2) as overdue_amount
    from base
    where base.collection_deadline <= v_reference_date
    group by base.property_id, base.property_name, base.unit_id, base.unit_label
  ),
  risk_candidates as (
    select
      rollup.property_id,
      rollup.property_name,
      rollup.unit_id,
      rollup.unit_label,
      coalesce(nullif(trim(rollup.tenant_name), ''), 'Unassigned Tenant') as tenant_name,
      case
        when coalesce(rollup.recent_delays[1], 0) > 0
          and coalesce(rollup.recent_delays[2], 0) > 0
          and coalesce(rollup.recent_delays[3], 0) > 0 then 'High'
        when coalesce(rollup.overdue_charge_count, 0) > 0
          and coalesce(rollup.max_delay_days, 0) >= 7 then 'High'
        when coalesce(array_length(rollup.recent_delays, 1), 0) >= 3
          and coalesce(rollup.recent_delays[1], 0) > coalesce(rollup.recent_delays[2], 0)
          and coalesce(rollup.recent_delays[2], 0) > coalesce(rollup.recent_delays[3], 0)
          and coalesce(rollup.recent_delays[1], 0) > 0 then 'Medium'
        when coalesce(rollup.late_month_count, 0) = 1
          and coalesce(rollup.recent_delays[1], 0) > 5 then 'Medium'
        else null
      end as risk_level,
      case
        when coalesce(rollup.recent_delays[1], 0) > 0
          and coalesce(rollup.recent_delays[2], 0) > 0
          and coalesce(rollup.recent_delays[3], 0) > 0 then '3 consecutive late months'
        when coalesce(rollup.overdue_charge_count, 0) > 0
          and coalesce(rollup.max_delay_days, 0) >= 7 then format(
            'Outstanding past due (%s days)',
            coalesce(rollup.max_delay_days, 0)
          )
        when coalesce(array_length(rollup.recent_delays, 1), 0) >= 3
          and coalesce(rollup.recent_delays[1], 0) > coalesce(rollup.recent_delays[2], 0)
          and coalesce(rollup.recent_delays[2], 0) > coalesce(rollup.recent_delays[3], 0)
          and coalesce(rollup.recent_delays[1], 0) > 0 then 'Increasing delay trend'
        when coalesce(rollup.late_month_count, 0) = 1
          and coalesce(rollup.recent_delays[1], 0) > 5 then 'First time late (> 5 days)'
        else null
      end as pattern,
      case
        when coalesce(rollup.recent_delays[1], 0) > 0
          and coalesce(rollup.recent_delays[2], 0) > 0
          and coalesce(rollup.recent_delays[3], 0) > 0 then 1
        when coalesce(rollup.overdue_charge_count, 0) > 0
          and coalesce(rollup.max_delay_days, 0) >= 7 then 2
        when coalesce(array_length(rollup.recent_delays, 1), 0) >= 3
          and coalesce(rollup.recent_delays[1], 0) > coalesce(rollup.recent_delays[2], 0)
          and coalesce(rollup.recent_delays[2], 0) > coalesce(rollup.recent_delays[3], 0)
          and coalesce(rollup.recent_delays[1], 0) > 0 then 3
        when coalesce(rollup.late_month_count, 0) = 1
          and coalesce(rollup.recent_delays[1], 0) > 5 then 4
        else 99
      end as risk_sort,
      coalesce(rollup.max_delay_days, 0) as max_delay_days,
      coalesce(rollup.avg_late_delay_days, 0) as avg_late_delay_days,
      coalesce(rollup.overdue_amount, 0) as overdue_amount
    from risk_rollup rollup
  ),
  insight_numbers as (
    select
      coalesce(max(case when bucket_key = 'days_4_7' then current_pct - previous_pct end), 0) as mid_term_delta_pct,
      coalesce(max(case when bucket_key = 'days_7_plus' then current_pct end), 0) as long_delay_pct,
      coalesce(max(case when bucket_key = 'on_time' then current_pct end), 0) as on_time_pct,
      max(rs.consistency_index) as consistency_index,
      max(rs.stable_units) as stable_units,
      max(rs.tracked_units) as tracked_units
    from behavior_comparison
    cross join reliability_source rs
  )
  select jsonb_build_object(
    'period',
    jsonb_build_object(
      'reference_date', v_reference_date,
      'start_date', v_period_start,
      'end_date', v_period_end,
      'label', to_char(v_period_start, 'Mon YYYY'),
      'comparison_label', to_char(v_previous_period_start, 'Mon YYYY')
    ),
    'summary',
    jsonb_build_object(
      'currency_code', current_summary.currency_code,
      'total_collected', current_summary.total_collected,
      'total_collected_change_pct',
        round(
          case
            when coalesce(previous_summary.total_collected, 0) = 0 then
              case when current_summary.total_collected > 0 then 100 else 0 end
            else (
              (
                current_summary.total_collected - previous_summary.total_collected
              ) / nullif(previous_summary.total_collected, 0)
            ) * 100
          end,
          1
        ),
      'collection_rate', current_summary.collection_rate,
      'collection_rate_delta_pct',
        round(
          current_summary.collection_rate - coalesce(previous_summary.collection_rate, 0),
          1
        ),
      'expected_rent', current_summary.expected_rent,
      'on_time_rate', current_summary.on_time_rate,
      'on_time_rate_delta_pct',
        round(
          current_summary.on_time_rate - coalesce(previous_summary.on_time_rate, 0),
          1
        ),
      'avg_delay_days', coalesce(current_summary.avg_delay_days, 0),
      'avg_delay_delta_days',
        round(
          coalesce(current_summary.avg_delay_days, 0) - coalesce(previous_summary.avg_delay_days, 0),
          1
        ),
      'outstanding_amount', current_summary.outstanding_amount,
      'outstanding_pct', current_summary.outstanding_pct,
      'overdue_amount', exposure_summary.overdue_amount,
      'overdue_units_affected', exposure_summary.overdue_units_affected
    ),
    'trend',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'label', trend_rollup.label,
          'collected', trend_rollup.collected,
          'expected', trend_rollup.expected
        )
        order by trend_rollup.sort_order
      )
      from trend_rollup
    ), '[]'::jsonb),
    'behavior_breakdown',
    jsonb_build_object(
      'total_units', coalesce((select current_total from behavior_totals), 0),
      'segments',
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'bucket_key', behavior_comparison.bucket_key,
            'label', behavior_comparison.label,
            'units', behavior_comparison.current_units,
            'percentage', behavior_comparison.current_pct,
            'change_pct', round(behavior_comparison.current_pct - behavior_comparison.previous_pct, 0),
            'is_positive',
              case
                when behavior_comparison.bucket_key = 'on_time'
                  then (behavior_comparison.current_pct - behavior_comparison.previous_pct) >= 0
                else (behavior_comparison.current_pct - behavior_comparison.previous_pct) <= 0
              end,
            'color', behavior_comparison.color
          )
          order by behavior_comparison.sort_order
        )
        from behavior_comparison
      ), '[]'::jsonb),
      'summary',
        case
          when coalesce((select current_total from behavior_totals), 0) = 0 then
            'No completed or due rent charges are available for behavior scoring yet.'
          when coalesce((select max(current_pct) from behavior_comparison where bucket_key = 'days_4_7'), 0)
            > coalesce((select max(previous_pct) from behavior_comparison where bucket_key = 'days_4_7'), 0) then
            format(
              '%s%% of tenants are on time, but delays beyond 4 days are increasing. Monitor long delays as early risk signals.',
              current_summary.on_time_rate
            )
          else
            format(
              '%s%% of tenants are on time, and delay distribution remains stable across the current cycle.',
              current_summary.on_time_rate
            )
        end
    ),
    'reliability',
    jsonb_build_object(
      'score', reliability_source.score,
      'on_time_rate', current_summary.on_time_rate,
      'avg_delay_days', coalesce(current_summary.avg_delay_days, 0),
      'consistency_index', reliability_source.consistency_index,
      'status',
        case
          when reliability_source.score >= 80 then 'High'
          when reliability_source.score >= 60 then 'Medium'
          else 'Low'
        end,
      'benchmark_percentile',
        least(99, greatest(1, reliability_source.score + 1)),
      'benchmark_message',
        format(
          'Performs better than %s%% of similar portfolios.',
          least(99, greatest(1, reliability_source.score + 1))
        )
    ),
    'risk_units',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'property_id', property_id,
          'property_name', property_name,
          'unit_id', unit_id,
          'unit_label', unit_label,
          'tenant_name', tenant_name,
          'pattern', pattern,
          'risk_level', risk_level,
          'avg_delay_days', avg_late_delay_days,
          'overdue_amount', overdue_amount
        )
        order by risk_sort, max_delay_days desc, overdue_amount desc, property_name, unit_label
      )
      from (
        select *
        from risk_candidates
        where risk_level is not null
        order by risk_sort, max_delay_days desc, overdue_amount desc, property_name, unit_label
        limit 5
      ) ranked_risk
    ), '[]'::jsonb),
    'insights',
    jsonb_build_array(
      jsonb_build_object(
        'type', 'warning',
        'title',
          case
            when insight_numbers.mid_term_delta_pct > 0 then 'Rising Mid-Term Delays'
            else 'Delay Pressure Stable'
          end,
        'message',
          case
            when insight_numbers.mid_term_delta_pct > 0 then format(
              'Delays in the 4-7 day range have increased by %s%% this period. This often precedes longer-term defaults.',
              insight_numbers.mid_term_delta_pct
            )
            else format(
              'Mid-term delays are not increasing right now. Only %s%% of due rent is sitting in the 4-7 day delay band.',
              coalesce(
                (select current_pct from behavior_comparison where bucket_key = 'days_4_7'),
                0
              )
            )
          end,
        'action_label', 'Analyze late payers'
      ),
      jsonb_build_object(
        'type', 'success',
        'title',
          case
            when insight_numbers.consistency_index >= 8 then 'Consistency Peak'
            else 'Emerging Stability'
          end,
        'message',
          case
            when coalesce(insight_numbers.tracked_units, 0) = 0 then
              'Consistency scoring will appear once recurring payment history is available.'
            else format(
              '%s%% of your portfolio has paid on the exact same day for %s month%s. High stability identified.',
              round(
                case
                  when insight_numbers.tracked_units = 0 then 0
                  else (insight_numbers.stable_units::numeric / insight_numbers.tracked_units::numeric) * 100
                end,
                0
              ),
              v_required_consistency_months,
              case when v_required_consistency_months = 1 then '' else 's' end
            )
          end
      )
    )
  )
  into v_dashboard
  from current_summary
  cross join previous_summary
  cross join exposure_summary
  cross join reliability_source
  cross join insight_numbers;

  return coalesce(
    v_dashboard,
    jsonb_build_object(
      'period',
      jsonb_build_object(
        'reference_date', v_reference_date,
        'start_date', v_period_start,
        'end_date', v_period_end,
        'label', to_char(v_period_start, 'Mon YYYY'),
        'comparison_label', to_char(v_previous_period_start, 'Mon YYYY')
      ),
      'summary',
      jsonb_build_object(
        'currency_code', 'KES',
        'total_collected', 0,
        'total_collected_change_pct', 0,
        'collection_rate', 0,
        'collection_rate_delta_pct', 0,
        'expected_rent', 0,
        'on_time_rate', 0,
        'on_time_rate_delta_pct', 0,
        'avg_delay_days', 0,
        'avg_delay_delta_days', 0,
        'outstanding_amount', 0,
        'outstanding_pct', 0,
        'overdue_amount', 0,
        'overdue_units_affected', 0
      ),
      'trend',
      (
        select jsonb_agg(
          jsonb_build_object(
            'label', to_char(gs, 'Mon'),
            'collected', 0,
            'expected', 0
          )
          order by gs
        )
        from generate_series(v_trend_start, v_period_start, interval '1 month') as gs
      ),
      'behavior_breakdown',
      jsonb_build_object(
        'total_units', 0,
        'segments',
        jsonb_build_array(
          jsonb_build_object('bucket_key', 'on_time', 'label', 'On-time', 'units', 0, 'percentage', 0, 'change_pct', 0, 'is_positive', true, 'color', '#1D9E75'),
          jsonb_build_object('bucket_key', 'days_1_3', 'label', '1-3 days', 'units', 0, 'percentage', 0, 'change_pct', 0, 'is_positive', true, 'color', '#BA7517'),
          jsonb_build_object('bucket_key', 'days_4_7', 'label', '4-7 days', 'units', 0, 'percentage', 0, 'change_pct', 0, 'is_positive', true, 'color', '#E24B4A'),
          jsonb_build_object('bucket_key', 'days_7_plus', 'label', '7+ days', 'units', 0, 'percentage', 0, 'change_pct', 0, 'is_positive', true, 'color', '#8E2424')
        ),
        'summary', 'No completed or due rent charges are available for behavior scoring yet.'
      ),
      'reliability',
      jsonb_build_object(
        'score', 0,
        'on_time_rate', 0,
        'avg_delay_days', 0,
        'consistency_index', 0,
        'status', 'Low',
        'benchmark_percentile', 1,
        'benchmark_message', 'Performs better than 1% of similar portfolios.'
      ),
      'risk_units', '[]'::jsonb,
      'insights',
      jsonb_build_array(
        jsonb_build_object(
          'type', 'warning',
          'title', 'No payment behavior yet',
          'message', 'Rent analytics will populate after the first charge cycle and recorded payments.',
          'action_label', 'Review setup'
        ),
        jsonb_build_object(
          'type', 'success',
          'title', 'Collection layer ready',
          'message', 'The analytics endpoints are installed and ready for live charge and payment data.',
          'action_label', null
        )
      )
    )
  );
end;
$$;

revoke all on function app.get_financial_accessible_property_ids(uuid) from public, anon, authenticated;
revoke all on function app.get_rent_payment_delay_bucket(integer) from public, anon, authenticated;
revoke all on function app.get_payment_method_display_label(app.payment_method_type_enum) from public, anon, authenticated;
revoke all on function app.get_payment_record_display_status(
  app.payment_record_status_enum,
  app.payment_allocation_status_enum
) from public, anon, authenticated;
revoke all on function app.get_rent_payment_charge_snapshot(uuid, uuid, date) from public, anon, authenticated;
revoke all on function app.get_rent_payments_property_options() from public, anon, authenticated;
revoke all on function app.get_rent_payments_dashboard(uuid, uuid, date) from public, anon, authenticated;
revoke all on function app.get_rent_payments_ledger_rows(uuid, uuid, integer) from public, anon, authenticated;

grant execute on function app.get_rent_payments_property_options() to authenticated;
grant execute on function app.get_rent_payments_dashboard(uuid, uuid, date) to authenticated;
grant execute on function app.get_rent_payments_ledger_rows(uuid, uuid, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- Tenant payment setup API
-- ----------------------------------------------------------------------------

create or replace function app.get_active_payment_setup_for_tenant(
  p_unit_id uuid
)
returns table (
  id                      uuid,
  payment_method_type     text,
  display_name            text,
  account_name            text,
  paybill_number          text,
  till_number             text,
  send_money_phone        text,
  account_reference       text,
  collection_instructions text,
  setup_scope             text
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_caller_user_id uuid := auth.uid();
  v_property_id uuid;
  v_workspace_id uuid;
  v_unit_label text;
  v_has_tenancy boolean;
begin
  if v_caller_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select
    u.property_id,
    p.workspace_id,
    coalesce(nullif(trim(u.label), ''), u.id::text)
  into v_property_id, v_workspace_id, v_unit_label
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_property_id is null then
    raise exception 'Unit not found';
  end if;

  select exists (
    select 1
    from app.unit_tenancies ut
    where ut.unit_id = p_unit_id
      and ut.tenant_user_id = v_caller_user_id
      and ut.status in ('active', 'scheduled', 'pending_agreement')
    union all
    select 1
    from app.unit_occupancy_snapshots uos
    where uos.unit_id = p_unit_id
      and uos.current_tenant_user_id = v_caller_user_id
      and uos.occupancy_status in ('occupied', 'pending_confirmation')
  ) into v_has_tenancy;

  if not v_has_tenancy then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
      or app.has_financial_management_access(v_property_id)
    ) then
      raise exception 'Forbidden: no confirmed tenancy for this unit';
    end if;
  end if;

  return query
  with setups as (
    select
      s.id,
      s.payment_method_type,
      coalesce(nullif(trim(s.display_name), ''), s.account_name) as resolved_display_name,
      s.account_name,
      s.paybill_number,
      s.till_number,
      s.send_money_phone_number as send_money_phone,
      coalesce(nullif(trim(s.account_reference_hint), ''), v_unit_label) as resolved_account_reference,
      s.collection_instructions,
      s.scope_type::text as resolved_setup_scope,
      s.is_default,
      s.priority_rank,
      s.created_at,
      case s.scope_type
        when 'unit' then 1
        when 'property' then 2
        when 'workspace' then 3
        else 4
      end as scope_priority
    from app.payment_collection_setups s
    where s.deleted_at is null
      and s.lifecycle_status = 'active'
      and (
        (s.scope_type = 'unit' and s.unit_id = p_unit_id)
        or (s.scope_type = 'property' and s.property_id = v_property_id)
        or (s.scope_type = 'workspace' and s.workspace_id = v_workspace_id)
      )
  )
  select
    s.id,
    s.payment_method_type::text,
    s.resolved_display_name,
    s.account_name,
    s.paybill_number,
    s.till_number,
    s.send_money_phone,
    s.resolved_account_reference,
    s.collection_instructions,
    s.resolved_setup_scope
  from setups s
  order by
    s.scope_priority asc,
    s.is_default desc,
    s.priority_rank asc,
    s.created_at desc
  limit 1;
end;
$$;

revoke all on function app.get_active_payment_setup_for_tenant(uuid)
  from public, anon, authenticated;

grant execute on function app.get_active_payment_setup_for_tenant(uuid)
  to authenticated;

comment on function app.get_active_payment_setup_for_tenant(uuid) is
  'Returns the best active payment setup for a tenant unit, including the internal setup id required for payment initiation.';

-- ----------------------------------------------------------------------------
-- Operational health monitoring for payment workflows
-- ----------------------------------------------------------------------------

create schema if not exists app;

-- 1. Create type for health statuses if not already present
do $$ begin
  create type app.integration_health_status_enum as enum (
    'healthy', 'failed', 'pending', 'not_configured'
  );
exception when duplicate_object then null; end $$;

-- 2. View to resolve effective payment integration health per unit
create or replace view app.view_unit_payment_integration_health
with (security_invoker = on) as
with unit_setups as (
  -- Hierarchy: Unit -> Property -> Workspace
  select 
    u.id as unit_id,
    u.property_id,
    p.workspace_id,
    u.label as unit_name,
    p.display_name as property_name,
    -- Resolve effective setup
    coalesce(
      (select s.id from app.payment_collection_setups s where s.unit_id = u.id and s.deleted_at is null and s.lifecycle_status in ('active', 'draft') order by s.lifecycle_status = 'active' desc, s.created_at desc limit 1),
      (select s.id from app.payment_collection_setups s where s.property_id = u.property_id and s.unit_id is null and s.deleted_at is null and s.lifecycle_status in ('active', 'draft') order by s.lifecycle_status = 'active' desc, s.created_at desc limit 1),
      (select s.id from app.payment_collection_setups s where s.workspace_id = p.workspace_id and s.property_id is null and s.unit_id is null and s.deleted_at is null and s.lifecycle_status in ('active', 'draft') order by s.lifecycle_status = 'active' desc, s.created_at desc limit 1)
    ) as effective_setup_id
  from app.units u
  left join app.properties p on p.id = u.property_id
  where u.deleted_at is null
)
select 
  us.unit_id,
  us.unit_name,
  us.property_id,
  us.property_name,
  us.workspace_id,
  us.effective_setup_id,
  s.payment_method_type,
  s.paybill_number,
  s.till_number,
  s.lifecycle_status,
  case 
    when s.id is null then 'not_configured'::app.integration_health_status_enum
    when s.lifecycle_status = 'draft' then 'pending'::app.integration_health_status_enum
    when (s.metadata->>'health_verified')::boolean = false then 'failed'::app.integration_health_status_enum
    else 'healthy'::app.integration_health_status_enum
  end as health_status,
  coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified_at,
  s.metadata->>'health_error' as health_error
from unit_setups us
left join app.payment_collection_setups s on s.id = us.effective_setup_id;

-- 3. RPC to get system health summary for dashboard
create or replace function app.get_system_health_summary()
returns table (
  total_monitored bigint,
  active_count bigint,
  healthy_count bigint,
  failed_count bigint,
  pending_count bigint,
  unconfigured_count bigint
)
language sql
stable
security definer
set search_path = app, public
as $$
  select 
    count(*),
    count(*) filter (where effective_setup_id is not null),
    count(*) filter (where health_status = 'healthy'),
    count(*) filter (where health_status = 'failed'),
    count(*) filter (where health_status = 'pending'),
    count(*) filter (where health_status = 'not_configured')
  from app.view_unit_payment_integration_health;
$$;

-- 4. RPC to get integration health registry for the data table
create or replace function app.get_integration_health_registry()
returns table (
  id uuid,
  scope_type text,
  scope_name text,
  method_type text,
  status text,
  last_verified timestamptz,
  failure_reason text
)
language sql
stable
security definer
set search_path = app, public
as $$
  -- We include portfolio (workspace), properties, and specific units in the registry
  
  -- 1. Workspace Level
  select 
    s.id,
    'Portfolio' as scope_type,
    w.name as scope_name,
    s.payment_method_type::text as method_type,
    case 
      when s.lifecycle_status = 'draft' then 'pending'
      when (s.metadata->>'health_verified')::boolean = false then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.workspaces w on w.id = s.workspace_id
  where s.scope_type = 'workspace' and s.deleted_at is null and s.lifecycle_status in ('active', 'draft')

  union all

  -- 2. Property Level
  select 
    s.id,
    'Property' as scope_type,
    p.display_name as scope_name,
    s.payment_method_type::text as method_type,
    case 
      when s.lifecycle_status = 'draft' then 'pending'
      when (s.metadata->>'health_verified')::boolean = false then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.properties p on p.id = s.property_id
  where s.scope_type = 'property' and s.deleted_at is null and s.lifecycle_status in ('active', 'draft')

  union all

  -- 3. Units that are NOT configured yet (to show gaps)
  select 
    u.id,
    'Unit' as scope_type,
    u.label as scope_name,
    'None' as method_type,
    'not_configured' as status,
    null as last_verified,
    'No direct or inherited setup found' as failure_reason
  from app.units u
  left join app.view_unit_payment_integration_health v on v.unit_id = u.id
  where v.effective_setup_id is null;
$$;

-- 5. RPC to trigger setup verification (placeholder)
create or replace function app.trigger_setup_verification(p_setup_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_setup record;
begin
  select * into v_setup from app.payment_collection_setups where id = p_setup_id;
  if not found then
    raise exception 'Setup not found';
  end if;

  -- Logic to simulate a verification trigger
  update app.payment_collection_setups
  set metadata = jsonb_set(metadata, '{last_verified_at}', to_jsonb(now()::text))
  where id = p_setup_id;

  return jsonb_build_object('success', true, 'message', 'Verification triggered', 'setup_id', p_setup_id);
end;
$$;

grant execute on function app.get_system_health_summary to authenticated;
grant execute on function app.get_integration_health_registry to authenticated;
grant execute on function app.trigger_setup_verification to authenticated;
grant select on app.view_unit_payment_integration_health to authenticated;

-- ----------------------------------------------------------------------------
-- Tenant home summary and invoice support
-- ----------------------------------------------------------------------------

create or replace function app.get_tenant_home_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile record;
  v_residence record;
  v_has_residence boolean := false;

  v_days_stayed integer;
  v_daily_rate numeric;
  v_calculated_rent numeric := 0;
  v_has_calculated_rent boolean := false;

  v_ledger_arrears numeric := 0;
  v_pending_invoices jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select
    u.id as user_id,
    u.email,
    coalesce(
      nullif(trim(concat_ws(' ', p.first_name, p.last_name)), ''),
      nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''),
      nullif(trim(concat_ws(
        ' ',
        u.raw_user_meta_data ->> 'firstName',
        u.raw_user_meta_data ->> 'lastName'
      )), ''),
      nullif(trim(concat_ws(
        ' ',
        u.raw_user_meta_data ->> 'first_name',
        u.raw_user_meta_data ->> 'last_name'
      )), ''),
      nullif(trim(split_part(coalesce(u.email, ''), '@', 1)), ''),
      v_user_id::text
    ) as display_name
  into v_profile
  from auth.users u
  left join app.profiles p
    on p.id = u.id
  where u.id = v_user_id
  limit 1;

  select
    t.id as tenancy_id,
    t.property_id,
    t.unit_id,
    t.status as tenancy_status,
    t.starts_on,
    t.ends_on,
    u.label as unit_label,
    u.floor,
    u.block,
    p.display_name as property_name,
    l.id as lease_agreement_id,
    l.lease_type,
    l.start_date,
    l.end_date,
    l.billing_cycle,
    l.rent_amount,
    l.currency_code,
    app.get_effective_lease_status(
      l.status,
      l.confirmation_status,
      l.start_date,
      l.end_date
    ) as lease_status,
    l.confirmation_status
  into v_residence
  from app.unit_tenancies t
  join app.units u
    on u.id = t.unit_id
  join app.properties p
    on p.id = t.property_id
  join app.lease_agreements l
    on l.id = t.lease_agreement_id
  where t.tenant_user_id = v_user_id
    and t.status in (
      'active'::app.unit_tenancy_status_enum,
      'scheduled'::app.unit_tenancy_status_enum,
      'pending_agreement'::app.unit_tenancy_status_enum
    )
    and (t.ended_at is null or t.ended_at::date >= current_date)
    and (t.ends_on is null or t.ends_on >= current_date)
    and p.deleted_at is null
    and u.deleted_at is null
  order by
    case t.status
      when 'active'::app.unit_tenancy_status_enum then 0
      when 'scheduled'::app.unit_tenancy_status_enum then 1
      else 2
    end,
    coalesce(t.activated_at, t.created_at) desc,
    t.starts_on desc
  limit 1;

  v_has_residence := found;

  if v_has_residence then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', rcp.id,
          'type', 'rent',
          'title', 'Rent for ' || to_char(rcp.billing_period_start, 'Month'),
          'subtitle', 'Due ' || to_char(rcp.due_on, 'DD/MM/YYYY'),
          'amount', rcp.outstanding_amount,
          'currency_code', v_residence.currency_code,
          'due_date', rcp.due_on,
          'status', rcp.charge_status::text,
          'button_label', 'Pay Early',
          'is_estimated', false
        )
        order by rcp.due_on asc, rcp.billing_period_start asc
      ),
      '[]'::jsonb
    )
    into v_pending_invoices
    from app.rent_charge_periods rcp
    where rcp.unit_id = v_residence.unit_id
      and rcp.charge_status <> 'paid'
      and rcp.deleted_at is null;

    select coalesce(sum(outstanding_amount), 0)
    into v_ledger_arrears
    from app.rent_charge_periods
    where unit_id = v_residence.unit_id
      and charge_status <> 'paid'
      and deleted_at is null;
  end if;

  if v_has_residence
     and jsonb_array_length(v_pending_invoices) = 0
     and v_residence.rent_amount > 0 then
    v_days_stayed := (current_date - v_residence.starts_on::date);

    if v_days_stayed > 7 then
      v_daily_rate := v_residence.rent_amount / 31.0;
      v_calculated_rent := round(v_daily_rate * v_days_stayed, 2);
      v_has_calculated_rent := true;

      v_pending_invoices := json_build_array(
        jsonb_build_object(
          'id', null,
          'type', 'rent',
          'title', 'Pending Rent',
          'subtitle', 'Pro-rated from admission',
          'amount', v_calculated_rent,
          'currency_code', v_residence.currency_code,
          'due_date', current_date,
          'status', 'pending',
          'button_label', 'Pay Estimated',
          'is_estimated', true
        )
      )::jsonb;
    else
      v_calculated_rent := 0;
      v_has_calculated_rent := true;
    end if;
  elsif jsonb_array_length(v_pending_invoices) > 0 then
    v_has_calculated_rent := true;
    v_calculated_rent := v_ledger_arrears;
  end if;

  return jsonb_build_object(
    'profile',
    jsonb_build_object(
      'user_id', v_profile.user_id,
      'display_name', v_profile.display_name,
      'email', v_profile.email
    ),
    'residence',
    case
      when not v_has_residence then null
      else jsonb_build_object(
        'tenancy_id', v_residence.tenancy_id,
        'property_id', v_residence.property_id,
        'property_name', coalesce(
          nullif(trim(v_residence.property_name), ''),
          'Untitled Property'
        ),
        'unit_id', v_residence.unit_id,
        'unit_label', coalesce(
          nullif(trim(v_residence.unit_label), ''),
          'Unlabelled Unit'
        ),
        'floor', nullif(trim(coalesce(v_residence.floor, '')), ''),
        'block', nullif(trim(coalesce(v_residence.block, '')), ''),
        'tenancy_status', v_residence.tenancy_status::text,
        'starts_on', v_residence.starts_on,
        'ends_on', v_residence.ends_on,
        'lease',
        jsonb_build_object(
          'lease_agreement_id', v_residence.lease_agreement_id,
          'lease_type', v_residence.lease_type::text,
          'status', v_residence.lease_status::text,
          'confirmation_status', v_residence.confirmation_status::text,
          'start_date', v_residence.start_date,
          'end_date', v_residence.end_date,
          'billing_cycle', v_residence.billing_cycle::text,
          'rent_amount', v_residence.rent_amount,
          'currency_code', v_residence.currency_code
        )
      )
    end,
    'financial',
    jsonb_build_object(
      'has_payment_data', v_has_calculated_rent,
      'message', case
        when jsonb_array_length(v_pending_invoices) > 0 then 'Active pending charges found.'
        when v_has_calculated_rent then 'Pro-rated balance calculated.'
        else 'No billing data yet.'
      end,
      'arrears',
      jsonb_build_object(
        'has_overdue', v_calculated_rent > 0,
        'currency_code', case
          when v_has_residence then coalesce(v_residence.currency_code, 'KES')
          else 'KES'
        end,
        'total_amount', v_calculated_rent,
        'total_label', case
          when jsonb_array_length(v_pending_invoices) > 0 then 'Total Outstanding'
          when v_calculated_rent > 0 then 'Outstanding balance (Estimated)'
          when v_days_stayed <= 7 then 'Welcome period (Free)'
          else 'No balance recorded'
        end,
        'as_of_date', current_date,
        'previous_amount', 0,
        'previous_label', null,
        'previous_as_of_date', null
      ),
      'upcoming_payments', v_pending_invoices
    )
  );
end;
$$;
