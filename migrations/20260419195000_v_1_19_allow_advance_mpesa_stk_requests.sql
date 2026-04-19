-- ============================================================================
-- V 1 19: Allow Advance M-Pesa STK Requests Without Invoice Allocation
-- ============================================================================
-- Purpose:
--   - Allow STK requests initiated from advance-payment flows to be tracked
--     without requiring a rent charge period up front.
--   - Keep invoice-backed payments allocating automatically on callback.
--   - Leave advance payments as unapplied payment records until a later
--     allocation workflow assigns them to rent charge periods.
-- ============================================================================

alter table app.mpesa_stk_requests
  alter column rent_charge_period_id drop not null;

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
