-- ============================================================================
-- V 1.26: Payment Setup Update RPC
-- ============================================================================
-- Purpose: Allow authenticated owners/admins to update a payment setup's
--          shortcode and account reference hint.
--          Direct table UPDATE is blocked by RLS (only SELECT policy exists),
--          so a security definer RPC is required — consistent with existing
--          write patterns throughout the codebase.
-- ============================================================================

create or replace function app.update_payment_collection_setup_shortcode(
  p_setup_id               uuid,
  p_short_code             text,
  p_account_reference_hint text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_method_type  app.payment_method_type_enum;
  v_scope_type   app.payment_scope_enum;
  v_workspace_id uuid;
  v_property_id  uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select payment_method_type, scope_type, workspace_id, property_id
    into v_method_type, v_scope_type, v_workspace_id, v_property_id
  from app.payment_collection_setups
  where id = p_setup_id
    and deleted_at is null;

  if not found then
    raise exception 'Payment setup not found';
  end if;

  if v_scope_type = 'workspace' then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
    ) then
      raise exception 'Forbidden: requires workspace owner or workspace admin';
    end if;
  else
    perform app.assert_financial_management_access(v_property_id);
  end if;

  if p_short_code is null or char_length(trim(p_short_code)) < 5 then
    raise exception 'short_code must be at least 5 characters';
  end if;

  update app.payment_collection_setups
  set
    paybill_number = case
      when v_method_type = 'mpesa_paybill'    then trim(p_short_code)
      else paybill_number
    end,
    till_number = case
      when v_method_type = 'mpesa_till'       then trim(p_short_code)
      else till_number
    end,
    send_money_phone_number = case
      when v_method_type = 'mpesa_send_money' then trim(p_short_code)
      else send_money_phone_number
    end,
    account_reference_hint = p_account_reference_hint
  where id = p_setup_id;
end;
$$;

grant execute on function app.update_payment_collection_setup_shortcode(uuid, text, text)
  to authenticated;
