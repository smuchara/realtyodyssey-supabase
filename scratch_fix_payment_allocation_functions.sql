-- Standalone patch: fixes two trigger functions that both called max()/min()
-- on a uuid column (an aggregate Postgres doesn't have for uuid). Run this
-- once against your database before running seed.sql, if you're seeding by
-- pasting seed.sql directly into a SQL editor rather than via
-- `supabase db reset` (which would pick this up automatically from the
-- migration file once re-applied).
--
-- Source: supabase/migrations/20260409102000_v_1_09_revenue_payments_core.sql

set search_path = app, public, extensions;

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
    case when count(distinct rc.unit_id) = 1 then max(rc.unit_id::text)::uuid else null end,
    case when count(distinct rc.lease_agreement_id) = 1 then max(rc.lease_agreement_id::text)::uuid else null end
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

  select max(rc.unit_id::text)::uuid
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
