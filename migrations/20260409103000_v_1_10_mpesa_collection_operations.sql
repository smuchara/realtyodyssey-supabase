-- ============================================================================
-- V 1 10: M-Pesa Collection Operations
-- ============================================================================
-- Purpose
--   - Model M-Pesa C2B registration status, raw callback intake, and audit events.
--   - Support M-Pesa setup registration, C2B callback recording, STK callback handling, and setup methods.
--   - Keep provider-specific payment operations isolated from the revenue core.
--
-- Consolidated before first production publication. Related patch migrations
-- are folded into this canonical domain migration for easier maintenance.
-- ============================================================================
-- ----------------------------------------------------------------------------
-- M-Pesa transaction registry and callback event ingestion
-- ----------------------------------------------------------------------------

create schema if not exists app;

do $$ begin
  create type app.mpesa_registration_status_enum as enum (
    'not_required',
    'pending',
    'registered',
    'failed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.mpesa_callback_event_type_enum as enum (
    'c2b_validation',
    'c2b_confirmation'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.mpesa_callback_processing_status_enum as enum (
    'received',
    'processed',
    'duplicate',
    'rejected'
  );
exception when duplicate_object then null; end $$;

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('MPESA_C2B_URL_REGISTERED', 'M-Pesa C2B URL Registered', 206),
  ('MPESA_CALLBACK_RECEIVED', 'M-Pesa Callback Received', 207)
on conflict (code) do update
set label = excluded.label, sort_order = excluded.sort_order;

alter table app.payment_collection_setups
  add column if not exists mpesa_c2b_registration_status app.mpesa_registration_status_enum
    not null default 'not_required',
  add column if not exists mpesa_c2b_registered_at timestamptz,
  add column if not exists mpesa_c2b_last_registration_attempt_at timestamptz,
  add column if not exists mpesa_c2b_last_registration_response jsonb
    not null default '{}'::jsonb;

update app.payment_collection_setups
set mpesa_c2b_registration_status = case
  when payment_method_type in ('mpesa_paybill', 'mpesa_till')
    then 'pending'::app.mpesa_registration_status_enum
  else 'not_required'::app.mpesa_registration_status_enum
end
where mpesa_c2b_registration_status = 'not_required'
  and lifecycle_status = 'active'
  and payment_method_type in ('mpesa_paybill', 'mpesa_till');

create unique index if not exists uq_payment_collection_setups_paybill_active_global
  on app.payment_collection_setups(lower(trim(paybill_number)))
  where deleted_at is null
    and lifecycle_status = 'active'
    and paybill_number is not null;

create unique index if not exists uq_payment_collection_setups_till_active_global
  on app.payment_collection_setups(lower(trim(till_number)))
  where deleted_at is null
    and lifecycle_status = 'active'
    and till_number is not null;

create unique index if not exists uq_payment_collection_setups_send_money_active_global
  on app.payment_collection_setups(lower(trim(send_money_phone_number)))
  where deleted_at is null
    and lifecycle_status = 'active'
    and send_money_phone_number is not null;

create table if not exists app.mpesa_callback_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid references app.workspaces(id) on delete set null,
  property_id uuid references app.properties(id) on delete set null,
  unit_id uuid references app.units(id) on delete set null,
  payment_collection_setup_id uuid references app.payment_collection_setups(id) on delete set null,
  payment_record_id uuid references app.payment_records(id) on delete set null,
  event_type app.mpesa_callback_event_type_enum not null,
  processing_status app.mpesa_callback_processing_status_enum not null default 'received',
  payload_hash text not null,
  short_code text,
  mpesa_receipt_number text,
  transaction_type text,
  bill_ref_number text,
  invoice_number text,
  third_party_trans_id text,
  msisdn text,
  payer_name text,
  transacted_at timestamptz,
  amount numeric(12,2),
  raw_payload jsonb not null default '{}'::jsonb,
  processing_notes text,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_mpesa_callback_events_payload_hash_len
    check (char_length(trim(payload_hash)) between 8 and 128),
  constraint chk_mpesa_callback_events_amount_non_negative
    check (amount is null or amount >= 0),
  constraint chk_mpesa_callback_events_msisdn_len
    check (msisdn is null or char_length(trim(msisdn)) between 7 and 32)
);

comment on table app.mpesa_callback_events is
  'Immutable raw M-Pesa callback intake log used for auditability, deduplication, and later reconciliation.';

drop trigger if exists trg_mpesa_callback_events_updated_at on app.mpesa_callback_events;
create trigger trg_mpesa_callback_events_updated_at
before update on app.mpesa_callback_events
for each row
execute function app.set_updated_at();

create unique index if not exists uq_mpesa_callback_events_event_payload_hash
  on app.mpesa_callback_events(event_type, payload_hash);

create unique index if not exists uq_mpesa_callback_events_confirmation_receipt
  on app.mpesa_callback_events(lower(mpesa_receipt_number))
  where event_type = 'c2b_confirmation'
    and mpesa_receipt_number is not null;

create index if not exists idx_mpesa_callback_events_setup_created
  on app.mpesa_callback_events(payment_collection_setup_id, created_at desc);

create index if not exists idx_mpesa_callback_events_property_created
  on app.mpesa_callback_events(property_id, created_at desc)
  where property_id is not null;

create or replace function app.get_payment_scope_target_ids(
  p_scope_type app.payment_scope_enum,
  p_workspace_id uuid default null,
  p_property_id uuid default null,
  p_unit_id uuid default null
)
returns table (
  workspace_id uuid,
  property_id uuid,
  unit_id uuid
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_property_id uuid;
begin
  if p_scope_type = 'workspace' then
    if p_workspace_id is null then
      raise exception 'workspace_id is required for workspace scope';
    end if;

    return query
    select p_workspace_id, null::uuid, null::uuid;
    return;
  end if;

  if p_scope_type = 'property' then
    if p_property_id is null then
      raise exception 'property_id is required for property scope';
    end if;

    select p.workspace_id
      into v_workspace_id
    from app.properties p
    where p.id = p_property_id
      and p.deleted_at is null
    limit 1;

    if v_workspace_id is null then
      raise exception 'Property not found or deleted';
    end if;

    return query
    select v_workspace_id, p_property_id, null::uuid;
    return;
  end if;

  if p_scope_type = 'unit' then
    if p_unit_id is null then
      raise exception 'unit_id is required for unit scope';
    end if;

    select u.property_id, p.workspace_id
      into v_property_id, v_workspace_id
    from app.units u
    join app.properties p
      on p.id = u.property_id
    where u.id = p_unit_id
      and u.deleted_at is null
      and p.deleted_at is null
    limit 1;

    if v_property_id is null or v_workspace_id is null then
      raise exception 'Unit not found or deleted';
    end if;

    if p_property_id is not null and p_property_id <> v_property_id then
      raise exception 'unit_id does not belong to the provided property_id';
    end if;

    return query
    select v_workspace_id, v_property_id, p_unit_id;
    return;
  end if;

  raise exception 'Unsupported scope type: %', p_scope_type;
end;
$$;

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

  if p_payment_method_type not in ('mpesa_paybill', 'mpesa_till', 'mpesa_send_money') then
    raise exception 'Only M-Pesa payment methods are supported by this RPC';
  end if;

  if p_account_name is null or char_length(trim(p_account_name)) < 2 then
    raise exception 'account_name is required';
  end if;

  if p_account_number is null or char_length(trim(p_account_number)) < 5 then
    raise exception 'account_number is required';
  end if;

  v_lifecycle_status := case
    when p_activate then 'active'::app.payment_collection_setup_status_enum
    else 'draft'::app.payment_collection_setup_status_enum
  end;

  if p_payment_method_type = 'mpesa_paybill' then
    v_paybill_number := trim(p_account_number);
    v_registration_status := case
      when p_activate then 'pending'::app.mpesa_registration_status_enum
      else 'not_required'::app.mpesa_registration_status_enum
    end;
  elsif p_payment_method_type = 'mpesa_till' then
    v_till_number := trim(p_account_number);
    v_registration_status := case
      when p_activate then 'pending'::app.mpesa_registration_status_enum
      else 'not_required'::app.mpesa_registration_status_enum
    end;
  else
    v_send_money_phone_number := trim(p_account_number);
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
    coalesce(nullif(trim(p_display_name), ''), 'M-Pesa payment setup'),
    trim(p_account_name),
    v_paybill_number,
    v_till_number,
    v_send_money_phone_number,
    nullif(trim(coalesce(p_account_reference_hint, '')), ''),
    nullif(trim(coalesce(p_collection_instructions, '')), ''),
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
          'account_number', coalesce(v_paybill_number, v_till_number, v_send_money_phone_number),
          'is_default', coalesce(p_make_default, false) and p_activate
        )
      );
    end if;
  end if;

  return v_setup_id;
end;
$$;

create or replace function app.mark_payment_collection_setup_mpesa_registration(
  p_setup_id uuid,
  p_status app.mpesa_registration_status_enum,
  p_response jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_unit_id uuid;
  v_action_id uuid;
begin
  update app.payment_collection_setups s
     set mpesa_c2b_registration_status = p_status,
         mpesa_c2b_last_registration_attempt_at = now(),
         mpesa_c2b_registered_at = case
           when p_status = 'registered' then now()
           else s.mpesa_c2b_registered_at
         end,
         mpesa_c2b_last_registration_response = coalesce(p_response, '{}'::jsonb)
   where s.id = p_setup_id
     and s.deleted_at is null
  returning s.property_id, s.unit_id
    into v_property_id, v_unit_id;

  if v_property_id is null and v_unit_id is null then
    return;
  end if;

  if p_status = 'registered' and v_property_id is not null then
    v_action_id := app.get_audit_action_id_by_code('MPESA_C2B_URL_REGISTERED');
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
          'payment_collection_setup_id', p_setup_id,
          'registration_status', p_status,
          'response', coalesce(p_response, '{}'::jsonb)
        )
      );
    end if;
  end if;
end;
$$;

create or replace function app.record_mpesa_c2b_callback(
  p_event_type app.mpesa_callback_event_type_enum,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_payload_hash text;
  v_short_code text;
  v_receipt_number text;
  v_bill_ref_number text;
  v_invoice_number text;
  v_third_party_trans_id text;
  v_msisdn text;
  v_payer_name text;
  v_amount numeric(12,2);
  v_transacted_at timestamptz;
  v_setup record;
  v_event_id uuid;
  v_payment_record_id uuid;
  v_existing_payment_id uuid;
begin
  if p_payload is null or p_payload = '{}'::jsonb then
    raise exception 'Callback payload is required';
  end if;

  v_payload_hash := encode(
    digest(convert_to(p_payload::text, 'utf8'), 'sha256'),
    'hex'
  );

  v_short_code := nullif(trim(coalesce(
    p_payload->>'BusinessShortCode',
    p_payload->>'ShortCode'
  )), '');

  v_receipt_number := nullif(trim(coalesce(
    p_payload->>'TransID',
    p_payload->>'MpesaReceiptNumber'
  )), '');

  v_bill_ref_number := nullif(trim(coalesce(p_payload->>'BillRefNumber', '')), '');
  v_invoice_number := nullif(trim(coalesce(p_payload->>'InvoiceNumber', '')), '');
  v_third_party_trans_id := nullif(trim(coalesce(p_payload->>'ThirdPartyTransID', '')), '');
  v_msisdn := nullif(trim(coalesce(p_payload->>'MSISDN', p_payload->>'PhoneNumber', '')), '');

  v_payer_name := nullif(trim(concat_ws(
    ' ',
    nullif(trim(coalesce(p_payload->>'FirstName', '')), ''),
    nullif(trim(coalesce(p_payload->>'MiddleName', '')), ''),
    nullif(trim(coalesce(p_payload->>'LastName', '')), '')
  )), '');

  if nullif(trim(coalesce(p_payload->>'TransAmount', '')), '') is not null then
    v_amount := (p_payload->>'TransAmount')::numeric(12,2);
  end if;

  if nullif(trim(coalesce(p_payload->>'TransTime', '')), '') is not null then
    v_transacted_at := to_timestamp(p_payload->>'TransTime', 'YYYYMMDDHH24MISS');
  end if;

  begin
    insert into app.mpesa_callback_events (
      event_type,
      processing_status,
      payload_hash,
      short_code,
      mpesa_receipt_number,
      transaction_type,
      bill_ref_number,
      invoice_number,
      third_party_trans_id,
      msisdn,
      payer_name,
      transacted_at,
      amount,
      raw_payload
    )
    values (
      p_event_type,
      'received',
      v_payload_hash,
      v_short_code,
      v_receipt_number,
      nullif(trim(coalesce(p_payload->>'TransactionType', '')), ''),
      v_bill_ref_number,
      v_invoice_number,
      v_third_party_trans_id,
      v_msisdn,
      v_payer_name,
      v_transacted_at,
      v_amount,
      p_payload
    )
    returning id into v_event_id;
  exception
    when unique_violation then
      return jsonb_build_object(
        'status', 'duplicate',
        'payload_hash', v_payload_hash,
        'mpesa_receipt_number', v_receipt_number
      );
  end;

  if v_short_code is not null then
    select
      s.id,
      s.workspace_id,
      s.property_id,
      s.unit_id,
      s.payment_method_type
    into v_setup
    from app.payment_collection_setups s
    where s.deleted_at is null
      and s.lifecycle_status = 'active'
      and (
        lower(trim(s.paybill_number)) = lower(v_short_code)
        or lower(trim(s.till_number)) = lower(v_short_code)
      )
    order by
      case s.scope_type
        when 'unit' then 1
        when 'property' then 2
        else 3
      end asc,
      s.created_at desc
    limit 1;

    update app.mpesa_callback_events
       set workspace_id = v_setup.workspace_id,
           property_id = v_setup.property_id,
           unit_id = v_setup.unit_id,
           payment_collection_setup_id = v_setup.id
     where id = v_event_id;
  end if;

  if p_event_type = 'c2b_confirmation' and v_setup.id is not null and v_amount is not null then
    select pr.id
      into v_existing_payment_id
    from app.payment_records pr
    where pr.deleted_at is null
      and lower(pr.reference_code) = lower(coalesce(v_receipt_number, ''))
    limit 1;

    if v_existing_payment_id is null then
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
        payer_name,
        payer_phone,
        reference_code,
        external_receipt_number,
        collection_setup_snapshot,
        metadata,
        recorded_by_user_id
      )
      values (
        v_setup.workspace_id,
        v_setup.property_id,
        v_setup.unit_id,
        v_setup.id,
        'recorded',
        'mobile_money_import',
        v_setup.payment_method_type,
        v_amount,
        'KES',
        coalesce(v_transacted_at, now()),
        v_payer_name,
        v_msisdn,
        v_receipt_number,
        v_receipt_number,
        '{}'::jsonb,
        jsonb_build_object(
          'provider', 'mpesa_daraja',
          'event_type', p_event_type,
          'short_code', v_short_code,
          'bill_ref_number', v_bill_ref_number,
          'invoice_number', v_invoice_number,
          'third_party_trans_id', v_third_party_trans_id,
          'raw_payload', p_payload
        ),
        coalesce(
          (select created_by_user_id from app.payment_collection_setups where id = v_setup.id),
          (select owner_user_id from app.workspaces where id = v_setup.workspace_id)
        )
      )
      returning id into v_payment_record_id;
    else
      v_payment_record_id := v_existing_payment_id;
    end if;

    update app.mpesa_callback_events
       set payment_record_id = v_payment_record_id,
           processing_status = case
             when v_existing_payment_id is null then 'processed'
             else 'duplicate'
           end,
           processed_at = now()
     where id = v_event_id;
  else
    update app.mpesa_callback_events
       set processing_status = case
             when v_setup.id is null then 'rejected'
             else 'processed'
           end,
           processing_notes = case
             when v_setup.id is null then 'No active payment setup matched the callback short code'
             else null
           end,
           processed_at = now()
     where id = v_event_id;
  end if;

  return jsonb_build_object(
    'status', 'accepted',
    'event_id', v_event_id,
    'payment_collection_setup_id', v_setup.id,
    'payment_record_id', v_payment_record_id
  );
end;
$$;

alter table app.mpesa_callback_events enable row level security;
alter table app.mpesa_callback_events force row level security;

drop policy if exists mpesa_callback_events_select_financial_control on app.mpesa_callback_events;
create policy mpesa_callback_events_select_financial_control
on app.mpesa_callback_events
for select
to authenticated
using (
  (
    property_id is not null
    and app.has_financial_management_access(property_id)
  )
  or
  (
    property_id is null
    and workspace_id is not null
    and (
      app.is_workspace_owner(workspace_id)
      or app.is_workspace_admin(workspace_id)
    )
  )
);

revoke all on function app.get_payment_scope_target_ids(app.payment_scope_enum, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.create_payment_collection_setup(
  app.payment_scope_enum,
  uuid,
  uuid,
  uuid,
  app.payment_method_type_enum,
  text,
  text,
  text,
  text,
  text,
  boolean,
  boolean,
  integer
) from public, anon, authenticated;
revoke all on function app.mark_payment_collection_setup_mpesa_registration(uuid, app.mpesa_registration_status_enum, jsonb) from public, anon, authenticated;
revoke all on function app.record_mpesa_c2b_callback(app.mpesa_callback_event_type_enum, jsonb) from public, anon, authenticated;

grant execute on function app.create_payment_collection_setup(
  app.payment_scope_enum,
  uuid,
  uuid,
  uuid,
  app.payment_method_type_enum,
  text,
  text,
  text,
  text,
  text,
  boolean,
  boolean,
  integer
) to authenticated;

grant execute on function app.mark_payment_collection_setup_mpesa_registration(
  uuid,
  app.mpesa_registration_status_enum,
  jsonb
) to service_role;

grant execute on function app.record_mpesa_c2b_callback(
  app.mpesa_callback_event_type_enum,
  jsonb
) to service_role;

-- ----------------------------------------------------------------------------
-- M-Pesa STK lifecycle and advance payments
-- ----------------------------------------------------------------------------

create schema if not exists app;

do $$ begin
  create type app.mpesa_stk_status_enum as enum ('pending', 'success', 'failed', 'expired');
exception when duplicate_object then null; end $$;

create table if not exists app.mpesa_stk_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_id uuid references app.properties(id) on delete set null,
  unit_id uuid references app.units(id) on delete set null,
  rent_charge_period_id uuid references app.rent_charge_periods(id) on delete restrict,
  payment_collection_setup_id uuid not null references app.payment_collection_setups(id) on delete restrict,
  checkout_request_id text unique,
  merchant_request_id text,
  amount numeric(12,2) not null,
  phone_number text not null,
  status app.mpesa_stk_status_enum not null default 'pending',
  result_code text,
  result_desc text,
  raw_callback_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table app.mpesa_stk_requests is
  'Tracks the lifecycle of M-Pesa STK Push prompts. Links initiated requests to callbacks.';

create index if not exists idx_mpesa_stk_requests_checkout_request_id
  on app.mpesa_stk_requests(checkout_request_id)
  where checkout_request_id is not null;

create index if not exists idx_mpesa_stk_requests_rent_charge_period
  on app.mpesa_stk_requests(rent_charge_period_id);

alter table app.mpesa_stk_requests enable row level security;
alter table app.mpesa_stk_requests force row level security;

drop policy if exists mpesa_stk_requests_no_direct_client_access
  on app.mpesa_stk_requests;
create policy mpesa_stk_requests_no_direct_client_access
  on app.mpesa_stk_requests
  as restrictive
  for all
  to public
  using (false)
  with check (false);

revoke all on table app.mpesa_stk_requests from public, anon, authenticated;

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
      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
    end if;
  end if;

  return jsonb_build_object(
    'status', 'accepted',
    'stk_request_id', v_stk_request.id,
    'payment_record_id', v_payment_record_id
  );
end;
$$;

grant execute on function app.record_mpesa_stk_callback(jsonb) to service_role;

-- ----------------------------------------------------------------------------
-- Generic payment setup methods
-- ----------------------------------------------------------------------------

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
