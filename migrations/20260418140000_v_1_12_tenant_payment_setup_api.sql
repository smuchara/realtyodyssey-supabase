-- ============================================================================
-- V 1 12: Tenant Payment Setup API
-- ============================================================================
-- Purpose
--   - Expose a secure, tenant-facing RPC that resolves the active payment
--     collection setup for a given unit.
--   - Return the fields required by the mobile tenant app to render payment
--     details and initiate an STK push against the resolved setup.
--
-- Resolution priority (most specific wins)
--   1. unit scope
--   2. property scope
--   3. workspace scope
--
-- Security
--   - The function is SECURITY DEFINER.
--   - The caller must either:
--       * have a confirmed tenancy for the unit, or
--       * have owner/admin/financial access for preview and management flows.
-- ============================================================================

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

revoke all on function app.get_active_payment_setup_for_tenant(uuid)
  from public, anon, authenticated;

grant execute on function app.get_active_payment_setup_for_tenant(uuid)
  to authenticated;

comment on function app.get_active_payment_setup_for_tenant(uuid) is
  'Returns the best active payment setup for a tenant unit, including the internal setup id required for payment initiation.';
