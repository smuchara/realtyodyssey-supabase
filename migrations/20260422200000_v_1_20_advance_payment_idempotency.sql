-- ============================================================================
-- V 1 20: Advance Payment Idempotency Controls
-- ============================================================================
-- Purpose
--   - Prevent duplicate payments for already-covered rent periods.
--   - Enforce a re-payment lock window when rent is pre-paid into the future.
--   - Expose an eligibility RPC callable by both tenant apps and edge functions.
--   - Add a DB-level unique constraint so concurrent STK submissions for the
--     same unit cannot both proceed past the pending state simultaneously.
-- ============================================================================

create schema if not exists app;

-- ---------------------------------------------------------------------------
-- 1. Index: fast coverage lookups per unit
-- ---------------------------------------------------------------------------

create index if not exists idx_rent_charge_periods_unit_coverage
  on app.rent_charge_periods(unit_id, billing_period_start, charge_status)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 2. Unique constraint: at most one pending STK request per unit at a time.
--    This is the DB-level safety net that prevents a race condition where two
--    concurrent requests both pass the eligibility check before either insert.
-- ---------------------------------------------------------------------------

create unique index if not exists uq_mpesa_stk_requests_unit_pending
  on app.mpesa_stk_requests(unit_id)
  where status = 'pending'::app.mpesa_stk_status_enum
    and unit_id is not null;

-- ---------------------------------------------------------------------------
-- 3. get_tenant_advance_payment_eligibility
--    Returns a JSONB eligibility decision for a unit + requested month count.
--
--    Parameters
--      p_unit_id          – Unit to check.
--      p_requested_months – How many months the caller wants to pay (1–3).
--      p_user_id          – Caller identity when invoked from service_role
--                           (edge functions). Falls back to auth.uid() when
--                           called directly from an authenticated session.
--
--    Returns (always a JSONB object – never raises for normal business cases)
--      is_eligible         bool   – true when payment may proceed.
--      reason_code         text   – machine-readable gate reason.
--      reason              text   – human-readable message for the UI.
--      lock_until_date     date   – when the advance lock lifts (null if eligible).
--      eligible_from_month date   – billing_period_start of next payable period.
--      eligible_from_amount numeric – outstanding_amount of that period.
--      covered_until_month date   – last already-paid future month (null if none).
--      months_available    int    – how many unpaid months are available right now.
--      available_periods   jsonb  – array of payable period objects.
--
--    Reason codes
--      eligible             – Payment may proceed.
--      payment_in_progress  – A pending STK exists within the last 10 minutes.
--      advance_lock         – Future months are pre-paid; lock window is active.
--      all_periods_covered  – All upcoming charge periods are fully paid.
--      no_charge_periods    – No upcoming rent charges have been generated yet.
-- ---------------------------------------------------------------------------

create or replace function app.get_tenant_advance_payment_eligibility(
  p_unit_id          uuid,
  p_requested_months integer default 1,
  p_user_id          uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_caller_id            uuid    := coalesce(p_user_id, auth.uid());
  v_unit                 record;
  v_has_access           boolean := false;
  v_today                date    := current_date;
  v_current_month_start  date    := date_trunc('month', current_date)::date;
  v_max_advance_months   integer := 3;
  v_requested_months_safe integer;

  v_last_future_covered  record;
  v_last_future_month    date;
  v_lock_until           date;

  v_pending_stk_id       uuid;
  v_pending_stk_amount   numeric;

  v_available_periods    jsonb;
  v_next_month           date;
  v_next_amount          numeric;
begin
  if v_caller_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_unit_id is null then
    raise exception 'p_unit_id is required';
  end if;

  -- Resolve unit + workspace/property for access checks
  select
    u.id,
    u.label,
    u.property_id,
    p.workspace_id
  into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.id is null then
    raise exception 'Unit not found';
  end if;

  -- Access check: active tenant of this unit, or owner/admin/financial manager
  select exists (
    select 1
    from app.unit_tenancies ut
    where ut.unit_id    = p_unit_id
      and ut.tenant_user_id = v_caller_id
      and ut.status in (
        'active'::app.unit_tenancy_status_enum,
        'scheduled'::app.unit_tenancy_status_enum,
        'pending_agreement'::app.unit_tenancy_status_enum
      )
    union all
    select 1
    from app.unit_occupancy_snapshots uos
    where uos.unit_id              = p_unit_id
      and uos.current_tenant_user_id = v_caller_id
      and uos.occupancy_status in ('occupied', 'pending_confirmation')
  ) into v_has_access;

  if not v_has_access then
    if not (
      app.is_workspace_owner(v_unit.workspace_id)
      or app.is_workspace_admin(v_unit.workspace_id)
      or app.has_financial_management_access(v_unit.property_id)
    ) then
      raise exception 'Forbidden';
    end if;
  end if;

  v_requested_months_safe :=
    greatest(1, least(coalesce(p_requested_months, 1), v_max_advance_months));

  -- -----------------------------------------------------------------------
  -- Gate 1: pending STK in the last 10 minutes
  -- -----------------------------------------------------------------------
  select stk.id, stk.amount
    into v_pending_stk_id, v_pending_stk_amount
  from app.mpesa_stk_requests stk
  where stk.unit_id = p_unit_id
    and stk.status  = 'pending'::app.mpesa_stk_status_enum
    and stk.created_at > now() - interval '10 minutes'
  order by stk.created_at desc
  limit 1;

  if v_pending_stk_id is not null then
    return jsonb_build_object(
      'is_eligible',         false,
      'reason_code',         'payment_in_progress',
      'reason',              format(
        'A payment of KES %s is already being processed. Please wait for it to complete.',
        trim(to_char(v_pending_stk_amount, 'FM999,999,999,990D00'))
      ),
      'lock_until_date',     null,
      'eligible_from_month', null,
      'eligible_from_amount', null,
      'covered_until_month', null,
      'months_available',    0,
      'available_periods',   '[]'::jsonb
    );
  end if;

  -- -----------------------------------------------------------------------
  -- Gate 2: advance lock window
  --    If any FUTURE billing period (start > current month) is already paid,
  --    block further payments until 7 days before that period's due date.
  -- -----------------------------------------------------------------------
  select
    rc.id,
    rc.billing_period_start,
    rc.billing_period_end,
    rc.due_on
  into v_last_future_covered
  from app.rent_charge_periods rc
  where rc.unit_id      = p_unit_id
    and rc.deleted_at   is null
    and rc.charge_status = 'paid'::app.rent_charge_status_enum
    and date_trunc('month', rc.billing_period_start)::date > v_current_month_start
  order by rc.billing_period_start desc
  limit 1;

  if v_last_future_covered.id is not null then
    v_last_future_month := date_trunc('month', v_last_future_covered.billing_period_start)::date;
    v_lock_until        := (v_last_future_covered.due_on - interval '7 days')::date;

    if v_today < v_lock_until then
      return jsonb_build_object(
        'is_eligible',         false,
        'reason_code',         'advance_lock',
        'reason',              format(
          'You have already paid ahead to %s. Your next payment window opens on %s.',
          to_char(v_last_future_month, 'Mon YYYY'),
          to_char(v_lock_until, 'DD Mon YYYY')
        ),
        'lock_until_date',     v_lock_until,
        'eligible_from_month', null,
        'eligible_from_amount', null,
        'covered_until_month', v_last_future_month,
        'months_available',    0,
        'available_periods',   '[]'::jsonb
      );
    end if;
  end if;

  -- -----------------------------------------------------------------------
  -- Build list of available (unpaid) periods starting from current month
  -- -----------------------------------------------------------------------
  select jsonb_agg(
    jsonb_build_object(
      'rent_charge_period_id', rc.id,
      'month_start',           rc.billing_period_start,
      'month_end',             rc.billing_period_end,
      'month_label',           to_char(rc.billing_period_start, 'Mon YYYY'),
      'due_on',                rc.due_on,
      'scheduled_amount',      rc.scheduled_amount,
      'outstanding_amount',    rc.outstanding_amount,
      'charge_status',         rc.charge_status::text,
      'is_current_month',
        date_trunc('month', rc.billing_period_start)::date = v_current_month_start
    )
    order by rc.billing_period_start asc
  )
  into v_available_periods
  from (
    select *
    from app.rent_charge_periods rc
    where rc.unit_id = p_unit_id
      and rc.deleted_at is null
      and rc.charge_status not in (
        'paid'::app.rent_charge_status_enum,
        'cancelled'::app.rent_charge_status_enum
      )
      and date_trunc('month', rc.billing_period_start)::date >= v_current_month_start
    order by rc.billing_period_start asc
    limit v_requested_months_safe
  ) rc;

  -- -----------------------------------------------------------------------
  -- Gate 3: no payable periods found
  -- -----------------------------------------------------------------------
  if v_available_periods is null or jsonb_array_length(v_available_periods) = 0 then
    if v_last_future_covered.id is not null then
      return jsonb_build_object(
        'is_eligible',         false,
        'reason_code',         'all_periods_covered',
        'reason',              format(
          'All upcoming rent periods are already paid through %s.',
          to_char(v_last_future_month, 'Mon YYYY')
        ),
        'lock_until_date',     null,
        'eligible_from_month', null,
        'eligible_from_amount', null,
        'covered_until_month', v_last_future_month,
        'months_available',    0,
        'available_periods',   '[]'::jsonb
      );
    else
      return jsonb_build_object(
        'is_eligible',         false,
        'reason_code',         'no_charge_periods',
        'reason',              'No upcoming rent charges have been generated yet. Contact your property manager.',
        'lock_until_date',     null,
        'eligible_from_month', null,
        'eligible_from_amount', null,
        'covered_until_month', null,
        'months_available',    0,
        'available_periods',   '[]'::jsonb
      );
    end if;
  end if;

  -- All gates passed – return eligible response
  v_next_month  := (v_available_periods -> 0 ->> 'month_start')::date;
  v_next_amount := (v_available_periods -> 0 ->> 'outstanding_amount')::numeric;

  return jsonb_build_object(
    'is_eligible',         true,
    'reason_code',         'eligible',
    'reason',              case
      when v_last_future_covered.id is not null then
        format('Continuing from %s.', to_char(v_next_month, 'Mon YYYY'))
      else
        format('Rent for %s is ready to pay.', to_char(v_next_month, 'Mon YYYY'))
    end,
    'lock_until_date',     null,
    'eligible_from_month', v_next_month,
    'eligible_from_amount', v_next_amount,
    'covered_until_month', case
      when v_last_future_covered.id is not null then v_last_future_month
      else null
    end,
    'months_available',    jsonb_array_length(v_available_periods),
    'available_periods',   v_available_periods
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. validate_advance_payment_periods
--    Hard guard called during payment record creation to prevent allocation
--    of a payment to a period that is already fully paid.
--    Raises if any of the requested period IDs is already at charge_status='paid'.
-- ---------------------------------------------------------------------------

create or replace function app.validate_advance_payment_periods(
  p_unit_id                uuid,
  p_rent_charge_period_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_duplicate_period record;
begin
  if p_unit_id is null or p_rent_charge_period_ids is null
      or array_length(p_rent_charge_period_ids, 1) = 0 then
    return;
  end if;

  select
    rc.id,
    to_char(rc.billing_period_start, 'Mon YYYY') as period_label
  into v_duplicate_period
  from app.rent_charge_periods rc
  where rc.id = any(p_rent_charge_period_ids)
    and rc.unit_id = p_unit_id
    and rc.deleted_at is null
    and rc.charge_status = 'paid'::app.rent_charge_status_enum
  limit 1;

  if v_duplicate_period.id is not null then
    raise exception
      'Period % is already fully paid. Duplicate payment rejected.',
      v_duplicate_period.period_label
      using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------

revoke all on function app.get_tenant_advance_payment_eligibility(uuid, integer, uuid)
  from public, anon;

revoke all on function app.validate_advance_payment_periods(uuid, uuid[])
  from public, anon;

grant execute on function app.get_tenant_advance_payment_eligibility(uuid, integer, uuid)
  to authenticated, service_role;

grant execute on function app.validate_advance_payment_periods(uuid, uuid[])
  to service_role;

-- ---------------------------------------------------------------------------
-- Audit action types for idempotency events
-- ---------------------------------------------------------------------------

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('PAYMENT_BLOCKED_DUPLICATE',  'Payment Blocked – Duplicate Period',    210),
  ('PAYMENT_BLOCKED_LOCK_WINDOW', 'Payment Blocked – Advance Lock Window', 211)
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order;
