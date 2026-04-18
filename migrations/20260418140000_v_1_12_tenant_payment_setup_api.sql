-- ============================================================================
-- V 1 12: Tenant Payment Setup API
-- ============================================================================
-- Purpose
--   Expose a secure, tenant-facing RPC that resolves the active payment
--   collection setup for a given unit and returns the fields needed to
--   display an M-Pesa payment prompt in the Flutter tenant app.
--
-- Resolution priority (most specific wins):
--   1. unit scope   — setup scoped directly to the unit
--   2. property scope — setup scoped to the unit's parent property
--   3. workspace scope — setup scoped to the workspace that owns the property
--
-- Security
--   The function is SECURITY DEFINER but validates that the caller is an
--   authenticated tenant with a confirmed tenancy for the requested unit.
--   No internal IDs (workspace_id, setup_id) are returned.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- RPC: get_active_payment_setup_for_tenant
-- ---------------------------------------------------------------------------
create or replace function app.get_active_payment_setup_for_tenant(
  p_unit_id uuid
)
returns table (
  payment_method_type   text,
  display_name          text,
  account_name          text,
  paybill_number        text,
  till_number           text,
  send_money_phone      text,
  account_reference     text,   -- hint pre-filled with unit label if not explicit
  collection_instructions text,
  setup_scope           text    -- 'unit' | 'property' | 'workspace'
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
    -- unit_label is the human-readable identifier (e.g. "A1", "Bedsitter 3")
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

  -- Verify the caller is a confirmed tenant of that unit.
  -- Check unit_tenancies (active tenancy record) OR the occupancy snapshot
  -- current_tenant_user_id (set when occupancy_status = 'occupied').
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



  -- Also allow workspace owners/admins to call this (for admin previewing the tenant experience)
  if not v_has_tenancy then
    if not (
      app.is_workspace_owner(v_workspace_id)
      or app.is_workspace_admin(v_workspace_id)
      or app.has_financial_management_access(v_property_id)
    ) then
      raise exception 'Forbidden: no confirmed tenancy for this unit';
    end if;
  end if;

  -- Resolve the best active payment setup (unit > property > workspace)
  return query
  select
    s.payment_method_type::text,
    coalesce(nullif(trim(s.display_name), ''), s.account_name) as display_name,
    s.account_name,
    s.paybill_number,
    s.till_number,
    s.send_money_phone_number as send_money_phone,
    -- Use explicit reference hint, or fall back to the unit label
    coalesce(
      nullif(trim(s.account_reference_hint), ''),
      v_unit_label
    ) as account_reference,
    s.collection_instructions,
    s.scope_type::text as setup_scope
  from app.payment_collection_setups s
  where s.deleted_at is null
    and s.lifecycle_status = 'active'
    and (
      (s.scope_type = 'unit'      and s.unit_id     = p_unit_id)
      or (s.scope_type = 'property' and s.property_id  = v_property_id)
      or (s.scope_type = 'workspace' and s.workspace_id = v_workspace_id)
    )
  order by
    case s.scope_type
      when 'unit'      then 1
      when 'property'  then 2
      when 'workspace' then 3
      else 4
    end asc,
    s.is_default desc,
    s.priority_rank asc,
    s.created_at desc
  limit 1;
end;
$$;

-- Revoke from all roles first, then grant only to authenticated (tenants + owners)
revoke all on function app.get_active_payment_setup_for_tenant(uuid)
  from public, anon, authenticated;

grant execute on function app.get_active_payment_setup_for_tenant(uuid)
  to authenticated;

comment on function app.get_active_payment_setup_for_tenant(uuid) is
  'Returns the best active M-Pesa payment setup for a tenant''s unit. '
  'Resolves unit → property → workspace scope. '
  'Caller must have a confirmed tenancy or financial management access.';
