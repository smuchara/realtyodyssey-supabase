-- ============================================================================
-- V 1 15: Pro-rated Rent Calculation for Tenant Home
-- ============================================================================
-- Purpose:
--   - Calculate pro-rated rent since admission for tenants when ledger data is missing.
--   - Daily rate = Rent / 31.
--   - Free for the first 7 days (grace period).
-- ============================================================================

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
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- 1. Fetch Profile
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

  -- 2. Fetch Residence
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

  -- 3. Calculate Pro-rated Rent if ledger is missing
  if v_has_residence and v_residence.rent_amount > 0 then
    -- Admission date is residence.starts_on
    v_days_stayed := (current_date - v_residence.starts_on::date);
    
    if v_days_stayed > 7 then
      v_daily_rate := v_residence.rent_amount / 31.0;
      v_calculated_rent := round(v_daily_rate * v_days_stayed, 2);
      v_has_calculated_rent := true;
    else
      v_calculated_rent := 0;
      v_has_calculated_rent := true; -- It's a valid "free" period
    end if;
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
        when v_has_calculated_rent then 'Current balance calculated from admission date.'
        else 'Tenant payment ledger tables were not found yet.'
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
          when v_calculated_rent > 0 then 'Outstanding balance (Estimated)'
          when v_days_stayed <= 7 then 'Welcome period (Free)'
          else 'No balance recorded'
        end,
        'as_of_date', current_date,
        'previous_amount', 0,
        'previous_label', null,
        'previous_as_of_date', null
      ),
      'upcoming_payments', case
        when v_has_calculated_rent and v_calculated_rent > 0 then
          json_build_array(
            jsonb_build_object(
              'type', 'rent',
              'title', 'Pending Rent',
              'subtitle', 'Pro-rated from admission',
              'amount', v_calculated_rent,
              'currency_code', coalesce(v_residence.currency_code, 'KES'),
              'due_date', current_date,
              'status', 'pending',
              'button_label', 'Pay Ahora',
              'is_estimated', true
            )
          )::jsonb
        else '[]'::jsonb
      end
    )
  );
end;
$$;
