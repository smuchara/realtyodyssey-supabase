-- ============================================================================
-- V 1 31: Fix create_lease_template property_id access check
-- ============================================================================
-- Bug: V 1 25 create_lease_template used
--   (select property_id from app.properties where id = p_property_id ...)
-- but app.properties has no column named "property_id" — it has "id".
-- This caused every call to fail with "column property_id does not exist"
-- regardless of whether p_property_id was null.
--
-- Fix: pass p_property_id directly to has_tenancy_management_access since
-- p_property_id IS already the property UUID. No subquery needed.
-- ============================================================================

create schema if not exists app;

create or replace function app.create_lease_template(
  p_workspace_id            uuid,
  p_name                    text,
  p_description             text    default null,
  p_lease_type              app.lease_type_enum default 'fixed_term',
  p_property_category       text    default 'apartment',
  p_default_duration_months integer default null,
  p_renewal_behavior        text    default 'manual',
  p_notice_period_days      integer default 30,
  p_property_id             uuid    default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_template_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from app.workspaces w
    where w.id = p_workspace_id
      and (
        w.owner_user_id = auth.uid()
        or exists (
          select 1 from app.workspace_memberships wm
          where wm.workspace_id = p_workspace_id
            and wm.user_id = auth.uid()
            and wm.status = 'active'
        )
      )
  ) then
    raise exception 'Forbidden: you do not have access to this workspace';
  end if;

  -- Fixed: p_property_id IS already the property UUID — no subquery needed.
  if p_property_id is not null and not app.has_tenancy_management_access(p_property_id) then
    raise exception 'Forbidden: you do not have access to this property';
  end if;

  insert into app.lease_templates (
    workspace_id, property_id, name, description, lease_type, property_category,
    default_duration_months, renewal_behavior, notice_period_days, status, created_by
  ) values (
    p_workspace_id,
    p_property_id,
    trim(p_name),
    nullif(trim(coalesce(p_description, '')), ''),
    p_lease_type,
    coalesce(p_property_category, 'apartment'),
    p_default_duration_months,
    coalesce(p_renewal_behavior, 'manual'),
    coalesce(p_notice_period_days, 30),
    'draft',
    auth.uid()
  )
  returning id into v_template_id;

  return jsonb_build_object(
    'template_id', v_template_id,
    'status', 'draft'
  );
end;
$$;
