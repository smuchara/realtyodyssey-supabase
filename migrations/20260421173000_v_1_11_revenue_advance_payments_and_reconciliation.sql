-- ============================================================================
-- V 1 11: Revenue Dashboards, Advance Payments, and Reconciliation
-- ============================================================================
-- Purpose
--   - Apply final rent dashboard and ledger refinements.
--   - Support advance rent payment allocation, M-Pesa STK reconciliation, and idempotency guarantees.
--   - Expose final tenant home-summary eligibility and payment integration health registry behavior.
--
-- Consolidated before first production publication. Related patch migrations
-- are folded into this canonical domain migration for easier maintenance.
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Rent dashboard refinements
-- ----------------------------------------------------------------------------

create schema if not exists app;

create or replace function app.get_payment_record_verification_source(
  p_record_source app.payment_record_source_enum
)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case p_record_source
    when 'mobile_money_import'::app.payment_record_source_enum then 'M-Pesa callback'
    when 'bank_statement_import'::app.payment_record_source_enum then 'Bank statement import'
    when 'tenant_submission'::app.payment_record_source_enum then 'Tenant submission'
    when 'backfill_import'::app.payment_record_source_enum then 'Historical import'
    else 'Manual entry'
  end;
$$;

drop function if exists app.get_rent_payments_ledger_rows(uuid, integer);
drop function if exists app.get_rent_payments_ledger_rows(uuid, uuid, integer);

create function app.get_rent_payments_ledger_rows(
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
  applied_amount numeric,
  unapplied_amount numeric,
  currency_code text,
  method_label text,
  status_key text,
  status_label text,
  status_variant text,
  delay_days integer,
  delay_label text,
  coverage_period_label text,
  coverage_period_count integer,
  allocation_type text,
  verification_source text,
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
      round(coalesce(sum(pa.allocated_amount), 0), 2) as applied_amount,
      count(distinct date_trunc('month', rc.billing_period_start)::date)::int as coverage_period_count,
      min(date_trunc('month', rc.billing_period_start)::date) as first_period_start,
      max(date_trunc('month', rc.billing_period_start)::date) as last_period_start,
      bool_or(
        date_trunc('month', rc.billing_period_start)::date
        > date_trunc('month', pr.paid_at)::date
      ) as has_future_coverage,
      bool_or(
        date_trunc('month', rc.billing_period_start)::date
        <= date_trunc('month', pr.paid_at)::date
      ) as has_current_or_past_coverage,
      bool_and(
        date_trunc('month', rc.billing_period_start)::date
        > date_trunc('month', pr.paid_at)::date
      ) as is_fully_future_coverage,
      max(greatest(coalesce(rc.full_collection_delay_days, 0), 0))
        filter (
          where date_trunc('month', rc.billing_period_start)::date
            <= date_trunc('month', pr.paid_at)::date
        )::int as max_delay_days
    from app.payment_allocations pa
    join app.payment_records pr
      on pr.id = pa.payment_record_id
     and pr.deleted_at is null
    join app.rent_charge_periods rc
      on rc.id = pa.rent_charge_period_id
     and rc.deleted_at is null
    where pa.deleted_at is null
    group by pa.payment_record_id
  ),
  ledger_rows as (
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
      round(coalesce(ar.applied_amount, 0), 2) as applied_amount,
      round(greatest(pr.amount - coalesce(ar.applied_amount, 0), 0), 2) as unapplied_amount,
      coalesce(nullif(trim(pr.currency_code), ''), 'KES') as currency_code,
      app.get_payment_method_display_label(pr.payment_method_type) as method_label,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'failed'
        when coalesce(ar.applied_amount, 0) = 0 then 'unmatched'
        when coalesce(ar.applied_amount, 0) < pr.amount then 'partial'
        when coalesce(ar.is_fully_future_coverage, false) then 'advance_paid'
        else 'matched'
      end as status_key,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'Failed'
        when coalesce(ar.applied_amount, 0) = 0 then 'Unmatched'
        when coalesce(ar.applied_amount, 0) < pr.amount then 'Partial'
        when coalesce(ar.is_fully_future_coverage, false) then 'Advance Paid'
        else 'Matched'
      end as status_label,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'error'
        when coalesce(ar.applied_amount, 0) = 0 then 'warning'
        when coalesce(ar.applied_amount, 0) < pr.amount then 'info'
        else 'success'
      end as status_variant,
      case
        when coalesce(ar.is_fully_future_coverage, false) then null
        else ar.max_delay_days
      end as delay_days,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'Failed'
        when coalesce(ar.is_fully_future_coverage, false) then 'Paid early'
        when coalesce(ar.applied_amount, 0) = 0 then 'Unallocated'
        when ar.max_delay_days is null or ar.max_delay_days <= 0 then 'On-time'
        else format('%s days', ar.max_delay_days)
      end as delay_label,
      case
        when coalesce(ar.coverage_period_count, 0) = 0 then 'Unallocated'
        when ar.first_period_start = ar.last_period_start then to_char(ar.first_period_start, 'Mon YYYY')
        else format(
          '%s - %s',
          to_char(ar.first_period_start, 'Mon YYYY'),
          to_char(ar.last_period_start, 'Mon YYYY')
        )
      end as coverage_period_label,
      coalesce(ar.coverage_period_count, 0) as coverage_period_count,
      case
        when coalesce(ar.coverage_period_count, 0) = 0 then 'Unallocated cash'
        when coalesce(ar.has_future_coverage, false) and coalesce(ar.has_current_or_past_coverage, false)
          then 'Current + future rent'
        when coalesce(ar.has_future_coverage, false) then 'Covers future rent'
        else 'Current-period rent'
      end as allocation_type,
      app.get_payment_record_verification_source(pr.record_source) as verification_source,
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
    left join allocation_rollup ar
      on ar.payment_record_id = pr.id
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
  )
  select *
  from ledger_rows
  order by paid_at desc, payment_record_id desc
  limit greatest(coalesce(p_limit, 50), 1);
end;
$$;

drop function if exists app.get_rent_payments_dashboard(uuid, date);
drop function if exists app.get_rent_payments_dashboard(uuid, uuid, date);

create function app.get_rent_payments_dashboard(
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
  v_min_completed_cycles integer := 3;
  v_dashboard jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

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
  ),
  due_previous as (
    select *
    from previous_period
    where collection_deadline <= v_previous_period_end
  ),
  completed_due_current as (
    select *
    from due_current
    where is_fully_paid
  ),
  completed_due_previous as (
    select *
    from due_previous
    where is_fully_paid
  ),
  current_summary as (
    select
      coalesce(max(currency_code), 'KES') as currency_code,
      round(coalesce(sum(amount_paid), 0), 2) as total_collected,
      round(coalesce(sum(scheduled_amount), 0), 2) as expected_rent,
      round(
        least(
          100,
          case
            when coalesce(sum(scheduled_amount), 0) = 0 then 0
            else (coalesce(sum(amount_paid), 0) / nullif(sum(scheduled_amount), 0)) * 100
          end
        ),
        1
      ) as collection_rate,
      round(
        case
          when (select count(*) from due_current) = 0 then 0
          else (
            (select count(*) from due_current where is_fully_paid and positive_delay_days = 0)::numeric
            / nullif((select count(*) from due_current), 0)::numeric
          ) * 100
        end,
        1
      ) as on_time_rate,
      round(
        coalesce(
          (select avg(positive_delay_days::numeric) from completed_due_current),
          0
        ),
        1
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
      ) as outstanding_pct,
      count(*)::int as generated_charges_count,
      (select count(*)::int from due_current) as due_charges_count,
      (select count(*)::int from completed_due_current) as completed_due_charges_count
    from current_period
  ),
  previous_summary as (
    select
      round(coalesce(sum(amount_paid), 0), 2) as total_collected,
      round(
        least(
          100,
          case
            when coalesce(sum(scheduled_amount), 0) = 0 then 0
            else (coalesce(sum(amount_paid), 0) / nullif(sum(scheduled_amount), 0)) * 100
          end
        ),
        1
      ) as collection_rate,
      round(
        case
          when (select count(*) from due_previous) = 0 then 0
          else (
            (select count(*) from due_previous where is_fully_paid and positive_delay_days = 0)::numeric
            / nullif((select count(*) from due_previous), 0)::numeric
          ) * 100
        end,
        1
      ) as on_time_rate,
      round(
        coalesce(
          (select avg(positive_delay_days::numeric) from completed_due_previous),
          0
        ),
        1
      ) as avg_delay_days
    from previous_period
  ),
  exposure_summary as (
    select
      round(coalesce(sum(outstanding_amount) filter (where is_overdue and outstanding_amount > 0), 0), 2) as overdue_amount,
      count(distinct unit_id) filter (where is_overdue and outstanding_amount > 0)::int as overdue_units_affected
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
      round(coalesce(sum(b.scheduled_amount), 0), 2) as expected,
      round(coalesce(sum(b.outstanding_amount), 0), 2) as outstanding
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
      count(*)::int as completed_charge_count
    from completed_due_current
    group by delay_bucket
  ),
  behavior_previous as (
    select
      delay_bucket as bucket_key,
      count(*)::int as completed_charge_count
    from completed_due_previous
    group by delay_bucket
  ),
  behavior_totals as (
    select
      (select count(*)::int from completed_due_current) as current_total,
      (select count(*)::int from completed_due_previous) as previous_total
  ),
  behavior_comparison as (
    select
      template.bucket_key,
      template.label,
      template.sort_order,
      template.color,
      coalesce(current_bucket.completed_charge_count, 0) as current_units,
      coalesce(previous_bucket.completed_charge_count, 0) as previous_units,
      round(
        case
          when totals.current_total = 0 then 0
          else (coalesce(current_bucket.completed_charge_count, 0)::numeric / totals.current_total::numeric) * 100
        end,
        0
      ) as current_pct,
      round(
        case
          when totals.previous_total = 0 then 0
          else (coalesce(previous_bucket.completed_charge_count, 0)::numeric / totals.previous_total::numeric) * 100
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
  history_due as (
    select *
    from base
    where collection_deadline <= v_reference_date
      and billing_month between v_trend_start and v_period_start
  ),
  history_completed as (
    select *
    from history_due
    where is_fully_paid
  ),
  reliability_metrics as (
    select
      count(*)::int as total_due_invoices,
      count(*) filter (where is_fully_paid)::int as completed_due_invoices,
      count(distinct billing_month) filter (where is_fully_paid)::int as completed_due_cycles,
      count(*) filter (where is_fully_paid and positive_delay_days = 0)::int as on_time_paid_invoices,
      round(coalesce(avg(positive_delay_days::numeric) filter (where is_fully_paid), 0), 1) as avg_completed_delay_days
    from history_due
  ),
  consistency_distribution as (
    select extract(day from coalesce(last_payment_at, fully_paid_at)::date)::numeric as payment_day
    from history_completed
    where coalesce(last_payment_at, fully_paid_at) is not null
  ),
  consistency_metrics as (
    select
      count(*)::int as payment_observations,
      coalesce(stddev_samp(payment_day), 0) as payment_day_stddev
    from consistency_distribution
  ),
  reliability_source as (
    select
      rm.total_due_invoices,
      rm.completed_due_invoices,
      rm.completed_due_cycles,
      round(
        case
          when rm.total_due_invoices = 0 then 0
          else (rm.on_time_paid_invoices::numeric / rm.total_due_invoices::numeric) * 100
        end,
        1
      ) as on_time_rate,
      rm.avg_completed_delay_days as avg_delay_days,
      round(
        case
          when rm.total_due_invoices = 0 then 0
          else (rm.completed_due_invoices::numeric / rm.total_due_invoices::numeric) * 100
        end,
        1
      ) as collection_completion_rate,
      case
        when rm.avg_completed_delay_days <= 0 then 100
        when rm.avg_completed_delay_days <= 3 then 80
        when rm.avg_completed_delay_days <= 7 then 60
        when rm.avg_completed_delay_days <= 14 then 35
        else 10
      end as delay_score,
      case
        when cm.payment_observations < v_min_completed_cycles then 0
        when cm.payment_day_stddev <= 1 then 100
        when cm.payment_day_stddev <= 2 then 85
        when cm.payment_day_stddev <= 4 then 70
        when cm.payment_day_stddev <= 6 then 55
        when cm.payment_day_stddev <= 9 then 40
        else 25
      end as consistency_score,
      (
        rm.completed_due_invoices >= v_min_completed_cycles
        and rm.completed_due_cycles >= v_min_completed_cycles
      ) as is_eligible
    from reliability_metrics rm
    cross join consistency_metrics cm
  ),
  reliability_scored as (
    select
      rs.total_due_invoices,
      rs.completed_due_invoices,
      rs.completed_due_cycles,
      rs.on_time_rate,
      rs.avg_delay_days,
      rs.collection_completion_rate,
      rs.delay_score,
      rs.consistency_score,
      rs.is_eligible,
      case
        when not rs.is_eligible then null
        else round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        )::int
      end as score,
      case
        when not rs.is_eligible then 'Insufficient history'
        when round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        ) >= 85 then 'High'
        when round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        ) >= 65 then 'Moderate'
        when round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        ) >= 40 then 'Low'
        else 'Critical'
      end as status
    from reliability_source rs
  ),
  future_coverage as (
    select
      round(coalesce(sum(amount_paid), 0), 2) as total_prepaid_amount,
      count(*) filter (
        where amount_paid > 0
          and outstanding_amount <= 0
          and scheduled_amount > 0
      )::int as fully_covered_periods,
      count(*) filter (
        where amount_paid > 0
          and outstanding_amount > 0
      )::int as partially_covered_periods,
      count(distinct unit_id) filter (where amount_paid > 0)::int as units_covered
    from base
    where billing_period_start > v_period_end
  ),
  risk_rollup as (
    select
      base.property_id,
      base.property_name,
      base.unit_id,
      base.unit_label,
      max(base.tenant_name) as tenant_name,
      count(*) filter (where base.collection_deadline <= v_reference_date)::int as due_cycles,
      count(*) filter (where base.collection_deadline <= v_reference_date and base.is_overdue)::int as overdue_cycles,
      count(*) filter (
        where base.collection_deadline <= v_reference_date
          and (
            (base.is_fully_paid and base.positive_delay_days >= 4)
            or (base.outstanding_amount > 0 and base.is_overdue)
          )
      )::int as repeated_late_cycles,
      round(
        coalesce(
          avg(base.positive_delay_days::numeric) filter (
            where base.collection_deadline <= v_reference_date and base.is_fully_paid
          ),
          0
        ),
        1
      ) as avg_delay_days,
      round(
        coalesce(sum(base.outstanding_amount) filter (where base.collection_deadline <= v_reference_date), 0),
        2
      ) as unpaid_balance
    from base
    group by base.property_id, base.property_name, base.unit_id, base.unit_label
  ),
  risk_candidates as (
    select
      rollup.property_id,
      rollup.property_name,
      rollup.unit_id,
      rollup.unit_label,
      coalesce(nullif(trim(rollup.tenant_name), ''), 'Unassigned Tenant') as tenant_name,
      (
        (coalesce(rollup.overdue_cycles, 0) * 35)
        + (coalesce(rollup.repeated_late_cycles, 0) * 12)
        + (
          case
            when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
            when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
            when coalesce(rollup.avg_delay_days, 0) > 0 then 6
            else 0
          end
        )
        + (
          case
            when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
            when coalesce(rollup.unpaid_balance, 0) > 0 then 8
            else 0
          end
        )
      )::int as risk_score,
      case
        when coalesce(rollup.overdue_cycles, 0) >= 2 then 'Multiple overdue cycles'
        when coalesce(rollup.unpaid_balance, 0) > 0 and coalesce(rollup.avg_delay_days, 0) >= 7 then 'Overdue balance beyond threshold'
        when coalesce(rollup.repeated_late_cycles, 0) >= 2 then 'Repeated late payment behavior'
        when coalesce(rollup.unpaid_balance, 0) > 0 then 'Open rent balance requires follow-up'
        else 'Monitor payment behavior'
      end as pattern,
      case
        when (
          (coalesce(rollup.overdue_cycles, 0) * 35)
          + (coalesce(rollup.repeated_late_cycles, 0) * 12)
          + (
            case
              when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
              when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
              when coalesce(rollup.avg_delay_days, 0) > 0 then 6
              else 0
            end
          )
          + (
            case
              when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
              when coalesce(rollup.unpaid_balance, 0) > 0 then 8
              else 0
            end
          )
        ) >= 60 then 'High'
        when (
          (coalesce(rollup.overdue_cycles, 0) * 35)
          + (coalesce(rollup.repeated_late_cycles, 0) * 12)
          + (
            case
              when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
              when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
              when coalesce(rollup.avg_delay_days, 0) > 0 then 6
              else 0
            end
          )
          + (
            case
              when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
              when coalesce(rollup.unpaid_balance, 0) > 0 then 8
              else 0
            end
          )
        ) >= 35 then 'Medium'
        when (
          (coalesce(rollup.overdue_cycles, 0) * 35)
          + (coalesce(rollup.repeated_late_cycles, 0) * 12)
          + (
            case
              when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
              when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
              when coalesce(rollup.avg_delay_days, 0) > 0 then 6
              else 0
            end
          )
          + (
            case
              when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
              when coalesce(rollup.unpaid_balance, 0) > 0 then 8
              else 0
            end
          )
        ) >= 15 then 'Low'
        else null
      end as risk_level,
      coalesce(rollup.avg_delay_days, 0) as avg_delay_days,
      coalesce(rollup.unpaid_balance, 0) as overdue_amount
    from risk_rollup rollup
    where coalesce(rollup.due_cycles, 0) > 0
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
        round(current_summary.collection_rate - coalesce(previous_summary.collection_rate, 0), 1),
      'expected_rent', current_summary.expected_rent,
      'on_time_rate', current_summary.on_time_rate,
      'on_time_rate_delta_pct',
        round(current_summary.on_time_rate - coalesce(previous_summary.on_time_rate, 0), 1),
      'avg_delay_days', current_summary.avg_delay_days,
      'avg_delay_delta_days',
        round(current_summary.avg_delay_days - coalesce(previous_summary.avg_delay_days, 0), 1),
      'outstanding_amount', current_summary.outstanding_amount,
      'outstanding_pct', current_summary.outstanding_pct,
      'overdue_amount', exposure_summary.overdue_amount,
      'overdue_units_affected', exposure_summary.overdue_units_affected,
      'generated_charges_count', current_summary.generated_charges_count,
      'due_charges_count', current_summary.due_charges_count,
      'completed_due_charges_count', current_summary.completed_due_charges_count
    ),
    'trend',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'label', trend_rollup.label,
          'collected', trend_rollup.collected,
          'expected', trend_rollup.expected,
          'outstanding', trend_rollup.outstanding
        )
        order by trend_rollup.sort_order
      )
      from trend_rollup
    ), '[]'::jsonb),
    'behavior_breakdown',
    jsonb_build_object(
      'eligible', coalesce((select current_total from behavior_totals), 0) > 0,
      'total_completed_charges', coalesce((select current_total from behavior_totals), 0),
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
          when coalesce((select current_pct from behavior_comparison where bucket_key = 'on_time'), 0) >= 80 then
            'Completed rent charges are landing mostly on time in the selected period.'
          when coalesce((select current_pct from behavior_comparison where bucket_key = 'days_7_plus'), 0) >= 20 then
            'Long delays are showing up in completed charges. Prioritize units with repeated late completions.'
          else
            'Behavior is mixed. Watch 4-7 day and 7+ day delays before they harden into arrears.'
        end
    ),
    'reliability',
    jsonb_build_object(
      'eligible', reliability_scored.is_eligible,
      'score', reliability_scored.score,
      'on_time_rate', reliability_scored.on_time_rate,
      'avg_delay_days', reliability_scored.avg_delay_days,
      'completion_rate', reliability_scored.collection_completion_rate,
      'consistency_score', reliability_scored.consistency_score,
      'delay_score', reliability_scored.delay_score,
      'status', reliability_scored.status,
      'minimum_completed_invoices', v_min_completed_cycles,
      'completed_due_invoices', reliability_scored.completed_due_invoices,
      'completed_due_cycles', reliability_scored.completed_due_cycles,
      'summary',
        case
          when not reliability_scored.is_eligible then
            'Reliability scoring will appear once recurring rent history is available.'
          else
            'Weighted from on-time performance (40%), delay discipline (25%), completion rate (20%), and payment consistency (15%).'
        end
    ),
    'advance_summary',
    jsonb_build_object(
      'total_prepaid_amount', future_coverage.total_prepaid_amount,
      'fully_covered_periods', future_coverage.fully_covered_periods,
      'partially_covered_periods', future_coverage.partially_covered_periods,
      'units_covered', future_coverage.units_covered,
      'summary',
        case
          when future_coverage.total_prepaid_amount <= 0 then
            'Advance payment visibility will appear once future rent is allocated.'
          when future_coverage.partially_covered_periods > 0 then
            format(
              '%s future rent period%s fully covered, with %s more partially funded ahead.',
              future_coverage.fully_covered_periods,
              case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
              future_coverage.partially_covered_periods
            )
          else
            format(
              '%s future rent period%s already funded across %s unit%s.',
              future_coverage.fully_covered_periods,
              case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
              future_coverage.units_covered,
              case when future_coverage.units_covered = 1 then '' else 's' end
            )
        end
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
          'risk_score', risk_score,
          'avg_delay_days', avg_delay_days,
          'overdue_amount', overdue_amount
        )
        order by risk_score desc, overdue_amount desc, property_name, unit_label
      )
      from (
        select *
        from risk_candidates
        where risk_level in ('High', 'Medium')
        order by risk_score desc, overdue_amount desc, property_name, unit_label
        limit 8
      ) ranked_risk
    ), '[]'::jsonb),
    'insights',
    jsonb_build_array(
      jsonb_build_object(
        'type',
          case
            when current_summary.generated_charges_count = 0 then 'neutral'
            when exposure_summary.overdue_amount > 0 then 'warning'
            else 'success'
          end,
        'title',
          case
            when current_summary.generated_charges_count = 0 then 'No charges generated yet'
            when exposure_summary.overdue_amount > 0 then 'Overdue rent needs follow-up'
            else 'Current-period rent is under control'
          end,
        'message',
          case
            when current_summary.generated_charges_count = 0 then
              'No rent charges have been generated for this period yet, so collection analytics stay in a neutral state.'
            when exposure_summary.overdue_amount > 0 then format(
              '%s is already overdue across %s unit%s. Focus collection effort on balances that are past due.',
              current_summary.currency_code || ' ' || trim(to_char(exposure_summary.overdue_amount, 'FM999,999,999,990D00')),
              exposure_summary.overdue_units_affected,
              case when exposure_summary.overdue_units_affected = 1 then '' else 's' end
            )
            else 'Allocated collections are matching active generated charges without overdue pressure right now.'
          end,
        'action_label',
          case
            when current_summary.generated_charges_count = 0 then 'Review setup'
            when exposure_summary.overdue_amount > 0 then 'Review overdue units'
            else 'Inspect ledger'
          end
      ),
      jsonb_build_object(
        'type',
          case
            when not reliability_scored.is_eligible then 'neutral'
            when reliability_scored.score >= 85 then 'success'
            when reliability_scored.score >= 65 then 'info'
            else 'warning'
          end,
        'title',
          case
            when not reliability_scored.is_eligible then 'Not enough payment history yet'
            else 'Collection reliability is formula-based'
          end,
        'message',
          case
            when not reliability_scored.is_eligible then
              'Behavior insights will become available after completed and due rent cycles are recorded.'
            else format(
              'Current reliability blends %s%% on-time performance, %s%% completion, and a %s/100 consistency score into one operational signal.',
              reliability_scored.on_time_rate,
              reliability_scored.collection_completion_rate,
              reliability_scored.consistency_score
            )
          end,
        'action_label',
          case
            when not reliability_scored.is_eligible then null
            else 'View reliability model'
          end
      ),
      jsonb_build_object(
        'type',
          case
            when future_coverage.total_prepaid_amount > 0 then 'info'
            else 'neutral'
          end,
        'title',
          case
            when future_coverage.total_prepaid_amount > 0 then 'Advance allocations are active'
            else 'No advance-paid months recorded'
          end,
        'message',
          case
            when future_coverage.total_prepaid_amount > 0 then
              case
                when future_coverage.partially_covered_periods > 0 then format(
                  '%s future rent period%s fully covered, with %s more partially funded ahead.',
                  future_coverage.fully_covered_periods,
                  case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
                  future_coverage.partially_covered_periods
                )
                else format(
                  '%s future rent period%s already funded across %s unit%s.',
                  future_coverage.fully_covered_periods,
                  case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
                  future_coverage.units_covered,
                  case when future_coverage.units_covered = 1 then '' else 's' end
                )
              end
            else 'Future rent coverage will be tracked here once payments are allocated ahead of due dates.'
          end,
        'action_label',
          case
            when future_coverage.total_prepaid_amount > 0 then 'Review advance payments'
            else null
          end
      )
    )
  )
  into v_dashboard
  from current_summary
  cross join previous_summary
  cross join exposure_summary
  cross join reliability_scored
  cross join future_coverage;

  return v_dashboard;
end;
$$;

revoke all on function app.get_payment_record_verification_source(app.payment_record_source_enum)
  from public, anon, authenticated;
revoke all on function app.get_rent_payments_ledger_rows(uuid, uuid, integer)
  from public, anon, authenticated;
revoke all on function app.get_rent_payments_dashboard(uuid, uuid, date)
  from public, anon, authenticated;

grant execute on function app.get_rent_payments_ledger_rows(uuid, uuid, integer) to authenticated;
grant execute on function app.get_rent_payments_dashboard(uuid, uuid, date) to authenticated;

-- ----------------------------------------------------------------------------
-- Advance payment allocation and visibility
-- ----------------------------------------------------------------------------

create schema if not exists app;

alter table app.mpesa_stk_requests
  add column if not exists payment_context jsonb not null default '{}'::jsonb;

comment on column app.mpesa_stk_requests.payment_context is
  'Intent metadata for STK requests, such as advance-payment context and requested month coverage.';

create or replace function app.auto_allocate_payment_record_to_charge_periods(
  p_payment_record_id uuid,
  p_future_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_payment app.payment_records%rowtype;
  v_remaining_amount numeric(12,2);
  v_allocated_amount numeric(12,2) := 0;
  v_allocated_charge_count integer := 0;
  v_candidate record;
  v_amount_to_allocate numeric(12,2);
  v_payment_month date;
begin
  select *
    into v_payment
  from app.payment_records pr
  where pr.id = p_payment_record_id
    and pr.deleted_at is null
    and pr.recorded_status = 'recorded'::app.payment_record_status_enum
  limit 1;

  if v_payment.id is null then
    return jsonb_build_object(
      'status', 'missing_payment',
      'payment_record_id', p_payment_record_id
    );
  end if;

  if v_payment.unit_id is null then
    return jsonb_build_object(
      'status', 'missing_unit',
      'payment_record_id', p_payment_record_id
    );
  end if;

  v_remaining_amount := greatest(
    coalesce(v_payment.amount, 0) - coalesce(v_payment.allocated_amount, 0),
    0
  )::numeric(12,2);

  if v_remaining_amount <= 0 then
    return jsonb_build_object(
      'status', 'already_allocated',
      'payment_record_id', p_payment_record_id,
      'allocated_amount', coalesce(v_payment.allocated_amount, 0)
    );
  end if;

  v_payment_month := date_trunc('month', coalesce(v_payment.paid_at, now()))::date;

  for v_candidate in
    select
      rc.id,
      rc.workspace_id,
      rc.property_id,
      rc.unit_id,
      greatest(
        rc.scheduled_amount
        - coalesce((
          select sum(pa.allocated_amount)
          from app.payment_allocations pa
          where pa.rent_charge_period_id = rc.id
            and pa.deleted_at is null
        ), 0),
        0
      )::numeric(12,2) as remaining_charge_amount
    from app.rent_charge_periods rc
    where rc.deleted_at is null
      and rc.property_id = v_payment.property_id
      and rc.unit_id = v_payment.unit_id
      and rc.charge_status <> 'cancelled'::app.rent_charge_status_enum
      and (
        not p_future_only
        or date_trunc('month', rc.billing_period_start)::date > v_payment_month
      )
      and not exists (
        select 1
        from app.payment_allocations existing_pa
        where existing_pa.payment_record_id = v_payment.id
          and existing_pa.rent_charge_period_id = rc.id
          and existing_pa.deleted_at is null
      )
    order by rc.billing_period_start asc, rc.due_on asc, rc.created_at asc
  loop
    exit when v_remaining_amount <= 0;

    if coalesce(v_candidate.remaining_charge_amount, 0) <= 0 then
      continue;
    end if;

    v_amount_to_allocate := least(
      v_remaining_amount,
      v_candidate.remaining_charge_amount
    )::numeric(12,2);

    if v_amount_to_allocate <= 0 then
      continue;
    end if;

    insert into app.payment_allocations (
      workspace_id,
      property_id,
      unit_id,
      payment_record_id,
      rent_charge_period_id,
      allocation_source,
      allocated_amount,
      allocated_at,
      notes
    )
    values (
      v_candidate.workspace_id,
      v_candidate.property_id,
      v_candidate.unit_id,
      v_payment.id,
      v_candidate.id,
      'automatic'::app.payment_allocation_source_enum,
      v_amount_to_allocate,
      coalesce(v_payment.paid_at, now()),
      case
        when p_future_only then 'Auto-allocated from advance payment'
        else 'Auto-allocated from recorded payment'
      end
    );

    perform app.refresh_rent_charge_period_payment_state(v_candidate.id);

    v_remaining_amount := (v_remaining_amount - v_amount_to_allocate)::numeric(12,2);
    v_allocated_amount := (v_allocated_amount + v_amount_to_allocate)::numeric(12,2);
    v_allocated_charge_count := v_allocated_charge_count + 1;
  end loop;

  perform app.refresh_payment_record_allocation_state(v_payment.id);

  return jsonb_build_object(
    'status', case when v_allocated_charge_count > 0 then 'allocated' else 'no_candidate_charges' end,
    'payment_record_id', v_payment.id,
    'allocated_amount', v_allocated_amount,
    'remaining_amount', v_remaining_amount,
    'allocated_charge_count', v_allocated_charge_count,
    'future_only', p_future_only
  );
end;
$$;

create or replace function app.record_mpesa_stk_callback(
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_stk_callback jsonb;
  v_checkout_request_id text;
  v_result_code text;
  v_result_desc text;
  v_stk_request record;
  v_metadata jsonb;
  v_receipt_number text;
  v_amount numeric(12,2);
  v_transacted_at timestamptz;
  v_payment_record_id uuid;
  v_payment_intent text;
  v_requested_advance_months integer;
  v_allocation_result jsonb;
begin
  v_stk_callback := p_payload->'Body'->'stkCallback';
  if v_stk_callback is null then
    raise exception 'Invalid STK callback payload: missing stkCallback body';
  end if;

  v_checkout_request_id := v_stk_callback->>'CheckoutRequestID';
  v_result_code := v_stk_callback->>'ResultCode';
  v_result_desc := v_stk_callback->>'ResultDesc';

  select * into v_stk_request
  from app.mpesa_stk_requests
  where checkout_request_id = v_checkout_request_id
  for update;

  if v_stk_request.id is null then
    raise exception 'No matching STK request found for CheckoutRequestID %', v_checkout_request_id;
  end if;

  if v_stk_request.status <> 'pending' then
    return jsonb_build_object(
      'status', 'duplicate',
      'stk_request_id', v_stk_request.id,
      'processing_status', v_stk_request.status
    );
  end if;

  update app.mpesa_stk_requests
     set status = case
           when v_result_code = '0' then 'success'::app.mpesa_stk_status_enum
           else 'failed'::app.mpesa_stk_status_enum
         end,
         result_code = v_result_code,
         result_desc = v_result_desc,
         raw_callback_payload = p_payload,
         updated_at = now()
   where id = v_stk_request.id;

  if v_result_code = '0' then
    v_metadata := v_stk_callback->'CallbackMetadata'->'Item';
    v_payment_intent := coalesce(v_stk_request.payment_context->>'payment_intent', 'charge_payment');
    v_requested_advance_months := nullif(v_stk_request.payment_context->>'requested_advance_months', '')::integer;

    select (e->>'Value')::text
      into v_receipt_number
    from jsonb_array_elements(v_metadata) e
    where e->>'Name' = 'MpesaReceiptNumber';

    select (e->>'Value')::numeric
      into v_amount
    from jsonb_array_elements(v_metadata) e
    where e->>'Name' = 'Amount';

    select to_timestamp((e->>'Value'), 'YYYYMMDDHH24MISS')
      into v_transacted_at
    from jsonb_array_elements(v_metadata) e
    where e->>'Name' = 'TransactionDate';

    insert into app.payment_records (
      workspace_id,
      property_id,
      unit_id,
      collection_setup_id,
      recorded_status,
      record_source,
      payment_method_type,
      amount,
      currency_code,
      paid_at,
      reference_code,
      external_receipt_number,
      metadata,
      recorded_by_user_id
    )
    select
      v_stk_request.workspace_id,
      v_stk_request.property_id,
      v_stk_request.unit_id,
      v_stk_request.payment_collection_setup_id,
      'recorded',
      'mobile_money_import',
      (select payment_method_type from app.payment_collection_setups where id = v_stk_request.payment_collection_setup_id),
      coalesce(v_amount, v_stk_request.amount),
      'KES',
      coalesce(v_transacted_at, now()),
      v_receipt_number,
      v_receipt_number,
      jsonb_build_object(
        'provider', 'mpesa_daraja',
        'checkout_request_id', v_checkout_request_id,
        'stk_request_id', v_stk_request.id,
        'payment_intent', v_payment_intent,
        'requested_advance_months', v_requested_advance_months,
        'allocation_mode', case
          when v_stk_request.rent_charge_period_id is null then 'unapplied'
          else 'automatic'
        end
      ),
      (select created_by_user_id from app.payment_collection_setups where id = v_stk_request.payment_collection_setup_id)
    returning id into v_payment_record_id;

    if v_stk_request.rent_charge_period_id is not null then
      insert into app.payment_allocations (
        workspace_id,
        property_id,
        unit_id,
        payment_record_id,
        rent_charge_period_id,
        allocation_source,
        allocated_amount,
        allocated_at
      )
      values (
        v_stk_request.workspace_id,
        v_stk_request.property_id,
        v_stk_request.unit_id,
        v_payment_record_id,
        v_stk_request.rent_charge_period_id,
        'automatic',
        coalesce(v_amount, v_stk_request.amount),
        now()
      );

      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
      perform app.refresh_rent_charge_period_payment_state(v_stk_request.rent_charge_period_id);
    else
      v_allocation_result := app.auto_allocate_payment_record_to_charge_periods(
        v_payment_record_id,
        true
      );
      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
    end if;
  end if;

  return jsonb_build_object(
    'status', 'accepted',
    'stk_request_id', v_stk_request.id,
    'payment_record_id', v_payment_record_id,
    'allocation_result', coalesce(v_allocation_result, '{}'::jsonb)
  );
end;
$$;

drop function if exists app.get_rent_payments_ledger_rows(uuid, integer);
drop function if exists app.get_rent_payments_ledger_rows(uuid, uuid, integer);

create function app.get_rent_payments_ledger_rows(
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
  applied_amount numeric,
  unapplied_amount numeric,
  currency_code text,
  method_label text,
  status_key text,
  status_label text,
  status_variant text,
  delay_days integer,
  delay_label text,
  coverage_period_label text,
  coverage_period_count integer,
  allocation_type text,
  verification_source text,
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
      round(coalesce(sum(pa.allocated_amount), 0), 2) as applied_amount,
      count(distinct date_trunc('month', rc.billing_period_start)::date)::int as coverage_period_count,
      min(date_trunc('month', rc.billing_period_start)::date) as first_period_start,
      max(date_trunc('month', rc.billing_period_start)::date) as last_period_start,
      bool_or(
        date_trunc('month', rc.billing_period_start)::date
        > date_trunc('month', pr.paid_at)::date
      ) as has_future_coverage,
      bool_or(
        date_trunc('month', rc.billing_period_start)::date
        <= date_trunc('month', pr.paid_at)::date
      ) as has_current_or_past_coverage,
      bool_and(
        date_trunc('month', rc.billing_period_start)::date
        > date_trunc('month', pr.paid_at)::date
      ) as is_fully_future_coverage,
      max(greatest(coalesce(rc.full_collection_delay_days, 0), 0))
        filter (
          where date_trunc('month', rc.billing_period_start)::date
            <= date_trunc('month', pr.paid_at)::date
        )::int as max_delay_days
    from app.payment_allocations pa
    join app.payment_records pr
      on pr.id = pa.payment_record_id
     and pr.deleted_at is null
    join app.rent_charge_periods rc
      on rc.id = pa.rent_charge_period_id
     and rc.deleted_at is null
    where pa.deleted_at is null
    group by pa.payment_record_id
  ),
  recorded_ledger_rows as (
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
      round(coalesce(ar.applied_amount, 0), 2) as applied_amount,
      round(greatest(pr.amount - coalesce(ar.applied_amount, 0), 0), 2) as unapplied_amount,
      coalesce(nullif(trim(pr.currency_code), ''), 'KES') as currency_code,
      app.get_payment_method_display_label(pr.payment_method_type) as method_label,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'failed'
        when coalesce(ar.applied_amount, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then 'pending'
        when coalesce(ar.applied_amount, 0) = 0 then 'unmatched'
        when coalesce(ar.applied_amount, 0) < pr.amount then 'partial'
        when coalesce(ar.is_fully_future_coverage, false) then 'advance_paid'
        else 'matched'
      end as status_key,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'Failed'
        when coalesce(ar.applied_amount, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then 'Pending Allocation'
        when coalesce(ar.applied_amount, 0) = 0 then 'Unmatched'
        when coalesce(ar.applied_amount, 0) < pr.amount then 'Partial'
        when coalesce(ar.is_fully_future_coverage, false) then 'Advance Paid'
        else 'Matched'
      end as status_label,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'error'
        when coalesce(ar.applied_amount, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then 'info'
        when coalesce(ar.applied_amount, 0) = 0 then 'warning'
        when coalesce(ar.applied_amount, 0) < pr.amount then 'info'
        else 'success'
      end as status_variant,
      case
        when coalesce(ar.is_fully_future_coverage, false) then null
        when coalesce(ar.applied_amount, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then null
        else ar.max_delay_days
      end as delay_days,
      case
        when pr.recorded_status = 'voided'::app.payment_record_status_enum then 'Failed'
        when coalesce(ar.is_fully_future_coverage, false) then 'Paid early'
        when coalesce(ar.applied_amount, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then 'Awaiting future charge'
        when coalesce(ar.applied_amount, 0) = 0 then 'Unallocated'
        when ar.max_delay_days is null or ar.max_delay_days <= 0 then 'On-time'
        else format('%s days', ar.max_delay_days)
      end as delay_label,
      case
        when coalesce(ar.coverage_period_count, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then 'Awaiting future allocation'
        when coalesce(ar.coverage_period_count, 0) = 0 then 'Unallocated'
        when ar.first_period_start = ar.last_period_start then to_char(ar.first_period_start, 'Mon YYYY')
        else format(
          '%s - %s',
          to_char(ar.first_period_start, 'Mon YYYY'),
          to_char(ar.last_period_start, 'Mon YYYY')
        )
      end as coverage_period_label,
      coalesce(ar.coverage_period_count, 0) as coverage_period_count,
      case
        when coalesce(ar.coverage_period_count, 0) = 0
          and (
            coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
            or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
          ) then 'Advance cash on hold'
        when coalesce(ar.coverage_period_count, 0) = 0 then 'Unallocated cash'
        when coalesce(ar.has_future_coverage, false) and coalesce(ar.has_current_or_past_coverage, false)
          then 'Current + future rent'
        when coalesce(ar.has_future_coverage, false) then 'Covers future rent'
        else 'Current-period rent'
      end as allocation_type,
      app.get_payment_record_verification_source(pr.record_source) as verification_source,
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
    left join allocation_rollup ar
      on ar.payment_record_id = pr.id
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
  ),
  pending_request_rows as (
    select
      stk.id as payment_record_id,
      stk.property_id,
      coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
      stk.unit_id,
      coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label,
      coalesce(
        nullif(trim(snapshot.current_tenant_name), ''),
        'Unassigned Tenant'
      ) as tenant_name,
      stk.created_at::date as paid_on,
      stk.created_at as paid_at,
      round(stk.amount, 2) as amount,
      0::numeric as applied_amount,
      round(stk.amount, 2) as unapplied_amount,
      'KES'::text as currency_code,
      coalesce(
        app.get_payment_method_display_label(pcs.payment_method_type),
        'M-Pesa'
      ) as method_label,
      'pending'::text as status_key,
      'Pending Confirmation'::text as status_label,
      'info'::text as status_variant,
      null::integer as delay_days,
      'Waiting for callback'::text as delay_label,
      'Awaiting confirmation'::text as coverage_period_label,
      0::integer as coverage_period_count,
      case
        when coalesce(stk.payment_context->>'payment_intent', '') = 'advance_payment'
          then 'Advance payment request'
        when stk.rent_charge_period_id is not null
          then 'Current-period payment request'
        else 'Pending payment request'
      end as allocation_type,
      'M-Pesa STK request'::text as verification_source,
      stk.checkout_request_id as reference_code,
      null::text as external_receipt_number,
      null::text as payer_name,
      stk.phone_number as payer_phone
    from app.mpesa_stk_requests stk
    join accessible_properties ap
      on ap.property_id = stk.property_id
    join app.properties p
      on p.id = stk.property_id
     and p.deleted_at is null
    left join app.units u
      on u.id = stk.unit_id
     and u.deleted_at is null
    left join app.unit_occupancy_snapshots snapshot
      on snapshot.unit_id = stk.unit_id
    left join app.payment_collection_setups pcs
      on pcs.id = stk.payment_collection_setup_id
     and pcs.deleted_at is null
    where stk.status = 'pending'::app.mpesa_stk_status_enum
      and (
        p_unit_id is null
        or stk.unit_id = p_unit_id
      )
      and not exists (
        select 1
        from app.payment_records pr_existing
        where pr_existing.deleted_at is null
          and pr_existing.metadata->>'checkout_request_id' = stk.checkout_request_id
      )
  ),
  ledger_rows as (
    select *
    from recorded_ledger_rows

    union all

    select *
    from pending_request_rows
  )
  select *
  from ledger_rows
  order by paid_at desc, payment_record_id desc
  limit greatest(coalesce(p_limit, 50), 1);
end;
$$;

drop function if exists app.get_rent_payments_dashboard(uuid, date);
drop function if exists app.get_rent_payments_dashboard(uuid, uuid, date);

create function app.get_rent_payments_dashboard(
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
  v_min_completed_cycles integer := 3;
  v_dashboard jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  with base as (
    select *
    from app.get_rent_payment_charge_snapshot(p_property_id, p_unit_id, v_reference_date)
  ),
  accessible_properties as (
    select accessible.property_id
    from app.get_financial_accessible_property_ids(p_property_id) as accessible
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
  ),
  due_previous as (
    select *
    from previous_period
    where collection_deadline <= v_previous_period_end
  ),
  completed_due_current as (
    select *
    from due_current
    where is_fully_paid
  ),
  completed_due_previous as (
    select *
    from due_previous
    where is_fully_paid
  ),
  current_summary as (
    select
      coalesce(max(currency_code), 'KES') as currency_code,
      round(coalesce(sum(amount_paid), 0), 2) as total_collected,
      round(coalesce(sum(scheduled_amount), 0), 2) as expected_rent,
      round(
        least(
          100,
          case
            when coalesce(sum(scheduled_amount), 0) = 0 then 0
            else (coalesce(sum(amount_paid), 0) / nullif(sum(scheduled_amount), 0)) * 100
          end
        ),
        1
      ) as collection_rate,
      round(
        case
          when (select count(*) from due_current) = 0 then 0
          else (
            (select count(*) from due_current where is_fully_paid and positive_delay_days = 0)::numeric
            / nullif((select count(*) from due_current), 0)::numeric
          ) * 100
        end,
        1
      ) as on_time_rate,
      round(
        coalesce(
          (select avg(positive_delay_days::numeric) from completed_due_current),
          0
        ),
        1
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
      ) as outstanding_pct,
      count(*)::int as generated_charges_count,
      (select count(*)::int from due_current) as due_charges_count,
      (select count(*)::int from completed_due_current) as completed_due_charges_count
    from current_period
  ),
  previous_summary as (
    select
      round(coalesce(sum(amount_paid), 0), 2) as total_collected,
      round(
        least(
          100,
          case
            when coalesce(sum(scheduled_amount), 0) = 0 then 0
            else (coalesce(sum(amount_paid), 0) / nullif(sum(scheduled_amount), 0)) * 100
          end
        ),
        1
      ) as collection_rate,
      round(
        case
          when (select count(*) from due_previous) = 0 then 0
          else (
            (select count(*) from due_previous where is_fully_paid and positive_delay_days = 0)::numeric
            / nullif((select count(*) from due_previous), 0)::numeric
          ) * 100
        end,
        1
      ) as on_time_rate,
      round(
        coalesce(
          (select avg(positive_delay_days::numeric) from completed_due_previous),
          0
        ),
        1
      ) as avg_delay_days
    from previous_period
  ),
  exposure_summary as (
    select
      round(coalesce(sum(outstanding_amount) filter (where is_overdue and outstanding_amount > 0), 0), 2) as overdue_amount,
      count(distinct unit_id) filter (where is_overdue and outstanding_amount > 0)::int as overdue_units_affected
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
      round(coalesce(sum(b.scheduled_amount), 0), 2) as expected,
      round(coalesce(sum(b.outstanding_amount), 0), 2) as outstanding
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
      count(*)::int as completed_charge_count
    from completed_due_current
    group by delay_bucket
  ),
  behavior_previous as (
    select
      delay_bucket as bucket_key,
      count(*)::int as completed_charge_count
    from completed_due_previous
    group by delay_bucket
  ),
  behavior_totals as (
    select
      (select count(*)::int from completed_due_current) as current_total,
      (select count(*)::int from completed_due_previous) as previous_total
  ),
  behavior_comparison as (
    select
      template.bucket_key,
      template.label,
      template.sort_order,
      template.color,
      coalesce(current_bucket.completed_charge_count, 0) as current_units,
      coalesce(previous_bucket.completed_charge_count, 0) as previous_units,
      round(
        case
          when totals.current_total = 0 then 0
          else (coalesce(current_bucket.completed_charge_count, 0)::numeric / totals.current_total::numeric) * 100
        end,
        0
      ) as current_pct,
      round(
        case
          when totals.previous_total = 0 then 0
          else (coalesce(previous_bucket.completed_charge_count, 0)::numeric / totals.previous_total::numeric) * 100
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
  history_due as (
    select *
    from base
    where collection_deadline <= v_reference_date
      and billing_month between v_trend_start and v_period_start
  ),
  history_completed as (
    select *
    from history_due
    where is_fully_paid
  ),
  reliability_metrics as (
    select
      count(*)::int as total_due_invoices,
      count(*) filter (where is_fully_paid)::int as completed_due_invoices,
      count(distinct billing_month) filter (where is_fully_paid)::int as completed_due_cycles,
      count(*) filter (where is_fully_paid and positive_delay_days = 0)::int as on_time_paid_invoices,
      round(coalesce(avg(positive_delay_days::numeric) filter (where is_fully_paid), 0), 1) as avg_completed_delay_days
    from history_due
  ),
  consistency_distribution as (
    select extract(day from coalesce(last_payment_at, fully_paid_at)::date)::numeric as payment_day
    from history_completed
    where coalesce(last_payment_at, fully_paid_at) is not null
  ),
  consistency_metrics as (
    select
      count(*)::int as payment_observations,
      coalesce(stddev_samp(payment_day), 0) as payment_day_stddev
    from consistency_distribution
  ),
  reliability_source as (
    select
      rm.total_due_invoices,
      rm.completed_due_invoices,
      rm.completed_due_cycles,
      round(
        case
          when rm.total_due_invoices = 0 then 0
          else (rm.on_time_paid_invoices::numeric / rm.total_due_invoices::numeric) * 100
        end,
        1
      ) as on_time_rate,
      rm.avg_completed_delay_days as avg_delay_days,
      round(
        case
          when rm.total_due_invoices = 0 then 0
          else (rm.completed_due_invoices::numeric / rm.total_due_invoices::numeric) * 100
        end,
        1
      ) as collection_completion_rate,
      case
        when rm.avg_completed_delay_days <= 0 then 100
        when rm.avg_completed_delay_days <= 3 then 80
        when rm.avg_completed_delay_days <= 7 then 60
        when rm.avg_completed_delay_days <= 14 then 35
        else 10
      end as delay_score,
      case
        when cm.payment_observations < v_min_completed_cycles then 0
        when cm.payment_day_stddev <= 1 then 100
        when cm.payment_day_stddev <= 2 then 85
        when cm.payment_day_stddev <= 4 then 70
        when cm.payment_day_stddev <= 6 then 55
        when cm.payment_day_stddev <= 9 then 40
        else 25
      end as consistency_score,
      (
        rm.completed_due_invoices >= v_min_completed_cycles
        and rm.completed_due_cycles >= v_min_completed_cycles
      ) as is_eligible
    from reliability_metrics rm
    cross join consistency_metrics cm
  ),
  reliability_scored as (
    select
      rs.total_due_invoices,
      rs.completed_due_invoices,
      rs.completed_due_cycles,
      rs.on_time_rate,
      rs.avg_delay_days,
      rs.collection_completion_rate,
      rs.delay_score,
      rs.consistency_score,
      rs.is_eligible,
      case
        when not rs.is_eligible then null
        else round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        )::int
      end as score,
      case
        when not rs.is_eligible then 'Insufficient history'
        when round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        ) >= 85 then 'High'
        when round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        ) >= 65 then 'Moderate'
        when round(
          (
            (rs.on_time_rate * 0.40)
            + (rs.delay_score * 0.25)
            + (rs.collection_completion_rate * 0.20)
            + (rs.consistency_score * 0.15)
          ),
          0
        ) >= 40 then 'Low'
        else 'Critical'
      end as status
    from reliability_source rs
  ),
  future_coverage as (
    select
      round(coalesce(sum(amount_paid), 0), 2) as total_prepaid_amount,
      count(*) filter (
        where amount_paid > 0
          and outstanding_amount <= 0
          and scheduled_amount > 0
      )::int as fully_covered_periods,
      count(*) filter (
        where amount_paid > 0
          and outstanding_amount > 0
      )::int as partially_covered_periods,
      count(distinct unit_id) filter (where amount_paid > 0)::int as units_covered
    from base
    where billing_period_start > v_period_end
  ),
  pending_advance_cash as (
    select
      round(
        coalesce(sum(greatest(pr.amount - coalesce(pr.allocated_amount, 0), 0)), 0),
        2
      ) as pending_prepaid_amount
    from app.payment_records pr
    join accessible_properties ap
      on ap.property_id = pr.property_id
    where pr.deleted_at is null
      and pr.recorded_status = 'recorded'::app.payment_record_status_enum
      and pr.unit_id is not null
      and (p_unit_id is null or pr.unit_id = p_unit_id)
      and greatest(pr.amount - coalesce(pr.allocated_amount, 0), 0) > 0
      and (
        coalesce(pr.metadata->>'payment_intent', '') = 'advance_payment'
        or coalesce(pr.metadata->>'allocation_mode', '') = 'unapplied'
      )
  ),
  risk_rollup as (
    select
      base.property_id,
      base.property_name,
      base.unit_id,
      base.unit_label,
      max(base.tenant_name) as tenant_name,
      count(*) filter (where base.collection_deadline <= v_reference_date)::int as due_cycles,
      count(*) filter (where base.collection_deadline <= v_reference_date and base.is_overdue)::int as overdue_cycles,
      count(*) filter (
        where base.collection_deadline <= v_reference_date
          and (
            (base.is_fully_paid and base.positive_delay_days >= 4)
            or (base.outstanding_amount > 0 and base.is_overdue)
          )
      )::int as repeated_late_cycles,
      round(
        coalesce(
          avg(base.positive_delay_days::numeric) filter (
            where base.collection_deadline <= v_reference_date and base.is_fully_paid
          ),
          0
        ),
        1
      ) as avg_delay_days,
      round(
        coalesce(sum(base.outstanding_amount) filter (where base.collection_deadline <= v_reference_date), 0),
        2
      ) as unpaid_balance
    from base
    group by base.property_id, base.property_name, base.unit_id, base.unit_label
  ),
  risk_candidates as (
    select
      rollup.property_id,
      rollup.property_name,
      rollup.unit_id,
      rollup.unit_label,
      coalesce(nullif(trim(rollup.tenant_name), ''), 'Unassigned Tenant') as tenant_name,
      (
        (coalesce(rollup.overdue_cycles, 0) * 35)
        + (coalesce(rollup.repeated_late_cycles, 0) * 12)
        + (
          case
            when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
            when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
            when coalesce(rollup.avg_delay_days, 0) > 0 then 6
            else 0
          end
        )
        + (
          case
            when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
            when coalesce(rollup.unpaid_balance, 0) > 0 then 8
            else 0
          end
        )
      )::int as risk_score,
      case
        when coalesce(rollup.overdue_cycles, 0) >= 2 then 'Multiple overdue cycles'
        when coalesce(rollup.unpaid_balance, 0) > 0 and coalesce(rollup.avg_delay_days, 0) >= 7 then 'Overdue balance beyond threshold'
        when coalesce(rollup.repeated_late_cycles, 0) >= 2 then 'Repeated late payment behavior'
        when coalesce(rollup.unpaid_balance, 0) > 0 then 'Open rent balance requires follow-up'
        else 'Monitor payment behavior'
      end as pattern,
      case
        when (
          (coalesce(rollup.overdue_cycles, 0) * 35)
          + (coalesce(rollup.repeated_late_cycles, 0) * 12)
          + (
            case
              when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
              when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
              when coalesce(rollup.avg_delay_days, 0) > 0 then 6
              else 0
            end
          )
          + (
            case
              when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
              when coalesce(rollup.unpaid_balance, 0) > 0 then 8
              else 0
            end
          )
        ) >= 60 then 'High'
        when (
          (coalesce(rollup.overdue_cycles, 0) * 35)
          + (coalesce(rollup.repeated_late_cycles, 0) * 12)
          + (
            case
              when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
              when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
              when coalesce(rollup.avg_delay_days, 0) > 0 then 6
              else 0
            end
          )
          + (
            case
              when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
              when coalesce(rollup.unpaid_balance, 0) > 0 then 8
              else 0
            end
          )
        ) >= 35 then 'Medium'
        when (
          (coalesce(rollup.overdue_cycles, 0) * 35)
          + (coalesce(rollup.repeated_late_cycles, 0) * 12)
          + (
            case
              when coalesce(rollup.avg_delay_days, 0) >= 7 then 20
              when coalesce(rollup.avg_delay_days, 0) >= 4 then 12
              when coalesce(rollup.avg_delay_days, 0) > 0 then 6
              else 0
            end
          )
          + (
            case
              when coalesce(rollup.unpaid_balance, 0) >= 20000 then 15
              when coalesce(rollup.unpaid_balance, 0) > 0 then 8
              else 0
            end
          )
        ) >= 15 then 'Low'
        else null
      end as risk_level,
      coalesce(rollup.avg_delay_days, 0) as avg_delay_days,
      coalesce(rollup.unpaid_balance, 0) as overdue_amount
    from risk_rollup rollup
    where coalesce(rollup.due_cycles, 0) > 0
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
        round(current_summary.collection_rate - coalesce(previous_summary.collection_rate, 0), 1),
      'expected_rent', current_summary.expected_rent,
      'on_time_rate', current_summary.on_time_rate,
      'on_time_rate_delta_pct',
        round(current_summary.on_time_rate - coalesce(previous_summary.on_time_rate, 0), 1),
      'avg_delay_days', current_summary.avg_delay_days,
      'avg_delay_delta_days',
        round(current_summary.avg_delay_days - coalesce(previous_summary.avg_delay_days, 0), 1),
      'outstanding_amount', current_summary.outstanding_amount,
      'outstanding_pct', current_summary.outstanding_pct,
      'overdue_amount', exposure_summary.overdue_amount,
      'overdue_units_affected', exposure_summary.overdue_units_affected,
      'generated_charges_count', current_summary.generated_charges_count,
      'due_charges_count', current_summary.due_charges_count,
      'completed_due_charges_count', current_summary.completed_due_charges_count
    ),
    'trend',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'label', trend_rollup.label,
          'collected', trend_rollup.collected,
          'expected', trend_rollup.expected,
          'outstanding', trend_rollup.outstanding
        )
        order by trend_rollup.sort_order
      )
      from trend_rollup
    ), '[]'::jsonb),
    'behavior_breakdown',
    jsonb_build_object(
      'eligible', coalesce((select current_total from behavior_totals), 0) > 0,
      'total_completed_charges', coalesce((select current_total from behavior_totals), 0),
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
          when coalesce((select current_pct from behavior_comparison where bucket_key = 'on_time'), 0) >= 80 then
            'Completed rent charges are landing mostly on time in the selected period.'
          when coalesce((select current_pct from behavior_comparison where bucket_key = 'days_7_plus'), 0) >= 20 then
            'Long delays are showing up in completed charges. Prioritize units with repeated late completions.'
          else
            'Behavior is mixed. Watch 4-7 day and 7+ day delays before they harden into arrears.'
        end
    ),
    'reliability',
    jsonb_build_object(
      'eligible', reliability_scored.is_eligible,
      'score', reliability_scored.score,
      'on_time_rate', reliability_scored.on_time_rate,
      'avg_delay_days', reliability_scored.avg_delay_days,
      'completion_rate', reliability_scored.collection_completion_rate,
      'consistency_score', reliability_scored.consistency_score,
      'delay_score', reliability_scored.delay_score,
      'status', reliability_scored.status,
      'minimum_completed_invoices', v_min_completed_cycles,
      'completed_due_invoices', reliability_scored.completed_due_invoices,
      'completed_due_cycles', reliability_scored.completed_due_cycles,
      'summary',
        case
          when not reliability_scored.is_eligible then
            'Reliability scoring will appear once recurring rent history is available.'
          else
            'Weighted from on-time performance (40%), delay discipline (25%), completion rate (20%), and payment consistency (15%).'
        end
    ),
    'advance_summary',
    jsonb_build_object(
      'total_prepaid_amount', future_coverage.total_prepaid_amount,
      'pending_prepaid_amount', pending_advance_cash.pending_prepaid_amount,
      'fully_covered_periods', future_coverage.fully_covered_periods,
      'partially_covered_periods', future_coverage.partially_covered_periods,
      'units_covered', future_coverage.units_covered,
      'summary',
        case
          when future_coverage.total_prepaid_amount <= 0
            and pending_advance_cash.pending_prepaid_amount <= 0 then
            'Advance payment visibility will appear once future rent is allocated.'
          when future_coverage.total_prepaid_amount <= 0
            and pending_advance_cash.pending_prepaid_amount > 0 then
            format(
              '%s %s has been received early and is waiting for future rent allocation.',
              current_summary.currency_code,
              trim(to_char(pending_advance_cash.pending_prepaid_amount, 'FM999,999,999,990D00'))
            )
          when pending_advance_cash.pending_prepaid_amount > 0 then
            format(
              '%s future coverage is already allocated, with %s %s still waiting for later rent charges.',
              case
                when future_coverage.partially_covered_periods > 0 then
                  format(
                    '%s full period%s and %s partial period%s',
                    future_coverage.fully_covered_periods,
                    case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
                    future_coverage.partially_covered_periods,
                    case when future_coverage.partially_covered_periods = 1 then '' else 's' end
                  )
                else
                  format(
                    '%s future period%s',
                    future_coverage.fully_covered_periods,
                    case when future_coverage.fully_covered_periods = 1 then '' else 's' end
                  )
              end,
              current_summary.currency_code,
              trim(to_char(pending_advance_cash.pending_prepaid_amount, 'FM999,999,999,990D00'))
            )
          when future_coverage.partially_covered_periods > 0 then
            format(
              '%s future rent period%s fully covered, with %s more partially funded ahead.',
              future_coverage.fully_covered_periods,
              case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
              future_coverage.partially_covered_periods
            )
          else
            format(
              '%s future rent period%s already funded across %s unit%s.',
              future_coverage.fully_covered_periods,
              case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
              future_coverage.units_covered,
              case when future_coverage.units_covered = 1 then '' else 's' end
            )
        end
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
          'risk_score', risk_score,
          'avg_delay_days', avg_delay_days,
          'overdue_amount', overdue_amount
        )
        order by risk_score desc, overdue_amount desc, property_name, unit_label
      )
      from (
        select *
        from risk_candidates
        where risk_level in ('High', 'Medium')
        order by risk_score desc, overdue_amount desc, property_name, unit_label
        limit 8
      ) ranked_risk
    ), '[]'::jsonb),
    'insights',
    jsonb_build_array(
      jsonb_build_object(
        'type',
          case
            when current_summary.generated_charges_count = 0 then 'neutral'
            when exposure_summary.overdue_amount > 0 then 'warning'
            else 'success'
          end,
        'title',
          case
            when current_summary.generated_charges_count = 0 then 'No charges generated yet'
            when exposure_summary.overdue_amount > 0 then 'Overdue rent needs follow-up'
            else 'Current-period rent is under control'
          end,
        'message',
          case
            when current_summary.generated_charges_count = 0 then
              'No rent charges have been generated for this period yet, so collection analytics stay in a neutral state.'
            when exposure_summary.overdue_amount > 0 then format(
              '%s is already overdue across %s unit%s. Focus collection effort on balances that are past due.',
              current_summary.currency_code || ' ' || trim(to_char(exposure_summary.overdue_amount, 'FM999,999,999,990D00')),
              exposure_summary.overdue_units_affected,
              case when exposure_summary.overdue_units_affected = 1 then '' else 's' end
            )
            else 'Allocated collections are matching active generated charges without overdue pressure right now.'
          end,
        'action_label',
          case
            when current_summary.generated_charges_count = 0 then 'Review setup'
            when exposure_summary.overdue_amount > 0 then 'Review overdue units'
            else 'Inspect ledger'
          end
      ),
      jsonb_build_object(
        'type',
          case
            when not reliability_scored.is_eligible then 'neutral'
            when reliability_scored.score >= 85 then 'success'
            when reliability_scored.score >= 65 then 'info'
            else 'warning'
          end,
        'title',
          case
            when not reliability_scored.is_eligible then 'Not enough payment history yet'
            else 'Collection reliability is formula-based'
          end,
        'message',
          case
            when not reliability_scored.is_eligible then
              'Behavior insights will become available after completed and due rent cycles are recorded.'
            else format(
              'Current reliability blends %s%% on-time performance, %s%% completion, and a %s/100 consistency score into one operational signal.',
              reliability_scored.on_time_rate,
              reliability_scored.collection_completion_rate,
              reliability_scored.consistency_score
            )
          end,
        'action_label',
          case
            when not reliability_scored.is_eligible then null
            else 'View reliability model'
          end
      ),
      jsonb_build_object(
        'type',
          case
            when future_coverage.total_prepaid_amount > 0
              or pending_advance_cash.pending_prepaid_amount > 0 then 'info'
            else 'neutral'
          end,
        'title',
          case
            when future_coverage.total_prepaid_amount > 0 then 'Advance allocations are active'
            when pending_advance_cash.pending_prepaid_amount > 0 then 'Advance cash is waiting for allocation'
            else 'No advance-paid months recorded'
          end,
        'message',
          case
            when future_coverage.total_prepaid_amount > 0 then
              case
                when future_coverage.partially_covered_periods > 0 then format(
                  '%s future rent period%s fully covered, with %s more partially funded ahead.',
                  future_coverage.fully_covered_periods,
                  case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
                  future_coverage.partially_covered_periods
                )
                else format(
                  '%s future rent period%s already funded across %s unit%s.',
                  future_coverage.fully_covered_periods,
                  case when future_coverage.fully_covered_periods = 1 then '' else 's' end,
                  future_coverage.units_covered,
                  case when future_coverage.units_covered = 1 then '' else 's' end
                )
              end
            when pending_advance_cash.pending_prepaid_amount > 0 then format(
              '%s %s has been received early, but it is still waiting for future rent charges before the dashboard can mark months as covered.',
              current_summary.currency_code,
              trim(to_char(pending_advance_cash.pending_prepaid_amount, 'FM999,999,999,990D00'))
            )
            else 'Future rent coverage will be tracked here once payments are allocated ahead of due dates.'
          end,
        'action_label',
          case
            when future_coverage.total_prepaid_amount > 0
              or pending_advance_cash.pending_prepaid_amount > 0 then 'Review advance payments'
            else null
          end
      )
    )
  )
  into v_dashboard
  from current_summary
  cross join previous_summary
  cross join exposure_summary
  cross join reliability_scored
  cross join future_coverage
  cross join pending_advance_cash;

  return v_dashboard;
end;
$$;

revoke all on function app.auto_allocate_payment_record_to_charge_periods(uuid, boolean)
  from public, anon, authenticated;
revoke all on function app.record_mpesa_stk_callback(jsonb)
  from public, anon, authenticated;
revoke all on function app.get_rent_payments_ledger_rows(uuid, uuid, integer)
  from public, anon, authenticated;
revoke all on function app.get_rent_payments_dashboard(uuid, uuid, date)
  from public, anon, authenticated;

grant execute on function app.auto_allocate_payment_record_to_charge_periods(uuid, boolean)
  to service_role;
grant execute on function app.record_mpesa_stk_callback(jsonb)
  to service_role;
grant execute on function app.get_rent_payments_ledger_rows(uuid, uuid, integer)
  to authenticated;
grant execute on function app.get_rent_payments_dashboard(uuid, uuid, date)
  to authenticated;

-- ----------------------------------------------------------------------------
-- M-Pesa callback reconciliation
-- ----------------------------------------------------------------------------

create schema if not exists app;

create table if not exists app.mpesa_stk_callback_events (
  id uuid primary key default gen_random_uuid(),
  checkout_request_id text not null,
  result_code text,
  result_desc text,
  payload jsonb not null,
  processing_status text not null default 'pending',
  linked_stk_request_id uuid references app.mpesa_stk_requests(id) on delete set null,
  linked_payment_record_id uuid references app.payment_records(id) on delete set null,
  processing_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint chk_mpesa_stk_callback_events_processing_status
    check (processing_status in ('pending', 'processed', 'failed', 'ignored'))
);

comment on table app.mpesa_stk_callback_events is
  'Durable inbox of M-Pesa STK callbacks. Used to replay or reconcile callbacks when posting fails.';

create index if not exists idx_mpesa_stk_callback_events_checkout_request_id
  on app.mpesa_stk_callback_events(checkout_request_id, received_at desc);

create index if not exists idx_mpesa_stk_callback_events_processing_status
  on app.mpesa_stk_callback_events(processing_status, received_at desc);

alter table app.mpesa_stk_callback_events enable row level security;
alter table app.mpesa_stk_callback_events force row level security;

drop policy if exists mpesa_stk_callback_events_no_direct_client_access
  on app.mpesa_stk_callback_events;
create policy mpesa_stk_callback_events_no_direct_client_access
  on app.mpesa_stk_callback_events
  as restrictive
  for all
  to public
  using (false)
  with check (false);

create index if not exists idx_payment_records_metadata_checkout_request_id
  on app.payment_records ((metadata->>'checkout_request_id'))
  where deleted_at is null and metadata ? 'checkout_request_id';

create or replace function app.process_mpesa_stk_callback_event(
  p_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_event app.mpesa_stk_callback_events%rowtype;
  v_result jsonb;
  v_result_status text;
  v_stk_request_id uuid;
  v_payment_record_id uuid;
begin
  select *
    into v_event
  from app.mpesa_stk_callback_events
  where id = p_event_id
  for update;

  if v_event.id is null then
    raise exception 'STK callback event not found: %', p_event_id;
  end if;

  if v_event.processing_status in ('processed', 'ignored') then
    return jsonb_build_object(
      'status', v_event.processing_status,
      'event_id', v_event.id,
      'checkout_request_id', v_event.checkout_request_id,
      'stk_request_id', v_event.linked_stk_request_id,
      'payment_record_id', v_event.linked_payment_record_id
    );
  end if;

  begin
    v_result := app.record_mpesa_stk_callback(v_event.payload);
    v_result_status := coalesce(v_result->>'status', 'accepted');
    v_stk_request_id := nullif(v_result->>'stk_request_id', '')::uuid;
    v_payment_record_id := nullif(v_result->>'payment_record_id', '')::uuid;

    if v_payment_record_id is null then
      select pr.id
        into v_payment_record_id
      from app.payment_records pr
      where pr.deleted_at is null
        and pr.metadata->>'checkout_request_id' = v_event.checkout_request_id
      order by pr.created_at desc
      limit 1;
    end if;

    if v_stk_request_id is null then
      select stk.id
        into v_stk_request_id
      from app.mpesa_stk_requests stk
      where stk.checkout_request_id = v_event.checkout_request_id
      limit 1;
    end if;

    update app.mpesa_stk_callback_events
       set processing_status = case
             when v_result_status = 'duplicate' then 'ignored'
             else 'processed'
           end,
           linked_stk_request_id = coalesce(v_stk_request_id, linked_stk_request_id),
           linked_payment_record_id = coalesce(v_payment_record_id, linked_payment_record_id),
           processing_error = null,
           processed_at = now()
     where id = v_event.id;

    return jsonb_build_object(
      'status', v_result_status,
      'event_id', v_event.id,
      'checkout_request_id', v_event.checkout_request_id,
      'stk_request_id', v_stk_request_id,
      'payment_record_id', v_payment_record_id,
      'processing_status', case
        when v_result_status = 'duplicate' then 'ignored'
        else 'processed'
      end
    );
  exception when others then
    update app.mpesa_stk_callback_events
       set processing_status = 'failed',
           linked_stk_request_id = coalesce(
             linked_stk_request_id,
             (
               select stk.id
               from app.mpesa_stk_requests stk
               where stk.checkout_request_id = v_event.checkout_request_id
               limit 1
             )
           ),
           processing_error = sqlerrm,
           processed_at = now()
     where id = v_event.id;

    return jsonb_build_object(
      'status', 'failed',
      'event_id', v_event.id,
      'checkout_request_id', v_event.checkout_request_id,
      'error', sqlerrm
    );
  end;
end;
$$;

create or replace function app.get_tenant_mpesa_payment_status(
  p_checkout_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_caller_user_id uuid := auth.uid();
  v_stk_request app.mpesa_stk_requests%rowtype;
  v_workspace_id uuid;
  v_has_access boolean := false;
  v_latest_event app.mpesa_stk_callback_events%rowtype;
  v_payment_record_id uuid;
begin
  if v_caller_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_checkout_request_id is null or length(trim(p_checkout_request_id)) = 0 then
    raise exception 'checkoutRequestId is required';
  end if;

  select stk.*
    into v_stk_request
  from app.mpesa_stk_requests stk
  where stk.checkout_request_id = trim(p_checkout_request_id)
  limit 1;

  if v_stk_request.id is null then
    raise exception 'Payment request not found';
  end if;

  select p.workspace_id
    into v_workspace_id
  from app.properties p
  where p.id = v_stk_request.property_id
    and p.deleted_at is null
  limit 1;

  if v_stk_request.unit_id is not null then
    select exists (
      select 1
      from app.unit_tenancies ut
      where ut.unit_id = v_stk_request.unit_id
        and ut.tenant_user_id = v_caller_user_id
        and ut.status in ('active', 'scheduled', 'pending_agreement')
      union all
      select 1
      from app.unit_occupancy_snapshots uos
      where uos.unit_id = v_stk_request.unit_id
        and uos.current_tenant_user_id = v_caller_user_id
        and uos.occupancy_status in ('occupied', 'pending_confirmation')
    ) into v_has_access;
  end if;

  if not v_has_access then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
      or app.has_financial_management_access(v_stk_request.property_id)
    ) then
      raise exception 'Forbidden';
    end if;
  end if;

  select *
    into v_latest_event
  from app.mpesa_stk_callback_events event_row
  where event_row.checkout_request_id = trim(p_checkout_request_id)
  order by event_row.received_at desc
  limit 1;

  if v_stk_request.status = 'pending'::app.mpesa_stk_status_enum then
    if v_latest_event.id is not null
      and v_latest_event.processing_status in ('pending', 'failed') then
      perform app.process_mpesa_stk_callback_event(v_latest_event.id);
    elsif v_stk_request.raw_callback_payload <> '{}'::jsonb then
      begin
        perform app.record_mpesa_stk_callback(v_stk_request.raw_callback_payload);
      exception when others then
        update app.mpesa_stk_requests
           set result_desc = format(
                 'Stored callback replay failed: %s',
                 sqlerrm
               ),
               updated_at = now()
         where id = v_stk_request.id;
      end;
    end if;

    select *
      into v_stk_request
    from app.mpesa_stk_requests
    where id = v_stk_request.id;

    select *
      into v_latest_event
    from app.mpesa_stk_callback_events event_row
    where event_row.checkout_request_id = trim(p_checkout_request_id)
    order by event_row.received_at desc
    limit 1;
  end if;

  select pr.id
    into v_payment_record_id
  from app.payment_records pr
  where pr.deleted_at is null
    and pr.metadata->>'checkout_request_id' = trim(p_checkout_request_id)
  order by pr.created_at desc
  limit 1;

  return jsonb_build_object(
    'checkout_request_id', trim(p_checkout_request_id),
    'stk_request_id', v_stk_request.id,
    'status', v_stk_request.status,
    'result_code', v_stk_request.result_code,
    'result_desc', v_stk_request.result_desc,
    'amount', v_stk_request.amount,
    'phone_number', v_stk_request.phone_number,
    'payment_record_id', v_payment_record_id,
    'is_posted', v_payment_record_id is not null,
    'callback_received',
      (
        v_latest_event.id is not null
        or v_stk_request.raw_callback_payload <> '{}'::jsonb
      ),
    'callback_processed',
      coalesce(v_latest_event.processing_status in ('processed', 'ignored'), false),
    'callback_processing_error', v_latest_event.processing_error,
    'updated_at', v_stk_request.updated_at
  );
end;
$$;

create or replace function app.reconcile_mpesa_stk_request_from_status_query(
  p_checkout_request_id text,
  p_status_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_stk_request app.mpesa_stk_requests%rowtype;
  v_existing_payment_record_id uuid;
  v_payment_record_id uuid;
  v_result_code text := coalesce(p_status_payload->>'ResultCode', '');
  v_result_desc text := coalesce(
    nullif(p_status_payload->>'ResultDesc', ''),
    nullif(p_status_payload->>'ResponseDescription', ''),
    'Status query processed'
  );
  v_payment_intent text;
  v_requested_advance_months integer;
  v_allocation_result jsonb;
  v_is_terminal_failure boolean := false;
begin
  if p_checkout_request_id is null or length(trim(p_checkout_request_id)) = 0 then
    raise exception 'checkoutRequestId is required';
  end if;

  select *
    into v_stk_request
  from app.mpesa_stk_requests stk
  where stk.checkout_request_id = trim(p_checkout_request_id)
  for update;

  if v_stk_request.id is null then
    raise exception 'No matching STK request found for CheckoutRequestID %', p_checkout_request_id;
  end if;

  select pr.id
    into v_existing_payment_record_id
  from app.payment_records pr
  where pr.deleted_at is null
    and pr.metadata->>'checkout_request_id' = trim(p_checkout_request_id)
  order by pr.created_at desc
  limit 1;

  if v_existing_payment_record_id is not null then
    update app.mpesa_stk_requests
       set status = 'success'::app.mpesa_stk_status_enum,
           result_code = nullif(v_result_code, ''),
           result_desc = v_result_desc,
           updated_at = now()
     where id = v_stk_request.id;

    return jsonb_build_object(
      'status', 'already_posted',
      'stk_request_id', v_stk_request.id,
      'payment_record_id', v_existing_payment_record_id
    );
  end if;

  if v_stk_request.status <> 'pending'::app.mpesa_stk_status_enum then
    return jsonb_build_object(
      'status', 'already_processed',
      'stk_request_id', v_stk_request.id,
      'processing_status', v_stk_request.status
    );
  end if;

  v_is_terminal_failure :=
    (
      nullif(v_result_code, '') is not null
      and v_result_code <> '0'
      and (
        v_result_code in ('1', '1032', '1037', '2001')
        or lower(v_result_desc) like '%cancel%'
        or lower(v_result_desc) like '%timeout%'
        or lower(v_result_desc) like '%declin%'
        or lower(v_result_desc) like '%failed%'
        or lower(v_result_desc) like '%insufficient%'
      )
    );

  if v_result_code = '0' then
    v_payment_intent := coalesce(v_stk_request.payment_context->>'payment_intent', 'charge_payment');
    v_requested_advance_months := nullif(
      v_stk_request.payment_context->>'requested_advance_months',
      ''
    )::integer;

    insert into app.payment_records (
      workspace_id,
      property_id,
      unit_id,
      collection_setup_id,
      recorded_status,
      record_source,
      payment_method_type,
      amount,
      currency_code,
      paid_at,
      payer_phone,
      reference_code,
      external_receipt_number,
      notes,
      metadata,
      recorded_by_user_id
    )
    select
      v_stk_request.workspace_id,
      v_stk_request.property_id,
      v_stk_request.unit_id,
      v_stk_request.payment_collection_setup_id,
      'recorded',
      'mobile_money_import',
      (
        select payment_method_type
        from app.payment_collection_setups
        where id = v_stk_request.payment_collection_setup_id
      ),
      v_stk_request.amount,
      'KES',
      now(),
      v_stk_request.phone_number,
      null,
      null,
      'Confirmed via STK status query before callback metadata was posted.',
      jsonb_build_object(
        'provider', 'mpesa_daraja',
        'checkout_request_id', trim(p_checkout_request_id),
        'stk_request_id', v_stk_request.id,
        'payment_intent', v_payment_intent,
        'requested_advance_months', v_requested_advance_months,
        'allocation_mode', case
          when v_stk_request.rent_charge_period_id is null then 'unapplied'
          else 'automatic'
        end,
        'settlement_source', 'stk_status_query',
        'status_query_payload', coalesce(p_status_payload, '{}'::jsonb)
      ),
      (
        select created_by_user_id
        from app.payment_collection_setups
        where id = v_stk_request.payment_collection_setup_id
      )
    returning id into v_payment_record_id;

    if v_stk_request.rent_charge_period_id is not null then
      insert into app.payment_allocations (
        workspace_id,
        property_id,
        unit_id,
        payment_record_id,
        rent_charge_period_id,
        allocation_source,
        allocated_amount,
        allocated_at,
        notes
      )
      values (
        v_stk_request.workspace_id,
        v_stk_request.property_id,
        v_stk_request.unit_id,
        v_payment_record_id,
        v_stk_request.rent_charge_period_id,
        'automatic'::app.payment_allocation_source_enum,
        v_stk_request.amount,
        now(),
        'Allocated after STK status query confirmation'
      );

      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
      perform app.refresh_rent_charge_period_payment_state(v_stk_request.rent_charge_period_id);
    else
      v_allocation_result := app.auto_allocate_payment_record_to_charge_periods(
        v_payment_record_id,
        true
      );
      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
    end if;

    update app.mpesa_stk_requests
       set status = 'success'::app.mpesa_stk_status_enum,
           result_code = '0',
           result_desc = v_result_desc,
           updated_at = now()
     where id = v_stk_request.id;

    return jsonb_build_object(
      'status', 'posted_from_status_query',
      'stk_request_id', v_stk_request.id,
      'payment_record_id', v_payment_record_id,
      'allocation_result', coalesce(v_allocation_result, '{}'::jsonb)
    );
  end if;

  if v_is_terminal_failure then
    update app.mpesa_stk_requests
       set status = 'failed'::app.mpesa_stk_status_enum,
           result_code = nullif(v_result_code, ''),
           result_desc = v_result_desc,
           updated_at = now()
     where id = v_stk_request.id;

    return jsonb_build_object(
      'status', 'failed_from_status_query',
      'stk_request_id', v_stk_request.id,
      'result_code', nullif(v_result_code, ''),
      'result_desc', v_result_desc
    );
  end if;

  update app.mpesa_stk_requests
     set result_code = nullif(v_result_code, ''),
         result_desc = v_result_desc,
         updated_at = now()
   where id = v_stk_request.id;

  return jsonb_build_object(
    'status', 'still_pending',
    'stk_request_id', v_stk_request.id,
    'result_code', nullif(v_result_code, ''),
    'result_desc', v_result_desc
  );
end;
$$;

revoke all on table app.mpesa_stk_callback_events from public, anon, authenticated;

revoke all on function app.process_mpesa_stk_callback_event(uuid)
  from public, anon, authenticated;
revoke all on function app.get_tenant_mpesa_payment_status(text)
  from public, anon, authenticated;
revoke all on function app.reconcile_mpesa_stk_request_from_status_query(text, jsonb)
  from public, anon, authenticated;

grant execute on function app.process_mpesa_stk_callback_event(uuid)
  to service_role;
grant execute on function app.get_tenant_mpesa_payment_status(text)
  to authenticated;
grant execute on function app.reconcile_mpesa_stk_request_from_status_query(text, jsonb)
  to service_role;

-- ----------------------------------------------------------------------------
-- Advance payment idempotency guarantees
-- ----------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 5. Update get_integration_health_registry to expose short_code and
--    account_reference_hint so the UI can display and edit payment credentials.
--    Must drop first because the return type (column list) is changing.
-- ---------------------------------------------------------------------------

drop function if exists app.get_integration_health_registry();

create or replace function app.get_integration_health_registry()
returns table (
  id                     uuid,
  scope_type             text,
  scope_name             text,
  method_type            text,
  short_code             text,
  account_reference_hint text,
  status                 text,
  last_verified          timestamptz,
  failure_reason         text
)
language sql
stable
security definer
set search_path = app, public
as $$
  -- 1. Workspace Level
  select
    s.id,
    'Portfolio' as scope_type,
    w.name as scope_name,
    s.payment_method_type::text as method_type,
    coalesce(s.paybill_number, s.till_number, s.send_money_phone_number) as short_code,
    s.account_reference_hint,
    case
      when s.lifecycle_status = 'draft'                            then 'pending'
      when (s.metadata->>'health_verified')::boolean = false       then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.workspaces w on w.id = s.workspace_id
  where s.scope_type = 'workspace'
    and s.deleted_at is null
    and s.lifecycle_status in ('active', 'draft')

  union all

  -- 2. Property Level
  select
    s.id,
    'Property' as scope_type,
    p.display_name as scope_name,
    s.payment_method_type::text as method_type,
    coalesce(s.paybill_number, s.till_number, s.send_money_phone_number) as short_code,
    s.account_reference_hint,
    case
      when s.lifecycle_status = 'draft'                            then 'pending'
      when (s.metadata->>'health_verified')::boolean = false       then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.properties p on p.id = s.property_id
  where s.scope_type = 'property'
    and s.deleted_at is null
    and s.lifecycle_status in ('active', 'draft')

  union all

  -- 3. Units that are NOT configured yet (to show gaps)
  select
    u.id,
    'Unit'          as scope_type,
    u.label         as scope_name,
    'None'          as method_type,
    null::text      as short_code,
    null::text      as account_reference_hint,
    'not_configured' as status,
    null::timestamptz as last_verified,
    'No direct or inherited setup found' as failure_reason
  from app.units u
  left join app.view_unit_payment_integration_health v on v.unit_id = u.id
  where v.effective_setup_id is null;
$$;

-- ----------------------------------------------------------------------------
-- Tenant advance eligibility in home summary
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

  v_advance_eligibility jsonb := null;
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

    -- Fetch advance payment eligibility (max 3 months). Wrapped in a sub-block
    -- so any unexpected error degrades gracefully rather than failing the whole
    -- home summary load.
    begin
      v_advance_eligibility := app.get_tenant_advance_payment_eligibility(
        v_residence.unit_id,
        3,
        v_user_id
      );
    exception when others then
      v_advance_eligibility := null;
    end;
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
        ),
        'advance_eligibility', v_advance_eligibility
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

-- ----------------------------------------------------------------------------
-- Unit registry visibility correction
-- ----------------------------------------------------------------------------

drop function if exists app.get_integration_health_registry();

create or replace function app.get_integration_health_registry()
returns table (
  id                     uuid,
  scope_type             text,
  scope_name             text,
  method_type            text,
  short_code             text,
  account_reference_hint text,
  status                 text,
  last_verified          timestamptz,
  failure_reason         text
)
language sql
stable
security definer
set search_path = app, public
as $$
  -- 1. Portfolio (workspace) level setups
  select
    s.id,
    'Portfolio'             as scope_type,
    w.name                  as scope_name,
    s.payment_method_type::text as method_type,
    coalesce(s.paybill_number, s.till_number, s.send_money_phone_number) as short_code,
    s.account_reference_hint,
    case
      when s.lifecycle_status = 'draft'                             then 'pending'
      when (s.metadata->>'health_verified')::boolean = false        then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.workspaces w on w.id = s.workspace_id
  where s.scope_type = 'workspace'
    and s.deleted_at is null
    and s.lifecycle_status in ('active', 'draft')

  union all

  -- 2. Property level setups
  select
    s.id,
    'Property'              as scope_type,
    p.display_name          as scope_name,
    s.payment_method_type::text as method_type,
    coalesce(s.paybill_number, s.till_number, s.send_money_phone_number) as short_code,
    s.account_reference_hint,
    case
      when s.lifecycle_status = 'draft'                             then 'pending'
      when (s.metadata->>'health_verified')::boolean = false        then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.properties p on p.id = s.property_id
  where s.scope_type = 'property'
    and s.deleted_at is null
    and s.lifecycle_status in ('active', 'draft')

  union all

  -- 3. All units — both configured (healthy/failed/pending) and unconfigured.
  --    view_unit_payment_integration_health resolves the effective setup for
  --    every unit via the Unit → Property → Workspace inheritance chain, so
  --    this is the single authoritative per-unit status.
  select
    v.unit_id                                                        as id,
    'Unit'                                                           as scope_type,
    v.unit_name                                                      as scope_name,
    case
      when v.effective_setup_id is null then 'None'
      else coalesce(v.payment_method_type::text, 'None')
    end                                                              as method_type,
    coalesce(v.paybill_number, v.till_number)                        as short_code,
    null::text                                                       as account_reference_hint,
    v.health_status::text                                            as status,
    v.last_verified_at                                               as last_verified,
    case
      when v.effective_setup_id is null then 'No direct or inherited setup found'
      else v.health_error
    end                                                              as failure_reason
  from app.view_unit_payment_integration_health v;
$$;

grant execute on function app.get_integration_health_registry() to authenticated;
