-- ============================================================================
-- V 1 23: Tenant Intelligence Dashboard
-- ============================================================================
-- Purpose
--   - Introduce reliability scoring and risk derivation as reusable helpers
--   - Expose a property options RPC for the tenant directory filter bar
--   - Expose the primary directory RPC that drives the Tenant Intelligence
--     page — returning portfolio summary + per-tenant intelligence rows as
--     a single JSONB payload shaped for the owner web dashboard
--
-- Design notes
--   - All payment intelligence is derived entirely from existing tables:
--     rent_charge_periods, payment_records, lease_agreements,
--     unit_occupancy_snapshots.
--   - Maintenance and compliance notice counts are included as 0 placeholders;
--     they will be populated once those modules are added to the schema.
--   - Reliability score requires a minimum of 6 completed due-cycles before
--     it is considered eligible; below that threshold, a provisional tier is
--     returned with is_eligible = false.
--   - Access control mirrors the existing tenancy + financial management
--     patterns: callers must hold owner-level or tenancy-management access
--     on the relevant properties.
-- ============================================================================

create schema if not exists app;

-- ─── 1. Reliability Scoring Helper ───────────────────────────────────────────
-- Computes a 0-100 reliability score and tier from raw payment cycle counts.
-- IMMUTABLE: no side effects, no DB reads.

create or replace function app.compute_tenant_reliability_v1(
  p_total_due_cycles   int,
  p_on_time_cycles     int,
  p_late_cycles        int,
  p_partial_cycles     int,
  p_missed_cycles      int,
  p_avg_delay_days     numeric
)
returns jsonb
language plpgsql
immutable
security definer
set search_path = app, public
as $$
declare
  v_min_cycles constant int     := 6;
  v_score               numeric := 0;
  v_tier                text;
begin
  -- Below minimum — return provisional assessment without a numeric score
  if coalesce(p_total_due_cycles, 0) < v_min_cycles then
    return jsonb_build_object(
      'score',       null,
      'is_eligible', false,
      'tier', case
        when coalesce(p_missed_cycles, 0) >= 2          then 'High Risk'
        when coalesce(p_total_due_cycles, 0) = 0        then 'High Risk'
        when coalesce(p_on_time_cycles, 0)::numeric
             / nullif(p_total_due_cycles, 0) >= 0.8     then 'Stable'
        else 'Watchlist'
      end
    );
  end if;

  -- On-time component  — max 50 points
  v_score := v_score
    + (coalesce(p_on_time_cycles, 0)::numeric / p_total_due_cycles) * 50;

  -- Delay-quality component — max 30 points, tapers to 0 at 30+ avg days
  v_score := v_score
    + greatest(0, 1 - coalesce(p_avg_delay_days, 0) / 30.0) * 30;

  -- Completion component — max 20 points, penalised by missed cycles
  v_score := v_score
    + greatest(0,
        1 - coalesce(p_missed_cycles, 0)::numeric / nullif(p_total_due_cycles, 0)
      ) * 20;

  -- Soft partial-payment penalty
  v_score := v_score
    - (coalesce(p_partial_cycles, 0)::numeric / nullif(p_total_due_cycles, 0)) * 8;

  -- Clamp 0–100
  v_score := greatest(0, least(100, round(v_score)));

  v_tier := case
    when v_score >= 85 then 'Excellent'
    when v_score >= 68 then 'Stable'
    when v_score >= 45 then 'Watchlist'
    else 'High Risk'
  end;

  return jsonb_build_object(
    'score',       v_score::int,
    'tier',        v_tier,
    'is_eligible', true
  );
end;
$$;

-- ─── 2. Risk Level Derivation Helper ─────────────────────────────────────────
-- Maps reliability score + financial exposure to a four-level risk signal.
-- IMMUTABLE: pure function, no DB reads.

create or replace function app.derive_tenant_risk_level_v1(
  p_reliability_score    int,
  p_current_balance      numeric,
  p_rent_amount          numeric,
  p_missed_cycles        int,
  p_frontend_occupancy   text        -- 'overstayed' | 'notice_period' | 'active' | 'invited'
)
returns text
language plpgsql
immutable
security definer
set search_path = app, public
as $$
begin
  -- Overstayed lease is always Critical regardless of score
  if p_frontend_occupancy = 'overstayed' then
    return 'Critical';
  end if;

  -- Critical: very low score, or balance > 2× rent, or 2+ missed payments
  if coalesce(p_reliability_score, 0) < 30
     or coalesce(p_current_balance, 0) > coalesce(p_rent_amount, 0) * 2
     or coalesce(p_missed_cycles, 0) >= 2
  then
    return 'Critical';
  end if;

  -- High: low score, or balance > 1× rent
  if coalesce(p_reliability_score, 0) < 50
     or coalesce(p_current_balance, 0) > coalesce(p_rent_amount, 0)
  then
    return 'High';
  end if;

  -- Medium: mid score, or any outstanding balance
  if coalesce(p_reliability_score, 0) < 70
     or coalesce(p_current_balance, 0) > 0
  then
    return 'Medium';
  end if;

  return 'Low';
end;
$$;

-- ─── 3. Property Options (filter bar) ────────────────────────────────────────
-- Returns the properties that have at least one occupied/invited unit,
-- filtered to those the caller can manage tenancy for.

create or replace function app.get_tenant_intelligence_property_options()
returns table (
  property_id        uuid,
  property_name      text,
  city_town          text,
  area_neighborhood  text,
  occupied_count     bigint,
  unit_count         bigint
)
language sql
stable
security definer
set search_path = app, public
as $$
  select
    p.id                  as property_id,
    p.display_name        as property_name,
    p.city_town,
    p.area_neighborhood,
    count(uos.unit_id) filter (
      where uos.occupancy_status in (
        'occupied'::app.unit_occupancy_status_enum,
        'pending_confirmation'::app.unit_occupancy_status_enum,
        'invited'::app.unit_occupancy_status_enum
      )
    )                     as occupied_count,
    count(uos.unit_id)    as unit_count
  from app.properties p
  join app.unit_occupancy_snapshots uos on uos.property_id = p.id
  where p.deleted_at is null
    and p.status = 'active'
    and app.has_tenancy_management_access(p.id)
  group by p.id, p.display_name, p.city_town, p.area_neighborhood
  having count(uos.unit_id) filter (
    where uos.occupancy_status in (
      'occupied'::app.unit_occupancy_status_enum,
      'pending_confirmation'::app.unit_occupancy_status_enum,
      'invited'::app.unit_occupancy_status_enum
    )
  ) > 0
  order by p.display_name;
$$;

-- ─── 4. Main Directory RPC ────────────────────────────────────────────────────
-- Returns the full tenant intelligence payload as a JSONB document:
--   { summary: {...}, tenants: [...], generated_at: "..." }
--
-- Access: caller must have tenancy management access on the relevant properties.
-- p_property_id = null means all accessible properties.

create or replace function app.get_tenant_intelligence_directory_v1(
  p_property_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_result jsonb;
begin
  with

  -- Tenancy-accessible property scope
  accessible_props as (
    select t.property_id
    from app.get_tenancy_accessible_property_ids(p_property_id) t
  ),

  -- Occupied/invited units that have an active current lease
  tenant_units as (
    select
      uos.unit_id,
      uos.property_id,
      uos.occupancy_status::text                                as occupancy_status,
      uos.current_lease_agreement_id                            as lease_id,
      uos.current_tenant_user_id,
      coalesce(uos.current_tenant_name, '—')                   as tenant_name,
      uos.current_tenant_phone                                  as tenant_phone,
      coalesce(uos.occupancy_started_at::date, la.start_date)  as move_in_date,
      coalesce(u.label, '—')                                    as unit_label,
      p.display_name                                            as property_name,
      la.lease_type::text                                       as lease_type,
      la.start_date                                             as lease_start_date,
      la.end_date                                               as lease_end_date,
      la.rent_amount,
      la.currency_code,
      la.status::text                                           as lease_status,
      coalesce(la.collection_grace_period_days, 5)             as grace_days
    from app.unit_occupancy_snapshots uos
    join accessible_props             ap  on ap.property_id  = uos.property_id
    join app.units                    u   on u.id             = uos.unit_id
                                        and u.deleted_at     is null
    join app.properties               p   on p.id             = uos.property_id
    join app.lease_agreements         la  on la.id            = uos.current_lease_agreement_id
    where uos.occupancy_status in (
      'occupied'::app.unit_occupancy_status_enum,
      'pending_confirmation'::app.unit_occupancy_status_enum,
      'invited'::app.unit_occupancy_status_enum
    )
    and uos.current_lease_agreement_id is not null
  ),

  -- Aggregated payment stats per lease (from rent_charge_periods)
  pay_agg as (
    select
      rcp.lease_agreement_id                                              as lease_id,
      count(*) filter (
        where rcp.charge_status in ('paid', 'partially_paid', 'overdue')
      )::int                                                              as total_due_cycles,
      count(*) filter (
        where rcp.charge_status = 'paid'
          and coalesce(rcp.full_collection_delay_days, 0) <= tu.grace_days
      )::int                                                              as on_time_cycles,
      count(*) filter (
        where rcp.charge_status = 'paid'
          and rcp.full_collection_delay_days > tu.grace_days
      )::int                                                              as late_cycles,
      count(*) filter (
        where rcp.charge_status = 'partially_paid'
      )::int                                                              as partial_cycles,
      count(*) filter (
        where rcp.charge_status = 'overdue'
      )::int                                                              as missed_cycles,
      coalesce(
        round(avg(rcp.full_collection_delay_days) filter (
          where rcp.charge_status = 'paid'
            and rcp.full_collection_delay_days > 0
        ))::int,
        0
      )                                                                   as avg_delay_days,
      coalesce(
        sum(rcp.scheduled_amount) filter (
          where rcp.charge_status != 'cancelled'
        ), 0
      )                                                                   as total_billed,
      coalesce(
        sum(rcp.amount_paid) filter (
          where rcp.charge_status != 'cancelled'
        ), 0
      )                                                                   as total_paid,
      -- Outstanding: overdue + partial + scheduled-but-now-due
      coalesce(
        sum(rcp.outstanding_amount) filter (
          where rcp.charge_status in ('overdue', 'partially_paid')
             or (rcp.charge_status = 'scheduled' and rcp.due_on <= current_date)
        ), 0
      )                                                                   as current_balance,
      max(rcp.last_payment_at)                                            as last_payment_at
    from app.rent_charge_periods rcp
    join tenant_units tu on tu.lease_id = rcp.lease_agreement_id
    where rcp.deleted_at is null
    group by rcp.lease_agreement_id, tu.grace_days
  ),

  -- Most recent completed period (for last-payment status display)
  last_period as (
    select distinct on (rcp.lease_agreement_id)
      rcp.lease_agreement_id  as lease_id,
      case
        when rcp.charge_status = 'paid'
          and rcp.fully_paid_at is not null
          and rcp.fully_paid_at < rcp.due_on::timestamptz
          then 'advance'
        when rcp.charge_status = 'paid'
          and coalesce(rcp.full_collection_delay_days, 0) <= tu.grace_days
          then 'on_time'
        when rcp.charge_status = 'paid'
          then 'late'
        when rcp.charge_status = 'partially_paid'
          then 'partial'
        else 'missed'
      end                     as last_payment_status,
      rcp.amount_paid         as last_payment_amount,
      coalesce(rcp.last_payment_at, rcp.fully_paid_at) as last_payment_date
    from app.rent_charge_periods rcp
    join tenant_units tu on tu.lease_id = rcp.lease_agreement_id
    where rcp.deleted_at is null
      and rcp.charge_status  != 'cancelled'
      and rcp.billing_period_start <= current_date
    order by rcp.lease_agreement_id, rcp.billing_period_start desc
  ),

  -- Tenant emails from profiles (only for users who have signed up)
  tenant_emails as (
    select pr.id as user_id, pr.email
    from app.profiles pr
    where pr.id in (
      select distinct tu.current_tenant_user_id
      from tenant_units tu
      where tu.current_tenant_user_id is not null
    )
  ),

  -- Combined per-tenant dataset with computed reliability + occupancy mapping
  tenant_data as (
    select
      tu.lease_id,
      tu.unit_id,
      tu.property_id,
      tu.occupancy_status,
      tu.move_in_date,
      tu.unit_label,
      tu.property_name,
      tu.lease_type,
      tu.lease_start_date,
      tu.lease_end_date,
      tu.rent_amount,
      tu.currency_code,
      tu.lease_status,
      tu.grace_days,
      tu.tenant_name,
      tu.tenant_phone,
      tu.current_tenant_user_id,
      te.email                                                   as tenant_email,
      coalesce(pa.total_due_cycles, 0)                           as total_due_cycles,
      coalesce(pa.on_time_cycles,   0)                           as on_time_cycles,
      coalesce(pa.late_cycles,      0)                           as late_cycles,
      coalesce(pa.partial_cycles,   0)                           as partial_cycles,
      coalesce(pa.missed_cycles,    0)                           as missed_cycles,
      coalesce(pa.avg_delay_days,   0)                           as avg_delay_days,
      coalesce(pa.total_billed,     0)                           as total_billed,
      coalesce(pa.total_paid,       0)                           as total_paid,
      coalesce(pa.current_balance,  0)                           as current_balance,
      coalesce(lp.last_payment_status, 'missed')                 as last_payment_status,
      lp.last_payment_amount,
      lp.last_payment_date,
      -- On-time rate (100 if no due cycles yet)
      case
        when coalesce(pa.total_due_cycles, 0) = 0 then 100
        else round(
          coalesce(pa.on_time_cycles, 0)::numeric
          / pa.total_due_cycles * 100
        )::int
      end                                                        as on_time_rate,
      -- Reliability JSONB
      app.compute_tenant_reliability_v1(
        coalesce(pa.total_due_cycles, 0),
        coalesce(pa.on_time_cycles,   0),
        coalesce(pa.late_cycles,      0),
        coalesce(pa.partial_cycles,   0),
        coalesce(pa.missed_cycles,    0),
        coalesce(pa.avg_delay_days,   0)
      )                                                          as reliability,
      -- Frontend-facing occupancy status
      case
        when tu.lease_status = 'overstayed'                                    then 'overstayed'
        when tu.lease_status in ('expired', 'terminated_early')                then 'notice_period'
        when tu.occupancy_status in ('invited', 'pending_confirmation')        then 'invited'
        else 'active'
      end                                                        as frontend_occupancy_status,
      -- Tenure in whole months
      (
        extract(year  from age(current_date, tu.lease_start_date)) * 12
        + extract(month from age(current_date, tu.lease_start_date))
      )::int                                                     as tenure_months
    from tenant_units    tu
    left join pay_agg    pa on pa.lease_id = tu.lease_id
    left join last_period lp on lp.lease_id = tu.lease_id
    left join tenant_emails te on te.user_id = tu.current_tenant_user_id
  )

  -- ─── Final JSON assembly ───────────────────────────────────────────────────
  select jsonb_build_object(

    'generated_at', now()::text,

    -- Portfolio summary (aggregate across all tenant rows)
    'summary', (
      select jsonb_build_object(
        'total_active_tenants',      count(*)::int,
        'reliable_tenants',          count(*) filter (
                                       where (td.reliability->>'tier') in ('Excellent','Stable')
                                     )::int,
        'watchlist_tenants',         count(*) filter (
                                       where (td.reliability->>'tier') = 'Watchlist'
                                     )::int,
        'high_risk_tenants',         count(*) filter (
                                       where app.derive_tenant_risk_level_v1(
                                         (td.reliability->>'score')::int,
                                         td.current_balance,
                                         td.rent_amount,
                                         td.missed_cycles,
                                         td.frontend_occupancy_status
                                       ) in ('High','Critical')
                                     )::int,
        'total_outstanding_balance', coalesce(sum(td.current_balance), 0),
        'portfolio_on_time_rate',    case
                                       when sum(td.total_due_cycles) = 0 then 100
                                       else round(
                                         sum(td.on_time_cycles)::numeric
                                         / sum(td.total_due_cycles) * 100
                                       )::int
                                     end,
        'currency_code',             coalesce(max(td.currency_code), 'KES'),
        'on_time_rate_trend',        0,   -- reserved for trend comparison
        'tenant_count_change',       0    -- reserved for period-over-period delta
      )
      from tenant_data td
    ),

    -- Per-tenant intelligence rows
    'tenants', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id',                      td.lease_id::text,
            'name',                    td.tenant_name,
            'email',                   td.tenant_email,
            'phone',                   td.tenant_phone,
            'unit_label',              td.unit_label,
            'property_name',           td.property_name,
            'occupancy_status',        td.frontend_occupancy_status,
            'lease_type',              td.lease_type,
            'lease_start_date',        td.lease_start_date::text,
            'lease_end_date',          td.lease_end_date::text,
            'move_in_date',            td.move_in_date::text,
            'rent_amount',             td.rent_amount,
            'currency_code',           td.currency_code,
            'reliability_score',       (td.reliability->>'score')::int,
            'reliability_tier',         td.reliability->>'tier',
            'risk_level',              app.derive_tenant_risk_level_v1(
                                         (td.reliability->>'score')::int,
                                         td.current_balance,
                                         td.rent_amount,
                                         td.missed_cycles,
                                         td.frontend_occupancy_status
                                       ),
            'current_balance',         td.current_balance,
            'total_billed',            td.total_billed,
            'total_paid',              td.total_paid,
            'last_payment_date',       case when td.last_payment_date is not null
                                         then td.last_payment_date::date::text
                                         else null
                                       end,
            'last_payment_status',     td.last_payment_status,
            'last_payment_amount',     td.last_payment_amount,
            'on_time_rate',            td.on_time_rate,
            'late_payment_count',      td.late_cycles,
            'partial_payment_count',   td.partial_cycles,
            'missed_payment_count',    td.missed_cycles,
            'avg_payment_delay_days',  td.avg_delay_days,
            -- Placeholders — maintenance + notice modules not yet implemented
            'maintenance_request_count', 0,
            'open_maintenance_count',    0,
            'notice_count',              0,
            'unresolved_notice_count',   0,

            -- Computed flags
            'flags', (
              select coalesce(jsonb_agg(f), '[]'::jsonb)
              from (
                select jsonb_build_object(
                  'type',     'excellent_payer',
                  'label',    case when td.last_payment_status = 'advance'
                                then 'Advance Payer' else 'Excellent Payer'
                              end,
                  'severity', 'success'
                ) as f
                where td.on_time_rate >= 90
                  and td.current_balance = 0
                  and td.total_due_cycles >= 3

                union all

                select jsonb_build_object(
                  'type',     'renewal_candidate',
                  'label',    'Renewal Candidate',
                  'severity', 'success'
                )
                where td.on_time_rate >= 82
                  and td.current_balance = 0
                  and (
                    (
                      td.lease_end_date is not null
                      and td.lease_end_date between current_date
                                                and current_date + interval '180 days'
                    )
                    or td.tenure_months >= 18
                  )

                union all

                select jsonb_build_object(
                  'type',     'late_payment',
                  'label',    'Repeated Late Payment',
                  'severity', 'warning'
                )
                where td.late_cycles >= 4

                union all

                select jsonb_build_object(
                  'type',     'arrears',
                  'label',    case when td.current_balance > td.rent_amount
                                then 'High Arrears' else 'Current Arrears'
                              end,
                  'severity', case when td.current_balance > td.rent_amount
                                then 'risk' else 'warning'
                              end
                )
                where td.current_balance > 0

                union all

                select jsonb_build_object(
                  'type',     'lease_expiring',
                  'label',    case when td.lease_end_date < current_date
                                then 'Lease Expired' else 'Lease Expiring Soon'
                              end,
                  'severity', 'warning'
                )
                where td.lease_end_date is not null
                  and td.lease_end_date between current_date - interval '30 days'
                                            and current_date + interval '90 days'
              ) flag_src(f)
            ),

            -- Payment history: last 12 billing periods (desc)
            'payment_history', (
              select coalesce(jsonb_agg(
                jsonb_build_object(
                  'period',     to_char(rcp.billing_period_start, 'Mon YYYY'),
                  'due_date',   rcp.due_on::text,
                  'paid_date',  case when rcp.fully_paid_at is not null
                                  then rcp.fully_paid_at::date::text else null
                                end,
                  'amount',     rcp.scheduled_amount,
                  'amount_paid', rcp.amount_paid,
                  'status', case
                    when rcp.charge_status = 'paid'
                      and rcp.fully_paid_at is not null
                      and rcp.fully_paid_at < rcp.due_on::timestamptz
                      then 'advance'
                    when rcp.charge_status = 'paid'
                      and coalesce(rcp.full_collection_delay_days, 0) <= td.grace_days
                      then 'on_time'
                    when rcp.charge_status = 'paid'
                      then 'late'
                    when rcp.charge_status = 'partially_paid'
                      then 'partial'
                    else 'missed'
                  end,
                  'delay_days', rcp.full_collection_delay_days
                )
                order by rcp.billing_period_start desc
              ), '[]'::jsonb)
              from (
                select * from app.rent_charge_periods rcp_i
                where rcp_i.lease_agreement_id = td.lease_id
                  and rcp_i.deleted_at          is null
                  and rcp_i.charge_status       != 'cancelled'
                  and rcp_i.billing_period_start <= current_date
                order by rcp_i.billing_period_start desc
                limit 12
              ) rcp
            ),

            -- Recent activity: last 6 payment records + lease-start event
            'recent_activity', (
              select coalesce(
                jsonb_build_array(
                  jsonb_build_object(
                    'id',          td.lease_id::text || '_lease_start',
                    'type',        'lease',
                    'title',       'Lease activated',
                    'description', initcap(replace(td.lease_type, '_', '-')) || ' lease confirmed',
                    'date',        td.lease_start_date::text,
                    'status',      'positive'
                  )
                )
                || coalesce(
                  (
                    select jsonb_agg(
                      jsonb_build_object(
                        'id',          pr.id::text,
                        'type',        'payment',
                        'title',       case
                                         when pr.allocation_status = 'fully_applied'::app.payment_allocation_status_enum
                                           then 'Payment received'
                                         when pr.allocation_status = 'partially_applied'::app.payment_allocation_status_enum
                                           then 'Partial payment received'
                                         else 'Payment recorded'
                                       end,
                        'description', td.currency_code || ' '
                                       || to_char(pr.amount, 'FM999,999,999')
                                       || ' received',
                        'date',        pr.paid_at::date::text,
                        'status',      case
                                         when pr.allocation_status = 'fully_applied'::app.payment_allocation_status_enum
                                           then 'positive'
                                         else 'neutral'
                                       end
                      )
                      order by pr.paid_at desc
                    )
                    from (
                      select * from app.payment_records pr_i
                      where pr_i.lease_agreement_id = td.lease_id
                        and pr_i.deleted_at          is null
                        and pr_i.recorded_status      = 'recorded'::app.payment_record_status_enum
                      order by pr_i.paid_at desc
                      limit 6
                    ) pr
                  ),
                  '[]'::jsonb
                ),
                '[]'::jsonb
              )
            ),

            -- Decision-support recommendation
            'recommendation', case
              when app.derive_tenant_risk_level_v1(
                     (td.reliability->>'score')::int,
                     td.current_balance, td.rent_amount,
                     td.missed_cycles, td.frontend_occupancy_status
                   ) = 'Critical'
                then 'Outstanding ' || td.currency_code || ' '
                     || to_char(td.current_balance, 'FM999,999,999')
                     || '. Immediate recovery action required. Formal notice may be necessary.'
              when app.derive_tenant_risk_level_v1(
                     (td.reliability->>'score')::int,
                     td.current_balance, td.rent_amount,
                     td.missed_cycles, td.frontend_occupancy_status
                   ) = 'High'
                then 'Escalating arrears — ' || td.currency_code || ' '
                     || to_char(td.current_balance, 'FM999,999,999')
                     || ' outstanding. Formal demand letter recommended.'
              when td.frontend_occupancy_status in ('overstayed','notice_period')
                then 'Lease has expired. Renewal or vacate decision required urgently.'
              when (td.reliability->>'tier') = 'Watchlist'
                then 'Monitor closely — ' || td.late_cycles::text
                     || ' late payment' || case when td.late_cycles = 1 then '' else 's' end
                     || ' recorded. Consider payment plan discussion before escalating.'
              when (td.reliability->>'tier') = 'Excellent' and td.tenure_months >= 24
                then 'Exemplary ' || td.tenure_months::text
                     || '-month tenant with outstanding reliability. Prioritize renewal.'
              when (td.reliability->>'tier') = 'Excellent'
                then 'Excellent payment record. Tenant in strong standing.'
              when (td.reliability->>'is_eligible')::boolean = false
                then 'Insufficient history for a full reliability score. Continue monitoring.'
              else 'Stable tenant. No immediate action required.'
            end,

            'recommendation_type', case
              when app.derive_tenant_risk_level_v1(
                     (td.reliability->>'score')::int,
                     td.current_balance, td.rent_amount,
                     td.missed_cycles, td.frontend_occupancy_status
                   ) in ('Critical','High')
                then 'critical'
              when app.derive_tenant_risk_level_v1(
                     (td.reliability->>'score')::int,
                     td.current_balance, td.rent_amount,
                     td.missed_cycles, td.frontend_occupancy_status
                   ) = 'Medium'
                  or (td.reliability->>'tier') = 'Watchlist'
                then 'warning'
              when (td.reliability->>'tier') = 'Excellent'
                then 'positive'
              else 'neutral'
            end
          )

          -- Default sort: Critical first, then by balance desc, then name
          order by
            case app.derive_tenant_risk_level_v1(
              (td.reliability->>'score')::int, td.current_balance, td.rent_amount,
              td.missed_cycles, td.frontend_occupancy_status
            )
              when 'Critical' then 1
              when 'High'     then 2
              when 'Medium'   then 3
              else                 4
            end,
            td.current_balance desc nulls last,
            td.tenant_name     asc  nulls last
        )
        from tenant_data td
      ),
      '[]'::jsonb
    )

  ) into v_result;

  return v_result;
end;
$$;

-- ─── 5. Grants ────────────────────────────────────────────────────────────────

revoke all on function app.compute_tenant_reliability_v1(int, int, int, int, int, numeric)
  from public, anon, authenticated;

revoke all on function app.derive_tenant_risk_level_v1(int, numeric, numeric, int, text)
  from public, anon, authenticated;

revoke all on function app.get_tenant_intelligence_property_options()
  from public, anon, authenticated;

revoke all on function app.get_tenant_intelligence_directory_v1(uuid)
  from public, anon, authenticated;

grant execute on function app.compute_tenant_reliability_v1(int, int, int, int, int, numeric)
  to authenticated;

grant execute on function app.derive_tenant_risk_level_v1(int, numeric, numeric, int, text)
  to authenticated;

grant execute on function app.get_tenant_intelligence_property_options()
  to authenticated;

grant execute on function app.get_tenant_intelligence_directory_v1(uuid)
  to authenticated;
