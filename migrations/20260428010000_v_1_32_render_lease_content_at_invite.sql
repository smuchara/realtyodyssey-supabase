-- ============================================================================
-- V 1 32: Render lease template content at invite creation time
-- ============================================================================
-- Problem
--   content_snapshot was stored with raw {{placeholder}} tokens from the
--   template, so the mobile app displayed unrendered text like
--   "{{tenant.full_name}}" instead of the tenant's actual name.
--
-- Solution
--   1. app.format_ordinal(n)          — "5" → "5th"
--   2. app.format_money(amount, code) — renders currency amounts
--   3. app.render_template_sections(sections, subs) — replaces all {{k}} tokens
--   4. Updated create_tenant_invitation — builds the substitution map from
--      invite params and stores RENDERED content in content_snapshot.
--
-- Tokens left unrendered (data not available at invite creation):
--   {{tenant.id_number}}, {{deposit.amount}}, {{late_fee.amount}},
--   {{service_charge.amount}}, {{agreement.*}}
-- ============================================================================

create schema if not exists app;

-- ─── format_ordinal ───────────────────────────────────────────────────────────

create or replace function app.format_ordinal(n integer)
returns text
language sql
immutable
set search_path = app, public
as $$
  select n::text || case
    when n % 100 in (11, 12, 13) then 'th'
    when n % 10 = 1              then 'st'
    when n % 10 = 2              then 'nd'
    when n % 10 = 3              then 'rd'
    else                              'th'
  end;
$$;

-- ─── format_money ─────────────────────────────────────────────────────────────

create or replace function app.format_money(p_amount numeric, p_currency text)
returns text
language sql
immutable
set search_path = app, public
as $$
  select coalesce(upper(p_currency), 'KES') || ' ' ||
         to_char(coalesce(p_amount, 0), 'FM999,999,999.00');
$$;

-- ─── render_template_sections ─────────────────────────────────────────────────
-- Takes a JSONB array of section objects and a JSONB substitution map
-- ({"{{token}}": "value"}) and returns the array with all tokens replaced in
-- each section's "content" field. Tokens with empty/null values are skipped.

create or replace function app.render_template_sections(
  p_sections      jsonb,
  p_substitutions jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = app, public
as $$
declare
  v_section  jsonb;
  v_content  text;
  v_key      text;
  v_val      text;
  v_result   jsonb := '[]'::jsonb;
begin
  if p_sections is null or jsonb_array_length(p_sections) = 0 then
    return '[]'::jsonb;
  end if;

  for v_section in select * from jsonb_array_elements(p_sections) loop
    v_content := v_section->>'content';

    if v_content is not null and p_substitutions is not null then
      for v_key, v_val in
        select key, trim(both '"' from value::text)
        from jsonb_each(p_substitutions)
      loop
        if v_val is not null and v_val <> '' and v_val <> 'null' then
          v_content := replace(v_content, v_key, v_val);
        end if;
      end loop;
    end if;

    v_result := v_result || jsonb_set(v_section, '{content}', to_jsonb(v_content));
  end loop;

  return v_result;
end;
$$;

-- ─── create_tenant_invitation (full rewrite with rendering) ──────────────────

create or replace function app.create_tenant_invitation(
  p_unit_id                    uuid,
  p_tenant_phone               text    default null,
  p_tenant_email               text    default null,
  p_delivery_channel           app.tenant_invitation_delivery_channel_enum default 'email',
  p_tenant_name                text    default null,
  p_lease_type                 app.lease_type_enum default 'fixed_term',
  p_start_date                 date    default current_date,
  p_end_date                   date    default null,
  p_rent_amount                numeric default 0,
  p_notes                      text    default null,
  p_billing_cycle              app.lease_billing_cycle_enum default 'monthly',
  p_rent_due_day_of_month      integer default 5,
  p_collection_grace_period_days integer default 2,
  p_currency_code              text    default 'KES',
  p_expires_in_days            integer default 7,
  p_template_id                text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_unit                       record;
  v_snapshot                   record;
  v_tenant_phone               text;
  v_tenant_email               text;
  v_tenant_name                text;
  v_notes                      text;
  v_currency_code              text;
  v_token                      text;
  v_expires_at                 timestamptz;
  v_lease_id                   uuid;
  v_invitation_id              uuid;
  v_lease_action_id            uuid;
  v_invite_action_id           uuid;
  -- Template resolution
  v_template_uuid              uuid;
  v_template_version_id        uuid;
  v_raw_sections               jsonb;
  v_content_snapshot           jsonb;
  -- Owner profile
  v_owner_name                 text;
  v_owner_email                text;
  -- Duration calculation
  v_duration_months            integer;
  v_duration_text              text;
  -- Substitution map
  v_subs                       jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_tenant_phone   := nullif(trim(coalesce(p_tenant_phone, '')), '');
  v_tenant_email   := nullif(trim(lower(coalesce(p_tenant_email, ''))), '');
  v_tenant_name    := nullif(trim(coalesce(p_tenant_name, '')), '');
  v_notes          := nullif(trim(coalesce(p_notes, '')), '');
  v_currency_code  := upper(coalesce(nullif(trim(p_currency_code), ''), 'KES'));
  v_expires_at     := now() + make_interval(days => greatest(coalesce(p_expires_in_days, 7), 1));

  if p_delivery_channel = 'email' and v_tenant_email is null then
    raise exception 'Tenant email is required for email delivery';
  end if;
  if p_delivery_channel = 'sms' and v_tenant_phone is null then
    raise exception 'Tenant phone number is required for SMS delivery';
  end if;
  if p_rent_amount is null or p_rent_amount < 0 then
    raise exception 'Rent amount must be zero or greater';
  end if;
  if p_rent_due_day_of_month is null or p_rent_due_day_of_month < 1 or p_rent_due_day_of_month > 28 then
    raise exception 'Rent due day must be between 1 and 28';
  end if;
  if p_collection_grace_period_days is null or p_collection_grace_period_days < 0 or p_collection_grace_period_days > 14 then
    raise exception 'Collection grace period must be between 0 and 14 days';
  end if;

  -- ── Template resolution ───────────────────────────────────────────────────
  if p_template_id is not null and length(trim(p_template_id)) > 0 then
    begin
      v_template_uuid := trim(p_template_id)::uuid;
    exception when invalid_text_representation then
      v_template_uuid := null;
    end;

    if v_template_uuid is not null then
      select ltv.id, ltv.sections
        into v_template_version_id, v_raw_sections
      from app.lease_template_versions ltv
      where ltv.template_id = v_template_uuid
        and ltv.status = 'active'
      order by ltv.version_number desc
      limit 1;
    end if;
  end if;

  -- ── Unit + property fetch (extended to include address fields) ─────────────
  select
    u.id               as unit_id,
    u.property_id,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit')          as unit_label,
    coalesce(u.block, '')                                            as unit_block,
    coalesce(u.floor, '')                                            as unit_floor,
    u.expected_rate,
    p.status           as property_status,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    coalesce(p.address_description, '')                              as property_address,
    coalesce(p.city_town, '')                                        as property_city
  into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.unit_id is null then
    raise exception 'Unit not found or deleted';
  end if;
  if v_unit.property_status <> 'active' then
    raise exception 'Tenant invites can only be created for active properties';
  end if;

  -- ── Owner profile ─────────────────────────────────────────────────────────
  select
    trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')),
    coalesce(email, '')
  into v_owner_name, v_owner_email
  from app.profiles
  where id = auth.uid()
  limit 1;

  v_owner_name  := nullif(trim(coalesce(v_owner_name, '')), '');
  v_owner_email := nullif(trim(coalesce(v_owner_email, '')), '');

  perform app.assert_tenancy_management_access(v_unit.property_id);
  perform app.expire_tenant_invitations(v_unit.property_id, p_unit_id);
  perform app.refresh_lease_agreement_statuses(v_unit.property_id, p_unit_id);
  perform app.refresh_unit_tenancy_statuses(v_unit.property_id, p_unit_id);
  perform app.ensure_unit_occupancy_snapshot_exists(p_unit_id, auth.uid());

  select occupancy_status into v_snapshot
  from app.unit_occupancy_snapshots
  where unit_id = p_unit_id
  limit 1;

  if coalesce(v_snapshot.occupancy_status::text, '') in ('occupied', 'disputed') then
    raise exception 'This unit is not currently available for a new tenant invite';
  end if;

  if exists (
    select 1 from app.tenant_invitations i
    where i.unit_id = p_unit_id
      and app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at)
          in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  ) then
    raise exception 'A live tenant invitation already exists for this unit';
  end if;

  if exists (
    select 1 from app.lease_agreements l
    where l.unit_id = p_unit_id
      and app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date)
          in ('pending_confirmation', 'confirmed', 'active', 'disputed')
  ) then
    raise exception 'A live lease agreement already exists for this unit';
  end if;

  if exists (
    select 1 from app.unit_tenancies t
    where t.unit_id = p_unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
  ) then
    raise exception 'This unit already has an open tenancy';
  end if;

  if p_lease_type = 'fixed_term' and (p_end_date is null or p_end_date <= p_start_date) then
    raise exception 'Fixed-term leases require an end date after the start date';
  end if;
  if p_lease_type <> 'fixed_term' and p_end_date is not null and p_end_date <= p_start_date then
    raise exception 'Lease end date must be after the start date';
  end if;

  -- ── Render template content with real invite data ─────────────────────────
  if v_raw_sections is not null then
    -- Compute lease duration text
    if p_end_date is not null then
      v_duration_months := (
        extract(year from age(p_end_date, p_start_date)) * 12 +
        extract(month from age(p_end_date, p_start_date))
      )::integer;
      v_duration_text := case
        when v_duration_months = 12 then 'Twelve (12) months'
        when v_duration_months = 6  then 'Six (6) months'
        when v_duration_months = 24 then 'Twenty-Four (24) months'
        else v_duration_months::text || ' months'
      end;
    else
      v_duration_text := 'Month-to-month (rolling)';
    end if;

    v_subs := jsonb_build_object(
      -- Tenant
      '{{tenant.full_name}}',   coalesce(v_tenant_name, coalesce(v_tenant_email, 'Tenant')),
      '{{tenant.email}}',       coalesce(v_tenant_email, ''),
      '{{tenant.phone}}',       coalesce(v_tenant_phone, ''),
      -- Owner / Landlord
      '{{owner.full_name}}',    coalesce(v_owner_name, 'Property Manager'),
      '{{owner.email}}',        coalesce(v_owner_email, ''),
      '{{owner.phone}}',        '',
      -- Property
      '{{property.name}}',      v_unit.property_name,
      '{{property.address}}',   case
                                  when v_unit.property_address <> '' and v_unit.property_city <> ''
                                  then v_unit.property_address || ', ' || v_unit.property_city
                                  when v_unit.property_address <> '' then v_unit.property_address
                                  when v_unit.property_city    <> '' then v_unit.property_city
                                  else ''
                                end,
      -- Unit
      '{{unit.number}}',        v_unit.unit_label,
      '{{unit.block}}',         v_unit.unit_block,
      '{{unit.floor}}',         v_unit.unit_floor,
      -- Lease dates & terms
      '{{lease.start_date}}',   to_char(p_start_date, 'FMDDth Month YYYY'),
      '{{lease.end_date}}',     case when p_end_date is not null
                                     then to_char(p_end_date, 'FMDDth Month YYYY')
                                     else 'Open-ended (month-to-month)'
                                end,
      '{{lease.duration}}',     v_duration_text,
      '{{lease.type}}',         initcap(replace(p_lease_type::text, '_', ' ')),
      '{{lease.notice_period}}','Thirty (30) days',
      -- Financial
      '{{rent.monthly_amount}}',app.format_money(p_rent_amount, v_currency_code),
      '{{rent.due_day}}',        app.format_ordinal(p_rent_due_day_of_month)
    );

    v_content_snapshot := app.render_template_sections(v_raw_sections, v_subs);
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  -- ── Create lease draft ────────────────────────────────────────────────────
  insert into app.lease_agreements (
    property_id, unit_id, tenant_name, tenant_phone, entered_by_user_id, lease_type,
    start_date, end_date, billing_cycle, rent_due_day_of_month, collection_grace_period_days,
    rent_amount, currency_code, status, confirmation_status, agreement_notes, terms_snapshot,
    template_version_id, content_snapshot
  )
  values (
    v_unit.property_id, p_unit_id, v_tenant_name, v_tenant_phone, auth.uid(),
    p_lease_type, p_start_date, p_end_date, coalesce(p_billing_cycle, 'monthly'),
    p_rent_due_day_of_month, p_collection_grace_period_days, p_rent_amount,
    v_currency_code, 'pending_confirmation', 'awaiting_tenant', v_notes,
    jsonb_build_object(
      'captured_from',                'owner_web_invite',
      'captured_at',                   now(),
      'expected_rate_at_capture',      v_unit.expected_rate,
      'unit_label',                    v_unit.unit_label,
      'property_name',                 v_unit.property_name,
      'rent_due_day_of_month',         p_rent_due_day_of_month,
      'collection_grace_period_days',  p_collection_grace_period_days,
      'collection_policy_label', format(
        'Rent due by the %s with collection follow-up through day %s of the month.',
        p_rent_due_day_of_month,
        p_rent_due_day_of_month + p_collection_grace_period_days
      ),
      'delivery_channel',              p_delivery_channel::text,
      'tenant_email',                  v_tenant_email
    ),
    v_template_version_id,
    v_content_snapshot
  )
  returning id into v_lease_id;

  -- ── Create invitation ─────────────────────────────────────────────────────
  insert into app.tenant_invitations (
    property_id, unit_id, lease_agreement_id, invited_by_user_id, invited_phone_number,
    invited_email, invited_name, token_hash, delivery_channel, status, sent_at,
    expires_at, template_id, template_version_id, metadata
  )
  values (
    v_unit.property_id, p_unit_id, v_lease_id, auth.uid(),
    v_tenant_phone, v_tenant_email, v_tenant_name,
    app.hash_token(v_token), p_delivery_channel, 'sent', now(), v_expires_at,
    v_template_uuid, v_template_version_id,
    jsonb_build_object(
      'lease_type',                   p_lease_type::text,
      'lease_start_date',             p_start_date,
      'lease_end_date',               p_end_date,
      'rent_amount',                  p_rent_amount,
      'currency_code',                v_currency_code,
      'billing_cycle',                coalesce(p_billing_cycle, 'monthly')::text,
      'rent_due_day_of_month',        p_rent_due_day_of_month,
      'collection_grace_period_days', p_collection_grace_period_days,
      'notes',                        v_notes,
      'template_version_id',          v_template_version_id
    )
  )
  returning id into v_invitation_id;

  perform app.sync_unit_occupancy_snapshot(p_unit_id, auth.uid());
  perform app.touch_property_activity(v_unit.property_id);
  perform app.enqueue_tenant_invitation_notifications(v_invitation_id);

  v_lease_action_id := app.get_audit_action_id_by_code('LEASE_CAPTURED');
  if v_lease_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (v_unit.property_id, p_unit_id, auth.uid(), v_lease_action_id,
      jsonb_build_object(
        'lease_agreement_id',           v_lease_id,
        'lease_type',                   p_lease_type::text,
        'billing_cycle',                coalesce(p_billing_cycle, 'monthly')::text,
        'rent_due_day_of_month',        p_rent_due_day_of_month,
        'collection_grace_period_days', p_collection_grace_period_days,
        'rent_amount',                  p_rent_amount,
        'currency_code',                v_currency_code,
        'template_version_id',          v_template_version_id
      ));
  end if;

  v_invite_action_id := app.get_audit_action_id_by_code('TENANT_INVITE_SENT');
  if v_invite_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (v_unit.property_id, p_unit_id, auth.uid(), v_invite_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invitation_id,
        'lease_agreement_id',   v_lease_id,
        'delivery_channel',     p_delivery_channel::text,
        'expires_at',           v_expires_at,
        'template_version_id',  v_template_version_id
      ));
  end if;

  return jsonb_build_object(
    'property_id',          v_unit.property_id,
    'unit_id',              p_unit_id,
    'lease_agreement_id',   v_lease_id,
    'tenant_invitation_id', v_invitation_id,
    'status',               'sent',
    'delivery_channel',     p_delivery_channel::text,
    'expires_at',           v_expires_at,
    'token',                v_token,
    'template_version_id',  v_template_version_id
  );
end;
$$;

-- Grants carry over from V 1 07 / V 1 31 — no changes needed since function
-- signature is identical.
