-- ============================================================================
-- V 1 19: M-Pesa Callback Reconciliation
-- ============================================================================
-- Purpose:
--   - Persist every STK callback in a durable inbox before processing.
--   - Allow replay/reconciliation when callback posting fails once.
--   - Expose a tenant-safe payment status lookup for short-lived polling after
--     STK prompt acceptance.
-- ============================================================================

create schema if not exists app;

create table if not exists app.mpesa_stk_callback_events (
  id uuid primary key default gen_random_uuid(),
  checkout_request_id text not null,
  result_code text,
  result_desc text,
  payload jsonb not null,
  processing_status text not null default 'pending',
  linked_stk_request_id uuid references app.mpesa_stk_requests(id) on delete set null,
  linked_payment_record_id uuid references app.payment_records(id) on delete set null,
  processing_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint chk_mpesa_stk_callback_events_processing_status
    check (processing_status in ('pending', 'processed', 'failed', 'ignored'))
);

comment on table app.mpesa_stk_callback_events is
  'Durable inbox of M-Pesa STK callbacks. Used to replay or reconcile callbacks when posting fails.';

create index if not exists idx_mpesa_stk_callback_events_checkout_request_id
  on app.mpesa_stk_callback_events(checkout_request_id, received_at desc);

create index if not exists idx_mpesa_stk_callback_events_processing_status
  on app.mpesa_stk_callback_events(processing_status, received_at desc);

create index if not exists idx_payment_records_metadata_checkout_request_id
  on app.payment_records ((metadata->>'checkout_request_id'))
  where deleted_at is null and metadata ? 'checkout_request_id';

create or replace function app.process_mpesa_stk_callback_event(
  p_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_event app.mpesa_stk_callback_events%rowtype;
  v_result jsonb;
  v_result_status text;
  v_stk_request_id uuid;
  v_payment_record_id uuid;
begin
  select *
    into v_event
  from app.mpesa_stk_callback_events
  where id = p_event_id
  for update;

  if v_event.id is null then
    raise exception 'STK callback event not found: %', p_event_id;
  end if;

  if v_event.processing_status in ('processed', 'ignored') then
    return jsonb_build_object(
      'status', v_event.processing_status,
      'event_id', v_event.id,
      'checkout_request_id', v_event.checkout_request_id,
      'stk_request_id', v_event.linked_stk_request_id,
      'payment_record_id', v_event.linked_payment_record_id
    );
  end if;

  begin
    v_result := app.record_mpesa_stk_callback(v_event.payload);
    v_result_status := coalesce(v_result->>'status', 'accepted');
    v_stk_request_id := nullif(v_result->>'stk_request_id', '')::uuid;
    v_payment_record_id := nullif(v_result->>'payment_record_id', '')::uuid;

    if v_payment_record_id is null then
      select pr.id
        into v_payment_record_id
      from app.payment_records pr
      where pr.deleted_at is null
        and pr.metadata->>'checkout_request_id' = v_event.checkout_request_id
      order by pr.created_at desc
      limit 1;
    end if;

    if v_stk_request_id is null then
      select stk.id
        into v_stk_request_id
      from app.mpesa_stk_requests stk
      where stk.checkout_request_id = v_event.checkout_request_id
      limit 1;
    end if;

    update app.mpesa_stk_callback_events
       set processing_status = case
             when v_result_status = 'duplicate' then 'ignored'
             else 'processed'
           end,
           linked_stk_request_id = coalesce(v_stk_request_id, linked_stk_request_id),
           linked_payment_record_id = coalesce(v_payment_record_id, linked_payment_record_id),
           processing_error = null,
           processed_at = now()
     where id = v_event.id;

    return jsonb_build_object(
      'status', v_result_status,
      'event_id', v_event.id,
      'checkout_request_id', v_event.checkout_request_id,
      'stk_request_id', v_stk_request_id,
      'payment_record_id', v_payment_record_id,
      'processing_status', case
        when v_result_status = 'duplicate' then 'ignored'
        else 'processed'
      end
    );
  exception when others then
    update app.mpesa_stk_callback_events
       set processing_status = 'failed',
           linked_stk_request_id = coalesce(
             linked_stk_request_id,
             (
               select stk.id
               from app.mpesa_stk_requests stk
               where stk.checkout_request_id = v_event.checkout_request_id
               limit 1
             )
           ),
           processing_error = sqlerrm,
           processed_at = now()
     where id = v_event.id;

    return jsonb_build_object(
      'status', 'failed',
      'event_id', v_event.id,
      'checkout_request_id', v_event.checkout_request_id,
      'error', sqlerrm
    );
  end;
end;
$$;

create or replace function app.get_tenant_mpesa_payment_status(
  p_checkout_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_caller_user_id uuid := auth.uid();
  v_stk_request app.mpesa_stk_requests%rowtype;
  v_workspace_id uuid;
  v_has_access boolean := false;
  v_latest_event app.mpesa_stk_callback_events%rowtype;
  v_payment_record_id uuid;
begin
  if v_caller_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_checkout_request_id is null or length(trim(p_checkout_request_id)) = 0 then
    raise exception 'checkoutRequestId is required';
  end if;

  select stk.*
    into v_stk_request
  from app.mpesa_stk_requests stk
  where stk.checkout_request_id = trim(p_checkout_request_id)
  limit 1;

  if v_stk_request.id is null then
    raise exception 'Payment request not found';
  end if;

  select p.workspace_id
    into v_workspace_id
  from app.properties p
  where p.id = v_stk_request.property_id
    and p.deleted_at is null
  limit 1;

  if v_stk_request.unit_id is not null then
    select exists (
      select 1
      from app.unit_tenancies ut
      where ut.unit_id = v_stk_request.unit_id
        and ut.tenant_user_id = v_caller_user_id
        and ut.status in ('active', 'scheduled', 'pending_agreement')
      union all
      select 1
      from app.unit_occupancy_snapshots uos
      where uos.unit_id = v_stk_request.unit_id
        and uos.current_tenant_user_id = v_caller_user_id
        and uos.occupancy_status in ('occupied', 'pending_confirmation')
    ) into v_has_access;
  end if;

  if not v_has_access then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
      or app.has_financial_management_access(v_stk_request.property_id)
    ) then
      raise exception 'Forbidden';
    end if;
  end if;

  select *
    into v_latest_event
  from app.mpesa_stk_callback_events event_row
  where event_row.checkout_request_id = trim(p_checkout_request_id)
  order by event_row.received_at desc
  limit 1;

  if v_stk_request.status = 'pending'::app.mpesa_stk_status_enum then
    if v_latest_event.id is not null
      and v_latest_event.processing_status in ('pending', 'failed') then
      perform app.process_mpesa_stk_callback_event(v_latest_event.id);
    elsif v_stk_request.raw_callback_payload <> '{}'::jsonb then
      begin
        perform app.record_mpesa_stk_callback(v_stk_request.raw_callback_payload);
      exception when others then
        update app.mpesa_stk_requests
           set result_desc = format(
                 'Stored callback replay failed: %s',
                 sqlerrm
               ),
               updated_at = now()
         where id = v_stk_request.id;
      end;
    end if;

    select *
      into v_stk_request
    from app.mpesa_stk_requests
    where id = v_stk_request.id;

    select *
      into v_latest_event
    from app.mpesa_stk_callback_events event_row
    where event_row.checkout_request_id = trim(p_checkout_request_id)
    order by event_row.received_at desc
    limit 1;
  end if;

  select pr.id
    into v_payment_record_id
  from app.payment_records pr
  where pr.deleted_at is null
    and pr.metadata->>'checkout_request_id' = trim(p_checkout_request_id)
  order by pr.created_at desc
  limit 1;

  return jsonb_build_object(
    'checkout_request_id', trim(p_checkout_request_id),
    'stk_request_id', v_stk_request.id,
    'status', v_stk_request.status,
    'result_code', v_stk_request.result_code,
    'result_desc', v_stk_request.result_desc,
    'amount', v_stk_request.amount,
    'phone_number', v_stk_request.phone_number,
    'payment_record_id', v_payment_record_id,
    'is_posted', v_payment_record_id is not null,
    'callback_received',
      (
        v_latest_event.id is not null
        or v_stk_request.raw_callback_payload <> '{}'::jsonb
      ),
    'callback_processed',
      coalesce(v_latest_event.processing_status in ('processed', 'ignored'), false),
    'callback_processing_error', v_latest_event.processing_error,
    'updated_at', v_stk_request.updated_at
  );
end;
$$;

create or replace function app.reconcile_mpesa_stk_request_from_status_query(
  p_checkout_request_id text,
  p_status_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_stk_request app.mpesa_stk_requests%rowtype;
  v_existing_payment_record_id uuid;
  v_payment_record_id uuid;
  v_result_code text := coalesce(p_status_payload->>'ResultCode', '');
  v_result_desc text := coalesce(
    nullif(p_status_payload->>'ResultDesc', ''),
    nullif(p_status_payload->>'ResponseDescription', ''),
    'Status query processed'
  );
  v_payment_intent text;
  v_requested_advance_months integer;
  v_allocation_result jsonb;
  v_is_terminal_failure boolean := false;
begin
  if p_checkout_request_id is null or length(trim(p_checkout_request_id)) = 0 then
    raise exception 'checkoutRequestId is required';
  end if;

  select *
    into v_stk_request
  from app.mpesa_stk_requests stk
  where stk.checkout_request_id = trim(p_checkout_request_id)
  for update;

  if v_stk_request.id is null then
    raise exception 'No matching STK request found for CheckoutRequestID %', p_checkout_request_id;
  end if;

  select pr.id
    into v_existing_payment_record_id
  from app.payment_records pr
  where pr.deleted_at is null
    and pr.metadata->>'checkout_request_id' = trim(p_checkout_request_id)
  order by pr.created_at desc
  limit 1;

  if v_existing_payment_record_id is not null then
    update app.mpesa_stk_requests
       set status = 'success'::app.mpesa_stk_status_enum,
           result_code = nullif(v_result_code, ''),
           result_desc = v_result_desc,
           updated_at = now()
     where id = v_stk_request.id;

    return jsonb_build_object(
      'status', 'already_posted',
      'stk_request_id', v_stk_request.id,
      'payment_record_id', v_existing_payment_record_id
    );
  end if;

  if v_stk_request.status <> 'pending'::app.mpesa_stk_status_enum then
    return jsonb_build_object(
      'status', 'already_processed',
      'stk_request_id', v_stk_request.id,
      'processing_status', v_stk_request.status
    );
  end if;

  v_is_terminal_failure :=
    (
      nullif(v_result_code, '') is not null
      and v_result_code <> '0'
      and (
        v_result_code in ('1', '1032', '1037', '2001')
        or lower(v_result_desc) like '%cancel%'
        or lower(v_result_desc) like '%timeout%'
        or lower(v_result_desc) like '%declin%'
        or lower(v_result_desc) like '%failed%'
        or lower(v_result_desc) like '%insufficient%'
      )
    );

  if v_result_code = '0' then
    v_payment_intent := coalesce(v_stk_request.payment_context->>'payment_intent', 'charge_payment');
    v_requested_advance_months := nullif(
      v_stk_request.payment_context->>'requested_advance_months',
      ''
    )::integer;

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
      payer_phone,
      reference_code,
      external_receipt_number,
      notes,
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
      (
        select payment_method_type
        from app.payment_collection_setups
        where id = v_stk_request.payment_collection_setup_id
      ),
      v_stk_request.amount,
      'KES',
      now(),
      v_stk_request.phone_number,
      null,
      null,
      'Confirmed via STK status query before callback metadata was posted.',
      jsonb_build_object(
        'provider', 'mpesa_daraja',
        'checkout_request_id', trim(p_checkout_request_id),
        'stk_request_id', v_stk_request.id,
        'payment_intent', v_payment_intent,
        'requested_advance_months', v_requested_advance_months,
        'allocation_mode', case
          when v_stk_request.rent_charge_period_id is null then 'unapplied'
          else 'automatic'
        end,
        'settlement_source', 'stk_status_query',
        'status_query_payload', coalesce(p_status_payload, '{}'::jsonb)
      ),
      (
        select created_by_user_id
        from app.payment_collection_setups
        where id = v_stk_request.payment_collection_setup_id
      )
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
        allocated_at,
        notes
      )
      values (
        v_stk_request.workspace_id,
        v_stk_request.property_id,
        v_stk_request.unit_id,
        v_payment_record_id,
        v_stk_request.rent_charge_period_id,
        'automatic'::app.payment_allocation_source_enum,
        v_stk_request.amount,
        now(),
        'Allocated after STK status query confirmation'
      );

      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
      perform app.refresh_rent_charge_period_payment_state(v_stk_request.rent_charge_period_id);
    else
      v_allocation_result := app.auto_allocate_payment_record_to_charge_periods(
        v_payment_record_id,
        true
      );
      perform app.refresh_payment_record_allocation_state(v_payment_record_id);
    end if;

    update app.mpesa_stk_requests
       set status = 'success'::app.mpesa_stk_status_enum,
           result_code = '0',
           result_desc = v_result_desc,
           updated_at = now()
     where id = v_stk_request.id;

    return jsonb_build_object(
      'status', 'posted_from_status_query',
      'stk_request_id', v_stk_request.id,
      'payment_record_id', v_payment_record_id,
      'allocation_result', coalesce(v_allocation_result, '{}'::jsonb)
    );
  end if;

  if v_is_terminal_failure then
    update app.mpesa_stk_requests
       set status = 'failed'::app.mpesa_stk_status_enum,
           result_code = nullif(v_result_code, ''),
           result_desc = v_result_desc,
           updated_at = now()
     where id = v_stk_request.id;

    return jsonb_build_object(
      'status', 'failed_from_status_query',
      'stk_request_id', v_stk_request.id,
      'result_code', nullif(v_result_code, ''),
      'result_desc', v_result_desc
    );
  end if;

  update app.mpesa_stk_requests
     set result_code = nullif(v_result_code, ''),
         result_desc = v_result_desc,
         updated_at = now()
   where id = v_stk_request.id;

  return jsonb_build_object(
    'status', 'still_pending',
    'stk_request_id', v_stk_request.id,
    'result_code', nullif(v_result_code, ''),
    'result_desc', v_result_desc
  );
end;
$$;

revoke all on table app.mpesa_stk_callback_events from public, anon, authenticated;

revoke all on function app.process_mpesa_stk_callback_event(uuid)
  from public, anon, authenticated;
revoke all on function app.get_tenant_mpesa_payment_status(text)
  from public, anon, authenticated;
revoke all on function app.reconcile_mpesa_stk_request_from_status_query(text, jsonb)
  from public, anon, authenticated;

grant execute on function app.process_mpesa_stk_callback_event(uuid)
  to service_role;
grant execute on function app.get_tenant_mpesa_payment_status(text)
  to authenticated;
grant execute on function app.reconcile_mpesa_stk_request_from_status_query(text, jsonb)
  to service_role;
