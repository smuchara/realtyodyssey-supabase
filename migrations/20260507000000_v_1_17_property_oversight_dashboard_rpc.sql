-- ============================================================================
-- V 1 17: Property Oversight Dashboard RPC
-- ============================================================================
-- Purpose
--   - Expose a single get_property_oversight_dashboard() RPC that powers the
--     top-level owner dashboard with all six KPIs in one round-trip.
--
-- KPIs:
--   1. Collection Efficiency  — previous month collected / due (0-100 score)
--   2. Occupancy Rate         — leased units / total units (0-100 score)
--   3. Tenant Satisfaction    — derived proxy score (on-time pay + maintenance + disputes)
--   4. Net Operating Income   — current month collected minus completed maintenance costs
--   5. Expected Revenue       — scheduled rent for current month
--   6. Revenue at Risk        — sum of overdue outstanding balances
--   7. Vacant Units           — count / total (for progress card)
-- ============================================================================

create schema if not exists app;

create or replace function app.get_property_oversight_dashboard()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  -- Date boundaries
  v_today             date := current_date;
  v_curr_period_start date := date_trunc('month', v_today)::date;
  v_prev_period_end   date := (v_curr_period_start - interval '1 day')::date;
  v_prev_period_start date := date_trunc('month', v_prev_period_end)::date;
  v_two_ago_end       date := (v_prev_period_start - interval '1 day')::date;
  v_two_ago_start     date := date_trunc('month', v_two_ago_end)::date;

  -- Workspace
  v_workspace_id uuid;

  -- Collection efficiency (previous month)
  v_coll_rate       numeric := 0;
  v_coll_rate_prev  numeric := 0;
  v_coll_trend      numeric := 0;

  -- Occupancy
  v_occ_dashboard   jsonb;
  v_occ_rate        numeric := 0;
  v_occ_rate_prev   numeric := 0;
  v_occ_trend       numeric := 0;
  v_total_units     int := 0;
  v_occupied_units  int := 0;
  v_vacant_units    int := 0;

  -- Tenant satisfaction
  v_on_time_rate            numeric := 0;
  v_maint_resolution_rate   numeric := 100;
  v_dispute_free_rate       numeric := 100;
  v_satisfaction_score      int := 0;

  -- Financial
  v_curr_collected        numeric := 0;
  v_curr_expected         numeric := 0;
  v_curr_overdue          numeric := 0;
  v_curr_overdue_units    int := 0;
  v_maint_cost_curr       numeric := 0;
  v_noi                   numeric := 0;
  v_risk_pct              numeric := 0;
  v_currency              text := 'KES';
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- ── Resolve workspace ─────────────────────────────────────────────────────
  select w.id into v_workspace_id
  from app.workspaces w
  where w.owner_user_id = auth.uid()
  limit 1;

  if v_workspace_id is null then
    select wm.workspace_id into v_workspace_id
    from app.workspace_memberships wm
    where wm.user_id = auth.uid()
      and wm.status = 'active'
    order by wm.created_at asc
    limit 1;
  end if;

  -- ── Collection Efficiency — previous month ────────────────────────────────
  -- Previous month: collected / scheduled for all due charges in that window
  select
    coalesce(
      round(
        least(100,
          sum(rcp.amount_paid)::numeric
          / nullif(sum(rcp.scheduled_amount), 0) * 100
        ), 1
      ), 0
    )
  into v_coll_rate
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_prev_period_start and v_prev_period_end;

  -- Month before last (for trend)
  select
    coalesce(
      round(
        least(100,
          sum(rcp.amount_paid)::numeric
          / nullif(sum(rcp.scheduled_amount), 0) * 100
        ), 1
      ), 0
    )
  into v_coll_rate_prev
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_two_ago_start and v_two_ago_end;

  v_coll_trend := round(v_coll_rate - v_coll_rate_prev, 0);

  -- ── Current month revenue ─────────────────────────────────────────────────
  select
    coalesce(round(sum(rcp.amount_paid), 2), 0),
    coalesce(round(sum(rcp.scheduled_amount), 2), 0),
    coalesce(max(rcp.currency_code), 'KES')
  into v_curr_collected, v_curr_expected, v_currency
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_curr_period_start
      and (v_curr_period_start + interval '1 month - 1 day')::date;

  -- Overdue amounts (past-due outstanding balances, any period)
  select
    coalesce(round(sum(rcp.outstanding_amount), 2), 0),
    count(distinct rcp.unit_id)::int
  into v_curr_overdue, v_curr_overdue_units
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status = 'overdue'
    and rcp.outstanding_amount > 0;

  -- ── Maintenance costs — completed tickets this month ─────────────────────
  if v_workspace_id is not null then
    select coalesce(round(sum(t.actual_cost), 2), 0)
    into v_maint_cost_curr
    from app.maintenance_tickets t
    where t.workspace_id = v_workspace_id
      and t.status in ('completed', 'verified')
      and t.actual_cost is not null
      and date_trunc('month', coalesce(t.completed_at, t.updated_at)) = v_curr_period_start;
  end if;

  v_noi := v_curr_collected - v_maint_cost_curr;

  -- Revenue at risk percentage of expected
  v_risk_pct := case
    when v_curr_expected = 0 then 0
    else round(v_curr_overdue / nullif(v_curr_expected, 0) * 100, 1)
  end;

  -- ── Occupancy ─────────────────────────────────────────────────────────────
  select app.get_units_occupancy_dashboard() into v_occ_dashboard;

  v_occ_rate       := coalesce((v_occ_dashboard -> 'summary' ->> 'occupancy_rate')::numeric, 0);
  v_total_units    := coalesce((v_occ_dashboard -> 'summary' ->> 'total_units')::int, 0);
  v_occupied_units := coalesce((v_occ_dashboard -> 'summary' ->> 'occupied_units')::int, 0);
  v_vacant_units   := coalesce((v_occ_dashboard -> 'summary' ->> 'vacant_units')::int, 0);

  -- Previous month occupancy: units with active charges last month / total units
  select
    case
      when v_total_units = 0 then 0
      else round(
        count(distinct rcp.unit_id)::numeric / v_total_units * 100, 1
      )
    end
  into v_occ_rate_prev
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_prev_period_start and v_prev_period_end;

  v_occ_trend := round(v_occ_rate - v_occ_rate_prev, 0);

  -- ── Tenant satisfaction (derived proxy) ──────────────────────────────────
  -- Proxy 1: on-time payment rate from prev month (40%)
  -- On-time = fully paid with full_collection_delay_days <= 0 (paid before/on grace deadline)
  -- due_on <= v_prev_period_end ensures the charge was already due (prev month always qualifies)
  select
    case
      when count(*) = 0 then 0
      else round(
        count(*) filter (
          where rcp.charge_status = 'paid'
            and coalesce(rcp.full_collection_delay_days, 0) <= 0
        )::numeric
        / count(*) * 100, 1
      )
    end
  into v_on_time_rate
  from app.rent_charge_periods rcp
  join app.get_financial_accessible_property_ids() ap on ap.property_id = rcp.property_id
  where rcp.deleted_at is null
    and rcp.charge_status <> 'cancelled'
    and rcp.billing_period_start between v_prev_period_start and v_prev_period_end;

  -- Proxy 2: maintenance resolution rate — completed / all tickets (35%)
  if v_workspace_id is not null then
    select
      case
        when count(*) = 0 then 100
        else round(
          count(*) filter (where t.status in ('completed', 'verified'))::numeric
          / count(*) * 100, 1
        )
      end
    into v_maint_resolution_rate
    from app.maintenance_tickets t
    where t.workspace_id = v_workspace_id;
  end if;

  -- Proxy 3: dispute-free rate — units not in disputed status (25%)
  if v_total_units > 0 then
    select
      round(
        100 - (
          count(*) filter (where uos.occupancy_status = 'disputed')::numeric
          / v_total_units * 100
        ), 1
      )
    into v_dispute_free_rate
    from app.unit_occupancy_snapshots uos
    join app.units u on u.id = uos.unit_id
    join app.get_financial_accessible_property_ids() ap on ap.property_id = u.property_id;
  end if;

  v_satisfaction_score := least(100, greatest(0,
    round(
      coalesce(v_on_time_rate, 0) * 0.40
      + coalesce(v_maint_resolution_rate, 100) * 0.35
      + coalesce(v_dispute_free_rate, 100) * 0.25
    )
  ))::int;

  -- ── Assemble and return ───────────────────────────────────────────────────
  return jsonb_build_object(
    'collection_efficiency', jsonb_build_object(
      'score',       round(v_coll_rate)::int,
      'trend',       v_coll_trend::int,
      'trend_label', 'Last month'
    ),
    'occupancy_rate', jsonb_build_object(
      'score',       round(v_occ_rate)::int,
      'trend',       v_occ_trend::int,
      'trend_label', 'Last month'
    ),
    'tenant_satisfaction', jsonb_build_object(
      'score',       v_satisfaction_score,
      'trend',       null,
      'trend_label', 'Last quarter'
    ),
    'net_operating_income', jsonb_build_object(
      'amount',        v_noi,
      'currency_code', v_currency
    ),
    'expected_revenue', jsonb_build_object(
      'amount',        v_curr_expected,
      'currency_code', v_currency
    ),
    'revenue_at_risk', jsonb_build_object(
      'amount',        v_curr_overdue,
      'percentage',    v_risk_pct,
      'units_affected', v_curr_overdue_units,
      'currency_code', v_currency
    ),
    'vacant_units', jsonb_build_object(
      'count',      v_vacant_units,
      'total',      v_total_units,
      'percentage', case
        when v_total_units = 0 then 0
        else round(v_vacant_units::numeric / v_total_units * 100, 1)
      end
    )
  );
end;
$$;

grant execute on function app.get_property_oversight_dashboard() to authenticated;
