-- ============================================================================
-- REBUILD 14: Update Payment RPC to include Setup ID
-- ============================================================================
-- Description:
--   Updates app.get_active_payment_setup_for_tenant to return the internal 
--   setup ID, which is required by the mobile app for payment initiation.
-- ============================================================================

drop function if exists app.get_active_payment_setup_for_tenant(uuid);

create or replace function app.get_active_payment_setup_for_tenant(
  p_unit_id uuid
)
returns table (
  id                    uuid,
  payment_method_type   text,
  display_name          text,
  account_name          text,
  paybill_number        text,
  till_number           text,
  send_money_phone      text,
  account_reference     text,
  collection_instructions text,
  setup_scope           text
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_caller_user_id    uuid := auth.uid();
  v_property_id       uuid;
  v_workspace_id      uuid;
  v_unit_label        text;
  v_has_tenancy       boolean;
begin
  -- Must be authenticated
  if v_caller_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- Resolve unit → property → workspace and capture the display label for the unit
  select 
    u.property_id, 
    p.workspace_id,
    coalesce(nullif(trim(u.label), ''), u.id::text)
  into v_property_id, v_workspace_id, v_unit_label
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id and u.deleted_at is null;

  if v_property_id is null then
    raise exception 'Unit not found';
  end if;

  -- Ensure the user actually lives here (minimal security shim)
  select exists (
    select 1 from app.tenancies t 
    where t.unit_id = p_unit_id 
      and t.profile_id = v_caller_user_id 
      and t.status = 'active'
  ) into v_has_tenancy;

  if not v_has_tenancy then
    raise exception 'Access denied to this unit setup';
  end if;

  -- Resolve the best active payment setup (unit > property > workspace)
  return query
  with setups as (
    select 
      s.id,
      s.payment_method_type,
      coalesce(nullif(trim(s.display_name), ''), s.account_name) as display_name,
      s.account_name,
      s.paybill_number,
      s.till_number,
      s.send_money_phone,
      coalesce(s.account_reference, v_unit_label) as account_reference,
      s.collection_instructions,
      (case 
        when s.unit_id is not null then 'unit'
        when s.property_id is not null then 'property'
        else 'workspace'
      end) as setup_scope,
      (case 
        when s.unit_id is not null then 1
        when s.property_id is not null then 2
        else 3
      end) as priority
    from app.payment_collection_setups s
    where s.deleted_at is null 
      and s.lifecycle_status = 'active'
      and (
        s.unit_id = p_unit_id or
        (s.property_id = v_property_id and s.unit_id is null) or
        (s.workspace_id = v_workspace_id and s.property_id is null and s.unit_id is null)
      )
    order by priority asc, s.created_at desc
  )
  select 
    s.id,
    s.payment_method_type::text,
    s.display_name,
    s.account_name,
    s.paybill_number,
    s.till_number,
    s.send_money_phone,
    s.account_reference,
    s.collection_instructions,
    s.setup_scope
  from setups s
  limit 1;
end;
$$;
