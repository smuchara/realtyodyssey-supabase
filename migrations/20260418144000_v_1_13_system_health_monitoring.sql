-- ============================================================================
-- V 1 13: System Health Monitoring
-- ============================================================================
-- Purpose:
--   - Track integration health status across the platform
--   - Provide a registry for monitoring payment setup health
--   - Enable backend-integrated health dashboarding
-- ============================================================================

create schema if not exists app;

-- 1. Create type for health statuses if not already present
do $$ begin
  create type app.integration_health_status_enum as enum (
    'healthy', 'failed', 'pending', 'not_configured'
  );
exception when duplicate_object then null; end $$;

-- 2. View to resolve effective payment integration health per unit
create or replace view app.view_unit_payment_integration_health as
with unit_setups as (
  -- Hierarchy: Unit -> Property -> Workspace
  select 
    u.id as unit_id,
    u.property_id,
    p.workspace_id,
    u.label as unit_name,
    p.display_name as property_name,
    -- Resolve effective setup
    coalesce(
      (select s.id from app.payment_collection_setups s where s.unit_id = u.id and s.deleted_at is null and s.lifecycle_status in ('active', 'draft') order by s.lifecycle_status = 'active' desc, s.created_at desc limit 1),
      (select s.id from app.payment_collection_setups s where s.property_id = u.property_id and s.unit_id is null and s.deleted_at is null and s.lifecycle_status in ('active', 'draft') order by s.lifecycle_status = 'active' desc, s.created_at desc limit 1),
      (select s.id from app.payment_collection_setups s where s.workspace_id = p.workspace_id and s.property_id is null and s.unit_id is null and s.deleted_at is null and s.lifecycle_status in ('active', 'draft') order by s.lifecycle_status = 'active' desc, s.created_at desc limit 1)
    ) as effective_setup_id
  from app.units u
  left join app.properties p on p.id = u.property_id
  where u.deleted_at is null
)
select 
  us.unit_id,
  us.unit_name,
  us.property_id,
  us.property_name,
  us.workspace_id,
  us.effective_setup_id,
  s.payment_method_type,
  s.paybill_number,
  s.till_number,
  s.lifecycle_status,
  case 
    when s.id is null then 'not_configured'::app.integration_health_status_enum
    when s.lifecycle_status = 'draft' then 'pending'::app.integration_health_status_enum
    when (s.metadata->>'health_verified')::boolean = false then 'failed'::app.integration_health_status_enum
    else 'healthy'::app.integration_health_status_enum
  end as health_status,
  coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified_at,
  s.metadata->>'health_error' as health_error
from unit_setups us
left join app.payment_collection_setups s on s.id = us.effective_setup_id;

-- 3. RPC to get system health summary for dashboard
create or replace function app.get_system_health_summary()
returns table (
  total_monitored bigint,
  active_count bigint,
  healthy_count bigint,
  failed_count bigint,
  pending_count bigint,
  unconfigured_count bigint
)
language sql
stable
security definer
set search_path = app, public
as $$
  select 
    count(*),
    count(*) filter (where effective_setup_id is not null),
    count(*) filter (where health_status = 'healthy'),
    count(*) filter (where health_status = 'failed'),
    count(*) filter (where health_status = 'pending'),
    count(*) filter (where health_status = 'not_configured')
  from app.view_unit_payment_integration_health;
$$;

-- 4. RPC to get integration health registry for the data table
create or replace function app.get_integration_health_registry()
returns table (
  id uuid,
  scope_type text,
  scope_name text,
  method_type text,
  status text,
  last_verified timestamptz,
  failure_reason text
)
language sql
stable
security definer
set search_path = app, public
as $$
  -- We include portfolio (workspace), properties, and specific units in the registry
  
  -- 1. Workspace Level
  select 
    s.id,
    'Portfolio' as scope_type,
    w.name as scope_name,
    s.payment_method_type::text as method_type,
    case 
      when s.lifecycle_status = 'draft' then 'pending'
      when (s.metadata->>'health_verified')::boolean = false then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.workspaces w on w.id = s.workspace_id
  where s.scope_type = 'workspace' and s.deleted_at is null and s.lifecycle_status in ('active', 'draft')

  union all

  -- 2. Property Level
  select 
    s.id,
    'Property' as scope_type,
    p.display_name as scope_name,
    s.payment_method_type::text as method_type,
    case 
      when s.lifecycle_status = 'draft' then 'pending'
      when (s.metadata->>'health_verified')::boolean = false then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.properties p on p.id = s.property_id
  where s.scope_type = 'property' and s.deleted_at is null and s.lifecycle_status in ('active', 'draft')

  union all

  -- 3. Units that are NOT configured yet (to show gaps)
  select 
    u.id,
    'Unit' as scope_type,
    u.label as scope_name,
    'None' as method_type,
    'not_configured' as status,
    null as last_verified,
    'No direct or inherited setup found' as failure_reason
  from app.units u
  left join app.view_unit_payment_integration_health v on v.unit_id = u.id
  where v.effective_setup_id is null;
$$;

-- 5. RPC to trigger setup verification (placeholder)
create or replace function app.trigger_setup_verification(p_setup_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_setup record;
begin
  select * into v_setup from app.payment_collection_setups where id = p_setup_id;
  if not found then
    raise exception 'Setup not found';
  end if;

  -- Logic to simulate a verification trigger
  update app.payment_collection_setups
  set metadata = jsonb_set(metadata, '{last_verified_at}', to_jsonb(now()::text))
  where id = p_setup_id;

  return jsonb_build_object('success', true, 'message', 'Verification triggered', 'setup_id', p_setup_id);
end;
$$;

grant execute on function app.get_system_health_summary to authenticated;
grant execute on function app.get_integration_health_registry to authenticated;
grant execute on function app.trigger_setup_verification to authenticated;
grant select on app.view_unit_payment_integration_health to authenticated;
