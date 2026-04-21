-- ============================================================================
-- V 1 16: Generic Payment Setup Methods
-- ============================================================================
-- Purpose
--   - Allow payment collection setups to store non-M-Pesa methods such as card.
--   - Keep M-Pesa-specific validation for M-Pesa setups only.
--   - Preserve current tenant M-Pesa resolution flows by filtering the tenant
--     payment-setup RPC to M-Pesa methods until non-M-Pesa payment collection
--     flows are implemented end to end.
-- ============================================================================

do $$
begin
  alter type app.payment_method_type_enum add value if not exists 'card';
exception
  when duplicate_object then null;
end $$;

alter table app.payment_collection_setups
  drop constraint if exists chk_payment_collection_setups_supported_methods;

alter table app.payment_collection_setups
  drop constraint if exists chk_payment_collection_setups_method_details;

alter table app.payment_collection_setups
  add constraint chk_payment_collection_setups_method_details
  check (
    (
      payment_method_type = 'mpesa_paybill'
      and paybill_number is not null
      and till_number is null
      and send_money_phone_number is null
    )
    or (
      payment_method_type = 'mpesa_till'
      and paybill_number is null
      and till_number is not null
      and send_money_phone_number is null
    )
    or (
      payment_method_type = 'mpesa_send_money'
      and paybill_number is null
      and till_number is null
      and send_money_phone_number is not null
    )
    or (
      payment_method_type::text in ('card', 'bank_transfer', 'cash', 'cheque', 'other')
      and paybill_number is null
      and till_number is null
      and send_money_phone_number is null
    )
  );

create or replace function app.create_payment_collection_setup(
  p_scope_type app.payment_scope_enum,
  p_workspace_id uuid default null,
  p_property_id uuid default null,
  p_unit_id uuid default null,
  p_payment_method_type app.payment_method_type_enum default 'mpesa_paybill',
  p_display_name text default null,
  p_account_name text default null,
  p_account_number text default null,
  p_account_reference_hint text default null,
  p_collection_instructions text default null,
  p_make_default boolean default true,
  p_activate boolean default true,
  p_priority_rank integer default 100
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_setup_id uuid := gen_random_uuid();
  v_workspace_id uuid;
  v_property_id uuid;
  v_unit_id uuid;
  v_paybill_number text;
  v_till_number text;
  v_send_money_phone_number text;
  v_lifecycle_status app.payment_collection_setup_status_enum;
  v_registration_status app.mpesa_registration_status_enum := 'not_required';
  v_action_id uuid;
  v_metadata jsonb := '{}'::jsonb;
  v_default_display_name text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select t.workspace_id, t.property_id, t.unit_id
    into v_workspace_id, v_property_id, v_unit_id
  from app.get_payment_scope_target_ids(
    p_scope_type,
    p_workspace_id,
    p_property_id,
    p_unit_id
  ) t
  limit 1;

  if p_scope_type = 'workspace' then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
    ) then
      raise exception 'Forbidden: requires workspace owner or workspace admin';
    end if;
  else
    perform app.assert_financial_management_access(v_property_id);
  end if;

  if p_account_name is null or char_length(trim(p_account_name)) < 2 then
    raise exception 'account_name is required';
  end if;

  v_lifecycle_status := case
    when p_activate then 'active'::app.payment_collection_setup_status_enum
    else 'draft'::app.payment_collection_setup_status_enum
  end;

  if p_payment_method_type = 'mpesa_paybill' then
    if p_account_number is null or char_length(trim(p_account_number)) < 5 then
      raise exception 'account_number is required for M-Pesa paybill';
    end if;

    v_paybill_number := trim(p_account_number);
    v_registration_status := case
      when p_activate then 'pending'::app.mpesa_registration_status_enum
      else 'not_required'::app.mpesa_registration_status_enum
    end;
    v_default_display_name := 'M-Pesa payment setup';
  elsif p_payment_method_type = 'mpesa_till' then
    if p_account_number is null or char_length(trim(p_account_number)) < 5 then
      raise exception 'account_number is required for M-Pesa till';
    end if;

    v_till_number := trim(p_account_number);
    v_registration_status := case
      when p_activate then 'pending'::app.mpesa_registration_status_enum
      else 'not_required'::app.mpesa_registration_status_enum
    end;
    v_default_display_name := 'M-Pesa payment setup';
  elsif p_payment_method_type = 'mpesa_send_money' then
    if p_account_number is null or char_length(trim(p_account_number)) < 5 then
      raise exception 'account_number is required for M-Pesa send money';
    end if;

    v_send_money_phone_number := trim(p_account_number);
    v_default_display_name := 'M-Pesa payment setup';
  else
    v_default_display_name := initcap(replace(p_payment_method_type::text, '_', ' ')) || ' payment setup';

    if nullif(trim(coalesce(p_account_number, '')), '') is not null then
      v_metadata := jsonb_build_object(
        'account_number',
        trim(p_account_number)
      );
    end if;
  end if;

  if p_activate then
    update app.payment_collection_setups s
       set lifecycle_status = 'superseded',
           is_default = false,
           deactivated_at = now(),
           replaced_by_setup_id = v_setup_id
     where s.deleted_at is null
       and s.lifecycle_status = 'active'
       and s.id <> v_setup_id
       and (
         (v_paybill_number is not null and lower(trim(s.paybill_number)) = lower(v_paybill_number))
         or
         (v_till_number is not null and lower(trim(s.till_number)) = lower(v_till_number))
         or
         (v_send_money_phone_number is not null and lower(trim(s.send_money_phone_number)) = lower(v_send_money_phone_number))
         or
         (
           s.payment_method_type = p_payment_method_type
           and s.scope_type = p_scope_type
           and (
             (p_scope_type = 'workspace' and s.workspace_id = v_workspace_id)
             or
             (p_scope_type = 'property' and s.property_id = v_property_id)
             or
             (p_scope_type = 'unit' and s.unit_id = v_unit_id)
           )
         )
       );

    if p_make_default then
      update app.payment_collection_setups s
         set is_default = false
       where s.deleted_at is null
         and s.lifecycle_status = 'active'
         and s.is_default = true
         and s.scope_type = p_scope_type
         and (
           (p_scope_type = 'workspace' and s.workspace_id = v_workspace_id)
           or
           (p_scope_type = 'property' and s.property_id = v_property_id)
           or
           (p_scope_type = 'unit' and s.unit_id = v_unit_id)
         );
    end if;
  end if;

  insert into app.payment_collection_setups (
    id,
    workspace_id,
    property_id,
    unit_id,
    scope_type,
    payment_method_type,
    lifecycle_status,
    is_default,
    priority_rank,
    display_name,
    account_name,
    paybill_number,
    till_number,
    send_money_phone_number,
    account_reference_hint,
    collection_instructions,
    metadata,
    mpesa_c2b_registration_status,
    created_by_user_id,
    activated_at
  )
  values (
    v_setup_id,
    v_workspace_id,
    v_property_id,
    v_unit_id,
    p_scope_type,
    p_payment_method_type,
    v_lifecycle_status,
    coalesce(p_make_default, false) and p_activate,
    greatest(coalesce(p_priority_rank, 100), 1),
    coalesce(nullif(trim(p_display_name), ''), v_default_display_name),
    trim(p_account_name),
    v_paybill_number,
    v_till_number,
    v_send_money_phone_number,
    nullif(trim(coalesce(p_account_reference_hint, '')), ''),
    nullif(trim(coalesce(p_collection_instructions, '')), ''),
    v_metadata,
    v_registration_status,
    auth.uid(),
    case when p_activate then now() else null end
  );

  if v_property_id is not null then
    perform app.touch_property_activity(v_property_id);

    v_action_id := app.get_audit_action_id_by_code('PAYMENT_SETUP_CREATED');
    if v_action_id is not null then
      insert into app.audit_logs (
        property_id,
        unit_id,
        actor_user_id,
        action_type_id,
        payload
      )
      values (
        v_property_id,
        v_unit_id,
        auth.uid(),
        v_action_id,
        jsonb_build_object(
          'payment_collection_setup_id', v_setup_id,
          'scope_type', p_scope_type,
          'payment_method_type', p_payment_method_type,
          'account_number', coalesce(
            v_paybill_number,
            v_till_number,
            v_send_money_phone_number,
            v_metadata->>'account_number'
          ),
          'is_default', coalesce(p_make_default, false) and p_activate
        )
      );
    end if;
  end if;

  return v_setup_id;
end;
$$;

create or replace function app.get_payment_method_display_label(
  p_method app.payment_method_type_enum
)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case p_method::text
    when 'mpesa_paybill' then 'M-Pesa'
    when 'mpesa_till' then 'M-Pesa'
    when 'mpesa_send_money' then 'M-Pesa Send Money'
    when 'card' then 'Card'
    when 'bank_transfer' then 'Bank Transfer'
    when 'cash' then 'Cash'
    when 'cheque' then 'Cheque'
    else 'Other'
  end;
$$;

create or replace function app.get_active_payment_setup_for_tenant(
  p_unit_id uuid
)
returns table (
  id                      uuid,
  payment_method_type     text,
  display_name            text,
  account_name            text,
  paybill_number          text,
  till_number             text,
  send_money_phone        text,
  account_reference       text,
  collection_instructions text,
  setup_scope             text
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_caller_user_id uuid := auth.uid();
  v_property_id uuid;
  v_workspace_id uuid;
  v_unit_label text;
  v_has_tenancy boolean;
begin
  if v_caller_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select
    u.property_id,
    p.workspace_id,
    coalesce(nullif(trim(u.label), ''), u.id::text)
  into v_property_id, v_workspace_id, v_unit_label
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_property_id is null then
    raise exception 'Unit not found';
  end if;

  select exists (
    select 1
    from app.unit_tenancies ut
    where ut.unit_id = p_unit_id
      and ut.tenant_user_id = v_caller_user_id
      and ut.status in ('active', 'scheduled', 'pending_agreement')
    union all
    select 1
    from app.unit_occupancy_snapshots uos
    where uos.unit_id = p_unit_id
      and uos.current_tenant_user_id = v_caller_user_id
      and uos.occupancy_status in ('occupied', 'pending_confirmation')
  ) into v_has_tenancy;

  if not v_has_tenancy then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
      or app.has_financial_management_access(v_property_id)
    ) then
      raise exception 'Forbidden: no confirmed tenancy for this unit';
    end if;
  end if;

  return query
  with setups as (
    select
      s.id,
      s.payment_method_type,
      coalesce(nullif(trim(s.display_name), ''), s.account_name) as resolved_display_name,
      s.account_name,
      s.paybill_number,
      s.till_number,
      s.send_money_phone_number as send_money_phone,
      coalesce(nullif(trim(s.account_reference_hint), ''), v_unit_label) as resolved_account_reference,
      s.collection_instructions,
      s.scope_type::text as resolved_setup_scope,
      s.is_default,
      s.priority_rank,
      s.created_at,
      case s.scope_type
        when 'unit' then 1
        when 'property' then 2
        when 'workspace' then 3
        else 4
      end as scope_priority
    from app.payment_collection_setups s
    where s.deleted_at is null
      and s.lifecycle_status = 'active'
      and s.payment_method_type in ('mpesa_paybill', 'mpesa_till', 'mpesa_send_money')
      and (
        (s.scope_type = 'unit' and s.unit_id = p_unit_id)
        or (s.scope_type = 'property' and s.property_id = v_property_id)
        or (s.scope_type = 'workspace' and s.workspace_id = v_workspace_id)
      )
  )
  select
    s.id,
    s.payment_method_type::text,
    s.resolved_display_name,
    s.account_name,
    s.paybill_number,
    s.till_number,
    s.send_money_phone,
    s.resolved_account_reference,
    s.collection_instructions,
    s.resolved_setup_scope
  from setups s
  order by
    s.scope_priority asc,
    s.is_default desc,
    s.priority_rank asc,
    s.created_at desc
  limit 1;
end;
$$;
