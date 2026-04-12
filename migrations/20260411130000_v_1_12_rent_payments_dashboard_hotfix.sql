-- ============================================================================
-- V 1 12: Rent Payments Dashboard Hotfix
-- ============================================================================
-- Purpose
--   - Fix aggregate grouping in app.get_rent_payments_dashboard
--   - Preserve the existing RPC contract used by the owner web dashboard
-- ============================================================================

create schema if not exists app;

create or replace function app.get_rent_payments_dashboard(
  p_property_id uuid default null,
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
    from app.get_rent_payment_charge_snapshot(p_property_id, v_reference_date)
  )
  select greatest(3, least(6, count(distinct billing_month)))::int
    into v_required_consistency_months
  from base
  where is_fully_paid
    and billing_month between v_trend_start and v_period_start;

  v_required_consistency_months := coalesce(v_required_consistency_months, 3);

  with base as (
    select *
    from app.get_rent_payment_charge_snapshot(p_property_id, v_reference_date)
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
    where due_on <= v_reference_date
       or is_fully_paid
       or is_overdue
  ),
  due_previous as (
    select *
    from previous_period
    where due_on <= v_previous_period_end
       or is_fully_paid
       or (outstanding_amount > 0 and due_on < v_previous_period_end)
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
        coalesce(sum(outstanding_amount) filter (where due_on >= v_reference_date), 0),
        2
      ) as outstanding_amount,
      round(
        case
          when coalesce(sum(scheduled_amount), 0) = 0 then 0
          else (
            coalesce(sum(outstanding_amount) filter (where due_on >= v_reference_date), 0)
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
    where base.due_on <= v_reference_date
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
