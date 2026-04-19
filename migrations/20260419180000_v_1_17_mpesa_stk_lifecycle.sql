-- ============================================================================
-- V 1 17: M-Pesa STK Lifecycle Tracking
-- ============================================================================
-- Purpose:
--   - Persist STK Push requests before they are sent to Safaricom
--   - Track the status of each prompt attempt
--   - Ensure reliable matching of callbacks via CheckoutRequestID
-- ============================================================================

create schema if not exists app;

do $$ begin
  create type app.mpesa_stk_status_enum as enum ('pending', 'success', 'failed', 'expired');
exception when duplicate_object then null; end $$;

create table if not exists app.mpesa_stk_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  property_id uuid references app.properties(id) on delete set null,
  unit_id uuid references app.units(id) on delete set null,
  rent_charge_period_id uuid not null references app.rent_charge_periods(id) on delete restrict,
  payment_collection_setup_id uuid not null references app.payment_collection_setups(id) on delete restrict,
  checkout_request_id text unique, -- Returned by Daraja
  merchant_request_id text, -- Returned by Daraja
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

-- RPC to record STK callback safely
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

  -- 1. Find the matching request
  select * into v_stk_request
  from app.mpesa_stk_requests
  where checkout_request_id = v_checkout_request_id
  for update;

  if v_stk_request.id is null then
    raise exception 'No matching STK request found for CheckoutRequestID %', v_checkout_request_id;
  end if;

  -- 1.5 Idempotency check: only process pending requests
  if v_stk_request.status <> 'pending' then
    return jsonb_build_object(
      'status', 'duplicate',
      'stk_request_id', v_stk_request.id,
      'processing_status', v_stk_request.status
    );
  end if;

  -- 2. Update the request status
  update app.mpesa_stk_requests
     set status = case when v_result_code = '0' then 'success'::app.mpesa_stk_status_enum else 'failed'::app.mpesa_stk_status_enum end,
         result_code = v_result_code,
         result_desc = v_result_desc,
         raw_callback_payload = p_payload,
         updated_at = now()
   where id = v_stk_request.id;

  -- 3. If success, create payment record
  if v_result_code = '0' then
    v_metadata := v_stk_callback->'CallbackMetadata'->'Item';
    
    -- Extract items from metadata array
    select (e->>'Value')::text into v_receipt_number from jsonb_array_elements(v_metadata) e where e->>'Name' = 'MpesaReceiptNumber';
    select (e->>'Value')::numeric into v_amount from jsonb_array_elements(v_metadata) e where e->>'Name' = 'Amount';
    
    -- M-Pesa TransTime is usually YYYYMMDDHHMMSS
    select to_timestamp((e->>'Value'), 'YYYYMMDDHH24MISS') into v_transacted_at from jsonb_array_elements(v_metadata) e where e->>'Name' = 'TransactionDate';

    -- Create target payment record
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
        'stk_request_id', v_stk_request.id
      ),
      (select created_by_user_id from app.payment_collection_setups where id = v_stk_request.payment_collection_setup_id)
    returning id into v_payment_record_id;

    -- Allocate the payment to the charge period
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

    -- Refresh states
    perform app.refresh_payment_record_allocation_state(v_payment_record_id);
    perform app.refresh_rent_charge_period_payment_state(v_stk_request.rent_charge_period_id);
  end if;

  return jsonb_build_object(
    'status', 'accepted',
    'stk_request_id', v_stk_request.id,
    'payment_record_id', v_payment_record_id
  );
end;
$$;

grant execute on function app.record_mpesa_stk_callback(jsonb) to service_role;
