-- ============================================================================
-- V 1 22: Fix Integration Health Registry - Show All Units
-- ============================================================================
-- Bug:
--   get_integration_health_registry section 3 only returned units where
--   effective_setup_id IS NULL (unconfigured). Units that are healthy via an
--   inherited workspace or property setup were excluded, so the "All" count in
--   the table was lower than the summary card counts.
--
-- Fix:
--   Replace the `where v.effective_setup_id is null` filter with a full scan
--   of view_unit_payment_integration_health so every unit appears as a Unit
--   row regardless of whether its configuration is direct or inherited.
-- ============================================================================

-- Must drop first because V1.20 added short_code / account_reference_hint
-- columns — CREATE OR REPLACE cannot change the return type.
drop function if exists app.get_integration_health_registry();

create or replace function app.get_integration_health_registry()
returns table (
  id                     uuid,
  scope_type             text,
  scope_name             text,
  method_type            text,
  short_code             text,
  account_reference_hint text,
  status                 text,
  last_verified          timestamptz,
  failure_reason         text
)
language sql
stable
security definer
set search_path = app, public
as $$
  -- 1. Portfolio (workspace) level setups
  select
    s.id,
    'Portfolio'             as scope_type,
    w.name                  as scope_name,
    s.payment_method_type::text as method_type,
    coalesce(s.paybill_number, s.till_number, s.send_money_phone_number) as short_code,
    s.account_reference_hint,
    case
      when s.lifecycle_status = 'draft'                             then 'pending'
      when (s.metadata->>'health_verified')::boolean = false        then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.workspaces w on w.id = s.workspace_id
  where s.scope_type = 'workspace'
    and s.deleted_at is null
    and s.lifecycle_status in ('active', 'draft')

  union all

  -- 2. Property level setups
  select
    s.id,
    'Property'              as scope_type,
    p.display_name          as scope_name,
    s.payment_method_type::text as method_type,
    coalesce(s.paybill_number, s.till_number, s.send_money_phone_number) as short_code,
    s.account_reference_hint,
    case
      when s.lifecycle_status = 'draft'                             then 'pending'
      when (s.metadata->>'health_verified')::boolean = false        then 'failed'
      else 'healthy'
    end as status,
    coalesce((s.metadata->>'last_verified_at')::timestamptz, s.updated_at) as last_verified,
    s.metadata->>'health_error' as failure_reason
  from app.payment_collection_setups s
  join app.properties p on p.id = s.property_id
  where s.scope_type = 'property'
    and s.deleted_at is null
    and s.lifecycle_status in ('active', 'draft')

  union all

  -- 3. All units — both configured (healthy/failed/pending) and unconfigured.
  --    view_unit_payment_integration_health resolves the effective setup for
  --    every unit via the Unit → Property → Workspace inheritance chain, so
  --    this is the single authoritative per-unit status.
  select
    v.unit_id                                                        as id,
    'Unit'                                                           as scope_type,
    v.unit_name                                                      as scope_name,
    case
      when v.effective_setup_id is null then 'None'
      else coalesce(v.payment_method_type::text, 'None')
    end                                                              as method_type,
    coalesce(v.paybill_number, v.till_number)                        as short_code,
    null::text                                                       as account_reference_hint,
    v.health_status::text                                            as status,
    v.last_verified_at                                               as last_verified,
    case
      when v.effective_setup_id is null then 'No direct or inherited setup found'
      else v.health_error
    end                                                              as failure_reason
  from app.view_unit_payment_integration_health v;
$$;

grant execute on function app.get_integration_health_registry() to authenticated;
