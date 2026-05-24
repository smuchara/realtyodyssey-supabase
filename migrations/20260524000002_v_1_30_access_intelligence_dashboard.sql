-- ============================================================================
-- V1.30: Access & Entry Management Intelligence Dashboard
-- ============================================================================
-- Aggregation RPCs for the PMC admin security intelligence dashboard.
-- All RPCs: security definer, scoped to auth.uid() as pmc_company_id,
-- restricted to property_management_company accounts.
-- ============================================================================

-- ── Helper: verify caller is a PMC admin ─────────────────────────────────────
-- Used inline in each RPC via a SELECT check.

-- ── 1. Overview Metrics ───────────────────────────────────────────────────────

create or replace function app.get_access_dashboard_overview()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id              uuid := auth.uid();
  v_account_type        text;
  v_today               timestamptz := date_trunc('day', now());
  v_yesterday           timestamptz := date_trunc('day', now()) - interval '1 day';
  v_week_ago            timestamptz := date_trunc('day', now()) - interval '6 days';
  v_entries_today       bigint := 0;
  v_entries_yesterday   bigint := 0;
  v_exits_today         bigint := 0;
  v_exits_yesterday     bigint := 0;
  v_failed_today        bigint := 0;
  v_failed_yesterday    bigint := 0;
  v_residents_inside    bigint := 0;
  v_guests_inside       bigint := 0;
  v_long_stay           bigint := 0;
  v_high_activity       bigint := 0;
  v_staff_active        bigint := 0;
begin
  if v_pmc_id is null then
    raise exception 'Not authenticated';
  end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;

  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  -- ── Scan counts ──
  select
    count(*) filter (where scan_action = 'entry' and scan_result = 'approved' and scanned_at >= v_today),
    count(*) filter (where scan_action = 'entry' and scan_result = 'approved' and scanned_at >= v_yesterday and scanned_at < v_today),
    count(*) filter (where scan_action = 'exit'  and scan_result = 'approved' and scanned_at >= v_today),
    count(*) filter (where scan_action = 'exit'  and scan_result = 'approved' and scanned_at >= v_yesterday and scanned_at < v_today),
    count(*) filter (where scan_result = 'denied' and scanned_at >= v_today),
    count(*) filter (where scan_result = 'denied' and scanned_at >= v_yesterday and scanned_at < v_today)
  into v_entries_today, v_entries_yesterday, v_exits_today, v_exits_yesterday, v_failed_today, v_failed_yesterday
  from app.security_scan_events
  where pmc_company_id = v_pmc_id;

  -- ── Residents currently inside (last access event = check_in) ──
  select count(distinct ap.id)
  into v_residents_inside
  from app.access_profiles ap
  where ap.pmc_company_id = v_pmc_id
    and ap.status = 'active'
    and exists (
      select 1 from app.access_events ae
      where ae.access_profile_id = ap.id
      order by ae.event_at desc
      limit 1
    )
    and (
      select ae2.event_type::text
      from app.access_events ae2
      where ae2.access_profile_id = ap.id
      order by ae2.event_at desc
      limit 1
    ) = 'check_in';

  -- ── Guests currently inside (last guest event = check_in AND invite active) ──
  select count(distinct gi.id)
  into v_guests_inside
  from app.guest_invitations gi
  where gi.pmc_company_id = v_pmc_id
    and gi.status = 'active'
    and exists (
      select 1 from app.guest_access_events gae
      where gae.guest_invitation_id = gi.id
    )
    and (
      select gae2.event_type::text
      from app.guest_access_events gae2
      where gae2.guest_invitation_id = gi.id
      order by gae2.event_at desc
      limit 1
    ) = 'check_in';

  -- ── Long-stay guests (inside > 24 hours) ──
  select count(*)
  into v_long_stay
  from app.guest_invitations gi
  where gi.pmc_company_id = v_pmc_id
    and gi.status = 'active'
    and exists (
      select 1 from app.guest_access_events gae
      where gae.guest_invitation_id = gi.id
    )
    and (
      select gae2.event_type::text
      from app.guest_access_events gae2
      where gae2.guest_invitation_id = gi.id
      order by gae2.event_at desc
      limit 1
    ) = 'check_in'
    and (
      select gae3.event_at
      from app.guest_access_events gae3
      where gae3.guest_invitation_id = gi.id
      order by gae3.event_at desc
      limit 1
    ) < now() - interval '24 hours';

  -- ── High-activity units this week (>= 5 guest check-ins) ──
  select count(distinct unit_id)
  into v_high_activity
  from (
    select gi.unit_id
    from app.guest_access_events gae
    join app.guest_invitations gi on gi.id = gae.guest_invitation_id
    where gi.pmc_company_id = v_pmc_id
      and gae.event_type::text = 'check_in'
      and gae.event_at >= v_week_ago
    group by gi.unit_id
    having count(*) >= 5
  ) t;

  -- ── Security staff active today ──
  select count(distinct scanned_by_staff_id)
  into v_staff_active
  from app.security_scan_events
  where pmc_company_id = v_pmc_id
    and scanned_at >= v_today;

  return jsonb_build_object(
    'entries_today',           v_entries_today,
    'entries_yesterday',       v_entries_yesterday,
    'exits_today',             v_exits_today,
    'exits_yesterday',         v_exits_yesterday,
    'failed_scans_today',      v_failed_today,
    'failed_scans_yesterday',  v_failed_yesterday,
    'residents_inside',        v_residents_inside,
    'guests_inside',           v_guests_inside,
    'long_stay_guests',        v_long_stay,
    'high_activity_units',     v_high_activity,
    'staff_active_today',      v_staff_active
  );
end;
$$;

grant execute on function app.get_access_dashboard_overview() to authenticated;

-- ── 2. Live Presence ──────────────────────────────────────────────────────────

create or replace function app.get_access_live_presence()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id      uuid := auth.uid();
  v_account_type text;
  v_residents   jsonb;
  v_guests      jsonb;
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  -- Residents inside
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'profile_id',       ap.id,
      'name',             pr.first_name || ' ' || pr.last_name,
      'unit_label',       u.label,
      'property_name',    p.display_name,
      'occupant_type',    ap.occupant_type::text,
      'checked_in_at',    last_ae.event_at,
      'duration_minutes', round(extract(epoch from (now() - last_ae.event_at)) / 60)
    )
    order by last_ae.event_at asc
  ), '[]'::jsonb)
  into v_residents
  from app.access_profiles ap
  join app.profiles  pr on pr.id = ap.user_id
  join app.units     u  on u.id  = ap.unit_id
  join app.properties p on p.id  = ap.property_id
  join lateral (
    select ae.event_type, ae.event_at
    from app.access_events ae
    where ae.access_profile_id = ap.id
    order by ae.event_at desc
    limit 1
  ) last_ae on last_ae.event_type::text = 'check_in'
  where ap.pmc_company_id = v_pmc_id
    and ap.status = 'active';

  -- Guests inside
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'invitation_id',    gi.id,
      'guest_name',       gi.guest_name,
      'inviter_name',     pr.first_name || ' ' || pr.last_name,
      'unit_label',       u.label,
      'property_name',    p.display_name,
      'checked_in_at',    last_gae.event_at,
      'duration_minutes', round(extract(epoch from (now() - last_gae.event_at)) / 60)
    )
    order by last_gae.event_at asc
  ), '[]'::jsonb)
  into v_guests
  from app.guest_invitations gi
  join app.access_profiles ap_i on ap_i.id = gi.inviter_access_profile_id
  join app.profiles         pr  on pr.id   = ap_i.user_id
  join app.units            u   on u.id    = gi.unit_id
  join app.properties       p   on p.id    = gi.property_id
  join lateral (
    select gae.event_type, gae.event_at
    from app.guest_access_events gae
    where gae.guest_invitation_id = gi.id
    order by gae.event_at desc
    limit 1
  ) last_gae on last_gae.event_type::text = 'check_in'
  where gi.pmc_company_id = v_pmc_id
    and gi.status = 'active';

  return jsonb_build_object(
    'residents', coalesce(v_residents, '[]'::jsonb),
    'guests',    coalesce(v_guests,    '[]'::jsonb)
  );
end;
$$;

grant execute on function app.get_access_live_presence() to authenticated;

-- ── 3. Daily Trends ───────────────────────────────────────────────────────────

create or replace function app.get_access_daily_trends(p_days int default 7)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
  v_range_start  timestamptz;
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  v_range_start := date_trunc('day', now()) - ((coalesce(p_days, 7) - 1) * interval '1 day');

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'date',              to_char(gs::date, 'YYYY-MM-DD'),
        'entries',           coalesce(c.entries, 0),
        'exits',             coalesce(c.exits, 0),
        'resident_entries',  coalesce(c.resident_entries, 0),
        'guest_entries',     coalesce(c.guest_entries, 0)
      )
      order by gs
    ), '[]'::jsonb)
    from generate_series(v_range_start, date_trunc('day', now()), '1 day') as gs
    left join (
      select
        date_trunc('day', scanned_at)                                                                as scan_day,
        count(*) filter (where scan_action::text = 'entry' and scan_result::text = 'approved')      as entries,
        count(*) filter (where scan_action::text = 'exit'  and scan_result::text = 'approved')      as exits,
        count(*) filter (where scan_action::text = 'entry' and scan_result::text = 'approved'
                           and person_type is not null and person_type <> 'guest')                  as resident_entries,
        count(*) filter (where scan_action::text = 'entry' and scan_result::text = 'approved'
                           and person_type = 'guest')                                               as guest_entries
      from app.security_scan_events
      where pmc_company_id = v_pmc_id
        and scanned_at >= v_range_start
      group by date_trunc('day', scanned_at)
    ) c on date_trunc('day', gs) = c.scan_day
  );
end;
$$;

grant execute on function app.get_access_daily_trends(int) to authenticated;

-- ── 4. Hourly Activity ────────────────────────────────────────────────────────

create or replace function app.get_access_hourly_breakdown()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'hour',    h.hour,
        'entries', coalesce(c.entries, 0),
        'exits',   coalesce(c.exits, 0)
      )
      order by h.hour
    ), '[]'::jsonb)
    from (select generate_series(0, 23) as hour) h
    left join (
      select
        extract(hour from scanned_at)::int                                                          as scan_hour,
        count(*) filter (where scan_action::text = 'entry' and scan_result::text = 'approved')      as entries,
        count(*) filter (where scan_action::text = 'exit'  and scan_result::text = 'approved')      as exits
      from app.security_scan_events
      where pmc_company_id = v_pmc_id
        and scanned_at >= now() - interval '7 days'
      group by extract(hour from scanned_at)::int
    ) c on c.scan_hour = h.hour
  );
end;
$$;

grant execute on function app.get_access_hourly_breakdown() to authenticated;

-- ── 5. High Activity Units ────────────────────────────────────────────────────

create or replace function app.get_access_high_activity_units()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
  v_week_ago     timestamptz := date_trunc('day', now()) - interval '6 days';
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'unit_id',            u.id,
        'unit_label',         u.label,
        'property_name',      prop.display_name,
        'resident_name',      coalesce(res.resident_name, 'Unknown'),
        'guest_entries_week', us.guest_entries,
        'total_scans_week',   us.total_scans,
        'risk_level',         case
          when us.guest_entries >= 20 then 'high'
          when us.guest_entries >= 10 then 'medium'
          else 'low'
        end
      )
      order by us.guest_entries desc
    ), '[]'::jsonb)
    from (
      select
        gi.unit_id,
        count(*) filter (where gae.event_type::text = 'check_in') as guest_entries,
        count(*)                                                    as total_scans
      from app.guest_access_events gae
      join app.guest_invitations gi on gi.id = gae.guest_invitation_id
      where gi.pmc_company_id = v_pmc_id
        and gae.event_at >= v_week_ago
      group by gi.unit_id
      having count(*) filter (where gae.event_type::text = 'check_in') >= 5
    ) us
    join app.units     u    on u.id   = us.unit_id
    join app.properties prop on prop.id = u.property_id
    left join lateral (
      select pr.first_name || ' ' || pr.last_name as resident_name
      from app.access_profiles ap
      join app.profiles pr on pr.id = ap.user_id
      where ap.unit_id = us.unit_id
        and ap.pmc_company_id = v_pmc_id
        and ap.status = 'active'
      order by ap.activated_at desc
      limit 1
    ) res on true
  );
end;
$$;

grant execute on function app.get_access_high_activity_units() to authenticated;

-- ── 6. Long-Stay Guests ───────────────────────────────────────────────────────

create or replace function app.get_access_long_stay_guests()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'invitation_id', gi.id,
        'guest_name',    gi.guest_name,
        'inviter_name',  pr.first_name || ' ' || pr.last_name,
        'unit_label',    u.label,
        'property_name', p.display_name,
        'checked_in_at', last_gae.event_at,
        'duration_hours', round(extract(epoch from (now() - last_gae.event_at)) / 3600),
        'severity',      case
          when last_gae.event_at < now() - interval '7 days'  then 'critical'
          when last_gae.event_at < now() - interval '72 hours' then 'high'
          else 'warning'
        end
      )
      order by last_gae.event_at asc
    ), '[]'::jsonb)
    from app.guest_invitations gi
    join app.access_profiles ap_i on ap_i.id = gi.inviter_access_profile_id
    join app.profiles         pr  on pr.id   = ap_i.user_id
    join app.units            u   on u.id    = gi.unit_id
    join app.properties       p   on p.id    = gi.property_id
    join lateral (
      select gae.event_type, gae.event_at
      from app.guest_access_events gae
      where gae.guest_invitation_id = gi.id
      order by gae.event_at desc
      limit 1
    ) last_gae on last_gae.event_type::text = 'check_in'
                  and last_gae.event_at < now() - interval '24 hours'
    where gi.pmc_company_id = v_pmc_id
      and gi.status = 'active'
  );
end;
$$;

grant execute on function app.get_access_long_stay_guests() to authenticated;

-- ── 7. Denied Scans ───────────────────────────────────────────────────────────

create or replace function app.get_access_denied_scans(p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id',             se.id,
        'scanned_at',     se.scanned_at,
        'gate_zone_name', se.gate_zone_name,
        'staff_name',     sp.full_name,
        'property_name',  p.display_name,
        'scan_action',    se.scan_action::text,
        'denial_reason',  se.denial_reason,
        'person_type',    se.person_type,
        'person_name',    se.person_name,
        'unit_label',     se.unit_label
      )
      order by se.scanned_at desc
    ), '[]'::jsonb)
    from (
      select * from app.security_scan_events
      where pmc_company_id = v_pmc_id
        and scan_result::text = 'denied'
      order by scanned_at desc
      limit coalesce(p_limit, 50)
    ) se
    join app.security_staff_profiles sp on sp.id = se.scanned_by_staff_id
    join app.properties              p  on p.id  = se.property_id
  );
end;
$$;

grant execute on function app.get_access_denied_scans(int) to authenticated;

-- ── 8. Security Staff Activity ────────────────────────────────────────────────

create or replace function app.get_access_security_staff_activity()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
  v_today        timestamptz := date_trunc('day', now());
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'staff_id',      sp.id,
        'staff_name',    sp.full_name,
        'role',          sp.role::text,
        'assigned_gate', la.gate_zone_name,
        'property_name', p.display_name,
        'scans_today',   coalesce(td.scans_today,   0),
        'entries_today', coalesce(td.entries_today, 0),
        'exits_today',   coalesce(td.exits_today,   0),
        'denied_today',  coalesce(td.denied_today,  0),
        'last_scan_at',  td.last_scan_at
      )
      order by coalesce(td.scans_today, 0) desc, sp.full_name
    ), '[]'::jsonb)
    from app.security_staff_profiles sp
    left join lateral (
      select la2.gate_zone_name, la2.property_id
      from app.security_location_assignments la2
      where la2.staff_profile_id = sp.id
        and la2.is_active = true
      order by la2.assigned_at desc
      limit 1
    ) la on true
    left join app.properties p on p.id = la.property_id
    left join lateral (
      select
        count(*)                                                                                    as scans_today,
        count(*) filter (where scan_action::text = 'entry' and scan_result::text = 'approved')     as entries_today,
        count(*) filter (where scan_action::text = 'exit'  and scan_result::text = 'approved')     as exits_today,
        count(*) filter (where scan_result::text = 'denied')                                       as denied_today,
        max(scanned_at)                                                                            as last_scan_at
      from app.security_scan_events
      where scanned_by_staff_id = sp.id
        and scanned_at >= v_today
    ) td on true
    where sp.pmc_company_id = v_pmc_id
      and sp.status = 'active'
  );
end;
$$;

grant execute on function app.get_access_security_staff_activity() to authenticated;

-- ── 9. Scan Logs ──────────────────────────────────────────────────────────────

create or replace function app.get_access_scan_logs(p_limit int default 100)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id',             se.id,
        'scanned_at',     se.scanned_at,
        'scan_action',    se.scan_action::text,
        'scan_result',    se.scan_result::text,
        'person_type',    se.person_type,
        'person_name',    se.person_name,
        'unit_label',     se.unit_label,
        'property_name',  p.display_name,
        'gate_zone_name', se.gate_zone_name,
        'staff_name',     sp.full_name,
        'denial_reason',  se.denial_reason
      )
      order by se.scanned_at desc
    ), '[]'::jsonb)
    from (
      select * from app.security_scan_events
      where pmc_company_id = v_pmc_id
      order by scanned_at desc
      limit coalesce(p_limit, 100)
    ) se
    join app.security_staff_profiles sp on sp.id = se.scanned_by_staff_id
    join app.properties              p  on p.id  = se.property_id
  );
end;
$$;

grant execute on function app.get_access_scan_logs(int) to authenticated;

-- ── 10. Attention Flags ───────────────────────────────────────────────────────

create or replace function app.get_access_attention_flags()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_pmc_id       uuid := auth.uid();
  v_account_type text;
  v_flags        jsonb := '[]'::jsonb;
  v_week_ago     timestamptz := date_trunc('day', now()) - interval '6 days';
  v_today        timestamptz := date_trunc('day', now());
begin
  if v_pmc_id is null then raise exception 'Not authenticated'; end if;

  select account_type::text into v_account_type
  from app.profiles where id = v_pmc_id limit 1;
  if v_account_type <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  -- Flag A: High guest activity per unit (>= 8 guest check-ins this week)
  v_flags := v_flags || coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',               'high_guest_' || us.unit_id,
        'flag_type',        'high_guest_activity',
        'title',            'High Guest Activity — ' || u.label,
        'description',      us.guest_entries::text || ' guest entries this week at ' ||
                            u.label || ', ' || prop.display_name || '.',
        'severity',         case when us.guest_entries >= 20 then 'high' else 'warning' end,
        'property_name',    prop.display_name,
        'unit_label',       u.label,
        'detected_at',      now(),
        'suggested_action', 'Review guest access logs or contact the resident if needed.'
      )
    )
    from (
      select gi.unit_id, count(*) filter (where gae.event_type::text = 'check_in') as guest_entries
      from app.guest_access_events gae
      join app.guest_invitations gi on gi.id = gae.guest_invitation_id
      where gi.pmc_company_id = v_pmc_id
        and gae.event_at >= v_week_ago
      group by gi.unit_id
      having count(*) filter (where gae.event_type::text = 'check_in') >= 8
    ) us
    join app.units     u    on u.id    = us.unit_id
    join app.properties prop on prop.id = u.property_id
  ), '[]'::jsonb);

  -- Flag B: Long-stay guests (>= 72 hours inside)
  v_flags := v_flags || coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',               'long_stay_' || gi.id,
        'flag_type',        'long_stay_guest',
        'title',            'Long-Stay Guest — ' || gi.guest_name,
        'description',      gi.guest_name || ' has been checked in for ' ||
                            round(extract(epoch from (now() - last_gae.event_at)) / 3600)::text ||
                            ' hours at ' || u.label || ', ' || p.display_name || '.',
        'severity',         case
          when last_gae.event_at < now() - interval '7 days'  then 'critical'
          when last_gae.event_at < now() - interval '72 hours' then 'high'
          else 'warning'
        end,
        'property_name',    p.display_name,
        'unit_label',       u.label,
        'detected_at',      now(),
        'suggested_action', 'Confirm whether extended stay is expected. Contact the resident if required.'
      )
    )
    from app.guest_invitations gi
    join app.units     u on u.id = gi.unit_id
    join app.properties p on p.id = gi.property_id
    join lateral (
      select gae.event_type, gae.event_at
      from app.guest_access_events gae
      where gae.guest_invitation_id = gi.id
      order by gae.event_at desc
      limit 1
    ) last_gae on last_gae.event_type::text = 'check_in'
                  and last_gae.event_at < now() - interval '72 hours'
    where gi.pmc_company_id = v_pmc_id
      and gi.status = 'active'
  ), '[]'::jsonb);

  -- Flag C: Gate with >= 5 denied scans today
  v_flags := v_flags || coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',               'denied_gate_' || gs.property_id || '_' || coalesce(gs.gate_zone_name, 'none'),
        'flag_type',        'high_denied_rate',
        'title',            'Multiple Denied Scans — ' || coalesce(gs.gate_zone_name, p.display_name),
        'description',      gs.denied_count::text || ' denied scans at ' ||
                            coalesce(gs.gate_zone_name, p.display_name) || ' today.',
        'severity',         case when gs.denied_count >= 10 then 'high' else 'warning' end,
        'property_name',    p.display_name,
        'unit_label',       null,
        'detected_at',      now(),
        'suggested_action', 'Review denied scan logs. Check if visitors are using valid QR codes.'
      )
    )
    from (
      select property_id, gate_zone_name, count(*) as denied_count
      from app.security_scan_events
      where pmc_company_id = v_pmc_id
        and scan_result::text = 'denied'
        and scanned_at >= v_today
      group by property_id, gate_zone_name
      having count(*) >= 5
    ) gs
    join app.properties p on p.id = gs.property_id
  ), '[]'::jsonb);

  -- Flag D: Active security staff with zero scans today
  v_flags := v_flags || coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',               'inactive_staff_' || sp.id,
        'flag_type',        'inactive_security_staff',
        'title',            'Security Staff Inactive — ' || sp.full_name,
        'description',      sp.full_name || ' is assigned to ' ||
                            coalesce(la.gate_zone_name, p.display_name) ||
                            ' but has no scans recorded today.',
        'severity',         'warning',
        'property_name',    p.display_name,
        'unit_label',       null,
        'detected_at',      now(),
        'suggested_action', 'Confirm the staff member is on duty and actively using the scan portal.'
      )
    )
    from app.security_staff_profiles sp
    join lateral (
      select la2.gate_zone_name, la2.property_id
      from app.security_location_assignments la2
      where la2.staff_profile_id = sp.id
        and la2.is_active = true
      order by la2.assigned_at desc
      limit 1
    ) la on true
    join app.properties p on p.id = la.property_id
    where sp.pmc_company_id = v_pmc_id
      and sp.status = 'active'
      and not exists (
        select 1 from app.security_scan_events
        where scanned_by_staff_id = sp.id
          and scanned_at >= v_today
      )
  ), '[]'::jsonb);

  return v_flags;
end;
$$;

grant execute on function app.get_access_attention_flags() to authenticated;
