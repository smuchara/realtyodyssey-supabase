-- ============================================================================
-- V 1 24: Properties Table Data RPC
-- ============================================================================
-- Purpose
--   - Expose get_properties_table_data() for the "My Properties" table.
--   - Returns per-property metrics: occupancy, NOI (current + previous month),
--     overdue amounts, and alert signals for the insights strip.
--   - NOI = sum(amount_paid) - sum(maintenance actual_cost) for the period.
--     For BUILDING properties this aggregates across all child units.
--   - Raw numbers are returned; trend and risk are derived in the app layer.
-- ============================================================================

create schema if not exists app;

create or replace function app.get_properties_table_data()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_today          date := current_date;
  v_curr_start     date := date_trunc('month', v_today)::date;
  v_curr_end       date := (v_curr_start + interval '1 month - 1 day')::date;
  v_prev_end       date := (v_curr_start - interval '1 day')::date;
  v_prev_start     date := date_trunc('month', v_prev_end)::date;
  v_two_ago_end    date := (v_prev_start - interval '1 day')::date;
  v_two_ago_start  date := date_trunc('month', v_two_ago_end)::date;

  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  with
  -- ── Properties accessible to the caller ───────────────────────────────────
  accessible as (
    select property_id from app.get_financial_accessible_property_ids()
  ),

  -- ── Property rows with type code ──────────────────────────────────────────
  props as (
    select
      p.id,
      p.display_name,
      p.internal_ref_code,
      upper(p.status::text)                        as status,
      coalesce(p.area_neighborhood, '')            as area,
      coalesce(p.city_town, '')                    as city,
      pt.code                                      as type_code
    from app.properties p
    join app.lookup_property_types pt on pt.id = p.property_type_id
    where p.deleted_at is null
      and p.id in (select property_id from accessible)
  ),

  -- ── Unit counts per property ───────────────────────────────────────────────
  unit_totals as (
    select
      u.property_id,
      count(*)::int as total_units
    from app.units u
    where u.deleted_at is null
      and u.property_id in (select property_id from accessible)
    group by u.property_id
  ),

  -- ── Occupied units per property (from latest occupancy snapshot) ──────────
  occupied_counts as (
    select
      u.property_id,
      count(*)::int as occupied_count
    from app.unit_occupancy_snapshots uos
    join app.units u on u.id = uos.unit_id
    where uos.occupancy_status = 'occupied'
      and u.deleted_at is null
      and u.property_id in (select property_id from accessible)
    group by u.property_id
  ),

  -- ── Current-month rent collected + scheduled per property ─────────────────
  curr_rev as (
    select
      rcp.property_id,
      coalesce(sum(rcp.amount_paid), 0)       as collected,
      coalesce(sum(rcp.scheduled_amount), 0)  as scheduled
    from app.rent_charge_periods rcp
    where rcp.deleted_at is null
      and rcp.charge_status <> 'cancelled'
      and rcp.billing_period_start between v_curr_start and v_curr_end
      and rcp.property_id in (select property_id from accessible)
    group by rcp.property_id
  ),

  -- ── Previous-month rent collected per property ────────────────────────────
  prev_rev as (
    select
      rcp.property_id,
      coalesce(sum(rcp.amount_paid), 0) as collected
    from app.rent_charge_periods rcp
    where rcp.deleted_at is null
      and rcp.charge_status <> 'cancelled'
      and rcp.billing_period_start between v_prev_start and v_prev_end
      and rcp.property_id in (select property_id from accessible)
    group by rcp.property_id
  ),

  -- ── Current-month maintenance cost per property ───────────────────────────
  curr_maint as (
    select
      mt.property_id,
      coalesce(sum(mt.actual_cost), 0) as cost
    from app.maintenance_tickets mt
    where mt.status in ('completed', 'verified')
      and mt.actual_cost is not null
      and date_trunc('month', coalesce(mt.completed_at, mt.updated_at))::date = v_curr_start
      and mt.property_id in (select property_id from accessible)
    group by mt.property_id
  ),

  -- ── Previous-month maintenance cost per property ──────────────────────────
  prev_maint as (
    select
      mt.property_id,
      coalesce(sum(mt.actual_cost), 0) as cost
    from app.maintenance_tickets mt
    where mt.status in ('completed', 'verified')
      and mt.actual_cost is not null
      and date_trunc('month', coalesce(mt.completed_at, mt.updated_at))::date = v_prev_start
      and mt.property_id in (select property_id from accessible)
    group by mt.property_id
  ),

  -- ── Overdue outstanding per property ─────────────────────────────────────
  overdue_amounts as (
    select
      rcp.property_id,
      coalesce(sum(rcp.outstanding_amount), 0) as overdue_amount
    from app.rent_charge_periods rcp
    where rcp.deleted_at is null
      and rcp.charge_status = 'overdue'
      and rcp.outstanding_amount > 0
      and rcp.property_id in (select property_id from accessible)
    group by rcp.property_id
  ),

  -- ── Portfolio-wide alert signals ──────────────────────────────────────────

  -- Active leases expiring within 45 days
  expiring_leases as (
    select count(*)::int as cnt
    from app.lease_agreements la
    where la.status = 'active'
      and la.end_date is not null
      and la.end_date between v_today and (v_today + interval '45 days')::date
      and la.property_id in (select property_id from accessible)
  ),

  -- Previous-month portfolio collection rate
  coll_prev as (
    select
      coalesce(
        round(
          least(100,
            sum(rcp.amount_paid)::numeric
            / nullif(sum(rcp.scheduled_amount), 0) * 100
          ), 1
        ), 0
      ) as rate
    from app.rent_charge_periods rcp
    where rcp.deleted_at is null
      and rcp.charge_status <> 'cancelled'
      and rcp.billing_period_start between v_prev_start and v_prev_end
      and rcp.property_id in (select property_id from accessible)
  ),

  -- Two-months-ago portfolio collection rate (for trend comparison)
  coll_two_ago as (
    select
      coalesce(
        round(
          least(100,
            sum(rcp.amount_paid)::numeric
            / nullif(sum(rcp.scheduled_amount), 0) * 100
          ), 1
        ), 0
      ) as rate
    from app.rent_charge_periods rcp
    where rcp.deleted_at is null
      and rcp.charge_status <> 'cancelled'
      and rcp.billing_period_start between v_two_ago_start and v_two_ago_end
      and rcp.property_id in (select property_id from accessible)
  ),

  -- Property with the largest maintenance cost spike month-over-month
  maint_spike as (
    select
      p.display_name as property_name,
      coalesce(cm.cost, 0)                          as curr_cost,
      coalesce(pm.cost, 0)                          as prev_cost,
      case
        when coalesce(pm.cost, 0) = 0 then null
        else round(
          (coalesce(cm.cost, 0) - coalesce(pm.cost, 0))
          / coalesce(pm.cost, 0) * 100, 0
        )
      end as pct_change
    from props p
    left join curr_maint cm on cm.property_id = p.id
    left join prev_maint pm on pm.property_id = p.id
    where coalesce(pm.cost, 0) > 0
      and coalesce(cm.cost, 0) > coalesce(pm.cost, 0)
    order by pct_change desc nulls last
    limit 1
  )

  -- ── Final assembly ─────────────────────────────────────────────────────────
  select jsonb_build_object(
    'properties', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id',              p.id,
            'name',            p.display_name,
            'typeCode',        p.type_code,
            'status',          p.status,
            'internalRef',     p.internal_ref_code,
            'area',            p.area,
            'city',            p.city,
            'totalUnits',      coalesce(ut.total_units, 0),
            'occupiedUnits',   coalesce(oc.occupied_count, 0),
            'occupancyRate',   case
                                 when coalesce(ut.total_units, 0) = 0 then 0
                                 else round(
                                   coalesce(oc.occupied_count, 0)::numeric
                                   / ut.total_units * 100, 1
                                 )
                               end,
            'noiCurr',         round(coalesce(cr.collected, 0) - coalesce(cm.cost, 0), 2),
            'noiPrev',         round(coalesce(pr.collected, 0) - coalesce(pm.cost, 0), 2),
            'overdueAmount',   coalesce(ov.overdue_amount, 0),
            'scheduledAmount', coalesce(cr.scheduled, 0)
          )
        )
        from props p
        left join unit_totals     ut on ut.property_id  = p.id
        left join occupied_counts oc on oc.property_id  = p.id
        left join curr_rev        cr on cr.property_id  = p.id
        left join prev_rev        pr on pr.property_id  = p.id
        left join curr_maint      cm on cm.property_id  = p.id
        left join prev_maint      pm on pm.property_id  = p.id
        left join overdue_amounts ov on ov.property_id  = p.id
      ),
      '[]'::jsonb
    ),
    'alerts', jsonb_build_object(
      'collectionRatePrev',   (select rate from coll_prev),
      'collectionRateTwoAgo', (select rate from coll_two_ago),
      'expiringLeases',       (select cnt  from expiring_leases),
      'maintSpikeProperty',   (select property_name from maint_spike),
      'maintSpikePct',        (select pct_change    from maint_spike)
    )
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function app.get_properties_table_data() to authenticated;
