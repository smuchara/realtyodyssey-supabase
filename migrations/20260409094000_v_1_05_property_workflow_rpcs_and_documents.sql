-- ============================================================================
-- V 1 05: Property Workflow RPCs and Documents
-- ============================================================================
-- Purpose
--   - Define the property onboarding workflow RPC surface
--   - Preserve app-facing RPC contracts used by the current web flows
--   - Create secure property document storage helpers and bucket policies
--   - Consolidate activation, soft-delete, ownership, and accountability logic
--   - Provide onboarding prefill RPCs used by the UI
--
-- Notes
--   - This migration intentionally keeps the current RPC names stable.
--   - Unit RPC parameter names preserve the live contract:
--       p_water_meter_no / p_electricity_meter_no
--     while writing into the canonical unit columns:
--       water_meter_number / electricity_meter_number
--   - Collaboration-aware step editing is intentionally deferred to V 1 06.
-- ============================================================================

create schema if not exists app;
create schema if not exists public;

-- ============================================================================
-- Internal lookup helpers used by workflow RPCs
-- ============================================================================

create or replace function app.get_document_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select dt.id
  from app.lookup_document_types dt
  where dt.code = p_code
    and dt.deleted_at is null
    and dt.is_active = true
  limit 1;
$$;

create or replace function app.get_relationship_role_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select rr.id
  from app.lookup_relationship_roles rr
  where rr.code = p_code
    and rr.deleted_at is null
    and rr.is_active = true
  limit 1;
$$;

create or replace function app.get_unit_preset_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select up.id
  from app.lookup_unit_presets up
  where up.code = p_code
    and up.deleted_at is null
    and up.is_active = true
  limit 1;
$$;

create or replace function app.get_home_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select ht.id
  from app.lookup_home_types ht
  where ht.code = p_code
    and ht.deleted_at is null
    and ht.is_active = true
  limit 1;
$$;

create or replace function app.get_lift_access_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select la.id
  from app.lookup_lift_access_types la
  where la.code = p_code
    and la.deleted_at is null
    and la.is_active = true
  limit 1;
$$;

create or replace function app.get_waste_disposal_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select wd.id
  from app.lookup_waste_disposal_types wd
  where wd.code = p_code
    and wd.deleted_at is null
    and wd.is_active = true
  limit 1;
$$;

create or replace function app.get_layout_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select lt.id
  from app.lookup_layout_types lt
  where lt.code = p_code
    and lt.deleted_at is null
    and lt.is_active = true
  limit 1;
$$;

revoke all on function app.get_document_type_id_by_code(text) from public, authenticated;
revoke all on function app.get_relationship_role_id_by_code(text) from public, authenticated;
revoke all on function app.get_unit_preset_id_by_code(text) from public, authenticated;
revoke all on function app.get_home_type_id_by_code(text) from public, authenticated;
revoke all on function app.get_lift_access_type_id_by_code(text) from public, authenticated;
revoke all on function app.get_waste_disposal_type_id_by_code(text) from public, authenticated;
revoke all on function app.get_layout_type_id_by_code(text) from public, authenticated;

-- ============================================================================
-- Property draft and identity workflow
-- ============================================================================

create or replace function app.create_property_draft(
  p_workspace_id uuid,
  p_property_type_code text,
  p_display_name text
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_property_type_id uuid;
  v_session_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.is_workspace_owner(p_workspace_id) then
    raise exception 'Only workspace owner can create properties';
  end if;

  if p_display_name is null or char_length(trim(p_display_name)) < 2 then
    raise exception 'Invalid property display name';
  end if;

  v_property_type_id := app.get_property_type_id_by_code(trim(p_property_type_code));

  if v_property_type_id is null then
    raise exception 'Invalid property type code: %', p_property_type_code;
  end if;

  insert into app.properties (
    workspace_id,
    property_type_id,
    display_name,
    created_by
  )
  values (
    p_workspace_id,
    v_property_type_id,
    trim(p_display_name),
    auth.uid()
  )
  returning id into v_property_id;

  insert into app.property_onboarding_sessions (
    property_id,
    started_by
  )
  values (
    v_property_id,
    auth.uid()
  )
  returning id into v_session_id;

  insert into app.property_onboarding_step_states (
    session_id,
    step_key,
    status
  )
  values
    (v_session_id, 'identity', 'in_progress'),
    (v_session_id, 'usage', 'not_started'),
    (v_session_id, 'structure', 'not_started'),
    (v_session_id, 'ownership', 'not_started'),
    (v_session_id, 'accountability', 'not_started'),
    (v_session_id, 'review', 'not_started');

  perform app.touch_property_activity(v_property_id);

  return v_property_id;
end;
$$;

revoke all on function app.create_property_draft(uuid, text, text) from public;
grant execute on function app.create_property_draft(uuid, text, text) to authenticated;

create or replace function app.get_latest_draft_property(
  p_workspace_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.is_workspace_owner(p_workspace_id) then
    raise exception 'Only workspace owner can read draft properties';
  end if;

  select p.id
    into v_property_id
  from app.properties p
  where p.workspace_id = p_workspace_id
    and p.status = 'draft'
    and p.onboarding_completed_at is null
    and p.deleted_at is null
  order by p.created_at desc
  limit 1;

  return v_property_id;
end;
$$;

revoke all on function app.get_latest_draft_property(uuid) from public;
grant execute on function app.get_latest_draft_property(uuid) to authenticated;

create or replace function app.update_property_identity(
  p_property_id uuid,
  p_internal_ref_code text default null,
  p_city_town text default null,
  p_area_neighborhood text default null,
  p_address_description text default null,
  p_map_source_code text default null,
  p_place_id text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_map_label text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_map_source_id uuid;
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);
  perform app.assert_property_onboarding_open(p_property_id);

  if p_map_source_code is not null and char_length(trim(p_map_source_code)) > 0 then
    v_map_source_id := app.get_map_source_id_by_code(trim(p_map_source_code));

    if v_map_source_id is null then
      raise exception 'Invalid map source code: %', p_map_source_code;
    end if;
  end if;

  update app.properties
     set internal_ref_code = nullif(trim(p_internal_ref_code), ''),
         city_town = nullif(trim(p_city_town), ''),
         area_neighborhood = nullif(trim(p_area_neighborhood), ''),
         address_description = nullif(trim(p_address_description), ''),
         map_source_id = v_map_source_id,
         place_id = nullif(trim(p_place_id), ''),
         latitude = p_latitude,
         longitude = p_longitude,
         map_label = nullif(trim(p_map_label), ''),
         identity_completed_at = now(),
         current_step_key = 'usage',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or deleted';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = auth.uid(),
         completed_at = coalesce(completed_at, now()),
         data_snapshot = jsonb_build_object(
           'internalRefCode', nullif(trim(p_internal_ref_code), ''),
           'cityTown', nullif(trim(p_city_town), ''),
           'areaNeighborhood', nullif(trim(p_area_neighborhood), ''),
           'addressDescription', nullif(trim(p_address_description), ''),
           'mapSourceCode', nullif(trim(p_map_source_code), ''),
           'placeId', nullif(trim(p_place_id), ''),
           'latitude', p_latitude,
           'longitude', p_longitude,
           'mapLabel', nullif(trim(p_map_label), '')
         ),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'identity'
     and deleted_at is null;

  update app.property_onboarding_sessions
     set current_step_key = 'usage',
         last_activity_at = now()
   where id = v_session_id
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'usage'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'identity',
        'next_step', 'usage'
      )
    );
  end if;
end;
$$;

revoke all on function app.update_property_identity(
  uuid, text, text, text, text, text, text, double precision, double precision, text
) from public;
grant execute on function app.update_property_identity(
  uuid, text, text, text, text, text, text, double precision, double precision, text
) to authenticated;

create or replace function app.update_property_usage(
  p_property_id uuid,
  p_usage_type_code text
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_usage_type_id uuid;
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);
  perform app.assert_property_onboarding_open(p_property_id);

  if p_usage_type_code is null or char_length(trim(p_usage_type_code)) = 0 then
    raise exception 'usage_type_code is required';
  end if;

  v_usage_type_id := app.get_usage_type_id_by_code(trim(p_usage_type_code));

  if v_usage_type_id is null then
    raise exception 'Invalid usage type code: %', p_usage_type_code;
  end if;

  update app.properties
     set usage_type_id = v_usage_type_id,
         current_step_key = 'structure',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or deleted';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'structure',
         last_activity_at = now()
   where id = v_session_id
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = auth.uid(),
         completed_at = coalesce(completed_at, now()),
         data_snapshot = jsonb_build_object(
           'usageTypeCode', trim(p_usage_type_code)
         ),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'usage'
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'structure'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'usage',
        'usage_type_code', trim(p_usage_type_code),
        'next_step', 'structure'
      )
    );
  end if;
end;
$$;

revoke all on function app.update_property_usage(uuid, text) from public;
grant execute on function app.update_property_usage(uuid, text) to authenticated;

-- ============================================================================
-- Structure and unit workflow
-- ============================================================================

create or replace function app.create_unit(
  p_property_id uuid,
  p_label text default null,
  p_floor text default null,
  p_block text default null,
  p_preset_code text default null,
  p_home_type_code text default null,
  p_bedrooms integer default 0,
  p_bathrooms integer default 0,
  p_parking integer default 0,
  p_balconies integer default 0,
  p_lift_access_code text default null,
  p_garage_slots integer default 0,
  p_waste_disposal_code text default null,
  p_layout_code text default null,
  p_expected_rate numeric default null,
  p_notes text default null,
  p_water_meter_no text default null,
  p_electricity_meter_no text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_id uuid;
  v_preset_id uuid;
  v_home_type_id uuid;
  v_lift_access_type_id uuid;
  v_waste_disposal_type_id uuid;
  v_layout_type_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'UNITS') then
    raise exception 'Missing domain scope: UNITS';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  if p_preset_code is not null and char_length(trim(p_preset_code)) > 0 then
    v_preset_id := app.get_unit_preset_id_by_code(trim(p_preset_code));
    if v_preset_id is null then
      raise exception 'Invalid preset code: %', p_preset_code;
    end if;
  end if;

  if p_home_type_code is not null and char_length(trim(p_home_type_code)) > 0 then
    v_home_type_id := app.get_home_type_id_by_code(trim(p_home_type_code));
    if v_home_type_id is null then
      raise exception 'Invalid home type code: %', p_home_type_code;
    end if;
  end if;

  if p_lift_access_code is not null and char_length(trim(p_lift_access_code)) > 0 then
    v_lift_access_type_id := app.get_lift_access_type_id_by_code(trim(p_lift_access_code));
    if v_lift_access_type_id is null then
      raise exception 'Invalid lift access code: %', p_lift_access_code;
    end if;
  end if;

  if p_waste_disposal_code is not null and char_length(trim(p_waste_disposal_code)) > 0 then
    v_waste_disposal_type_id := app.get_waste_disposal_type_id_by_code(trim(p_waste_disposal_code));
    if v_waste_disposal_type_id is null then
      raise exception 'Invalid waste disposal code: %', p_waste_disposal_code;
    end if;
  end if;

  if p_layout_code is not null and char_length(trim(p_layout_code)) > 0 then
    v_layout_type_id := app.get_layout_type_id_by_code(trim(p_layout_code));
    if v_layout_type_id is null then
      raise exception 'Invalid layout code: %', p_layout_code;
    end if;
  end if;

  insert into app.units (
    property_id,
    label,
    floor,
    block,
    preset_id,
    home_type_id,
    bedrooms,
    bathrooms,
    parking,
    balconies,
    lift_access_type_id,
    garage_slots,
    waste_disposal_type_id,
    layout_type_id,
    expected_rate,
    notes,
    water_meter_number,
    electricity_meter_number
  )
  values (
    p_property_id,
    nullif(trim(p_label), ''),
    nullif(trim(p_floor), ''),
    nullif(trim(p_block), ''),
    v_preset_id,
    v_home_type_id,
    greatest(coalesce(p_bedrooms, 0), 0),
    greatest(coalesce(p_bathrooms, 0), 0),
    greatest(coalesce(p_parking, 0), 0),
    greatest(coalesce(p_balconies, 0), 0),
    v_lift_access_type_id,
    greatest(coalesce(p_garage_slots, 0), 0),
    v_waste_disposal_type_id,
    v_layout_type_id,
    p_expected_rate,
    nullif(trim(p_notes), ''),
    nullif(trim(p_water_meter_no), ''),
    nullif(trim(p_electricity_meter_no), '')
  )
  returning id into v_unit_id;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('UNIT_CREATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      unit_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      v_unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'label', nullif(trim(p_label), ''),
        'water_meter_number', nullif(trim(p_water_meter_no), ''),
        'electricity_meter_number', nullif(trim(p_electricity_meter_no), '')
      )
    );
  end if;

  return v_unit_id;
end;
$$;

revoke all on function app.create_unit(
  uuid, text, text, text, text, text, integer, integer, integer, integer, text, integer, text, text, numeric, text, text, text
) from public;
grant execute on function app.create_unit(
  uuid, text, text, text, text, text, integer, integer, integer, integer, text, integer, text, text, numeric, text, text, text
) to authenticated;

create or replace function app.update_unit(
  p_unit_id uuid,
  p_label text default null,
  p_floor text default null,
  p_block text default null,
  p_preset_code text default null,
  p_home_type_code text default null,
  p_bedrooms integer default null,
  p_bathrooms integer default null,
  p_parking integer default null,
  p_balconies integer default null,
  p_lift_access_code text default null,
  p_garage_slots integer default null,
  p_waste_disposal_code text default null,
  p_layout_code text default null,
  p_expected_rate numeric default null,
  p_notes text default null,
  p_water_meter_no text default null,
  p_electricity_meter_no text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_preset_id uuid;
  v_home_type_id uuid;
  v_lift_access_type_id uuid;
  v_waste_disposal_type_id uuid;
  v_layout_type_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select u.property_id
    into v_property_id
  from app.units u
  where u.id = p_unit_id
    and u.deleted_at is null;

  if v_property_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  if not app.has_domain_scope(v_property_id, 'UNITS') then
    raise exception 'Missing domain scope: UNITS';
  end if;

  perform app.assert_property_onboarding_open(v_property_id);

  if p_preset_code is not null and char_length(trim(p_preset_code)) > 0 then
    v_preset_id := app.get_unit_preset_id_by_code(trim(p_preset_code));
    if v_preset_id is null then
      raise exception 'Invalid preset code: %', p_preset_code;
    end if;
  end if;

  if p_home_type_code is not null and char_length(trim(p_home_type_code)) > 0 then
    v_home_type_id := app.get_home_type_id_by_code(trim(p_home_type_code));
    if v_home_type_id is null then
      raise exception 'Invalid home type code: %', p_home_type_code;
    end if;
  end if;

  if p_lift_access_code is not null and char_length(trim(p_lift_access_code)) > 0 then
    v_lift_access_type_id := app.get_lift_access_type_id_by_code(trim(p_lift_access_code));
    if v_lift_access_type_id is null then
      raise exception 'Invalid lift access code: %', p_lift_access_code;
    end if;
  end if;

  if p_waste_disposal_code is not null and char_length(trim(p_waste_disposal_code)) > 0 then
    v_waste_disposal_type_id := app.get_waste_disposal_type_id_by_code(trim(p_waste_disposal_code));
    if v_waste_disposal_type_id is null then
      raise exception 'Invalid waste disposal code: %', p_waste_disposal_code;
    end if;
  end if;

  if p_layout_code is not null and char_length(trim(p_layout_code)) > 0 then
    v_layout_type_id := app.get_layout_type_id_by_code(trim(p_layout_code));
    if v_layout_type_id is null then
      raise exception 'Invalid layout code: %', p_layout_code;
    end if;
  end if;

  update app.units
     set label = case when p_label is null then label else nullif(trim(p_label), '') end,
         floor = case when p_floor is null then floor else nullif(trim(p_floor), '') end,
         block = case when p_block is null then block else nullif(trim(p_block), '') end,
         preset_id = case
           when p_preset_code is null then preset_id
           when char_length(trim(p_preset_code)) = 0 then null
           else v_preset_id
         end,
         home_type_id = case
           when p_home_type_code is null then home_type_id
           when char_length(trim(p_home_type_code)) = 0 then null
           else v_home_type_id
         end,
         bedrooms = case when p_bedrooms is null then bedrooms else greatest(p_bedrooms, 0) end,
         bathrooms = case when p_bathrooms is null then bathrooms else greatest(p_bathrooms, 0) end,
         parking = case when p_parking is null then parking else greatest(p_parking, 0) end,
         balconies = case when p_balconies is null then balconies else greatest(p_balconies, 0) end,
         lift_access_type_id = case
           when p_lift_access_code is null then lift_access_type_id
           when char_length(trim(p_lift_access_code)) = 0 then null
           else v_lift_access_type_id
         end,
         garage_slots = case when p_garage_slots is null then garage_slots else greatest(p_garage_slots, 0) end,
         waste_disposal_type_id = case
           when p_waste_disposal_code is null then waste_disposal_type_id
           when char_length(trim(p_waste_disposal_code)) = 0 then null
           else v_waste_disposal_type_id
         end,
         layout_type_id = case
           when p_layout_code is null then layout_type_id
           when char_length(trim(p_layout_code)) = 0 then null
           else v_layout_type_id
         end,
         expected_rate = case when p_expected_rate is null then expected_rate else p_expected_rate end,
         notes = case when p_notes is null then notes else nullif(trim(p_notes), '') end,
         water_meter_number = case
           when p_water_meter_no is null then water_meter_number
           else nullif(trim(p_water_meter_no), '')
         end,
         electricity_meter_number = case
           when p_electricity_meter_no is null then electricity_meter_number
           else nullif(trim(p_electricity_meter_no), '')
         end
   where id = p_unit_id
     and deleted_at is null;

  if not found then
    raise exception 'Unit not found or deleted';
  end if;

  perform app.touch_property_activity(v_property_id);

  v_action_id := app.get_audit_action_id_by_code('UNIT_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      unit_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      v_property_id,
      p_unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'action', 'update_unit',
        'label', p_label,
        'water_meter_number', p_water_meter_no,
        'electricity_meter_number', p_electricity_meter_no
      )
    );
  end if;
end;
$$;

revoke all on function app.update_unit(
  uuid, text, text, text, text, text, integer, integer, integer, integer, text, integer, text, text, numeric, text, text, text
) from public;
grant execute on function app.update_unit(
  uuid, text, text, text, text, text, integer, integer, integer, integer, text, integer, text, text, numeric, text, text, text
) to authenticated;

create or replace function app.upsert_primary_structure_unit(
  p_property_id uuid,
  p_label text default 'MAIN',
  p_floor text default null,
  p_block text default null,
  p_preset_code text default null,
  p_home_type_code text default null,
  p_bedrooms integer default 0,
  p_bathrooms integer default 0,
  p_parking integer default 0,
  p_balconies integer default 0,
  p_lift_access_code text default null,
  p_garage_slots integer default 0,
  p_waste_disposal_code text default null,
  p_layout_code text default null,
  p_expected_rate numeric default null,
  p_notes text default null,
  p_water_meter_no text default null,
  p_electricity_meter_no text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_type_code text;
  v_existing_unit_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'UNITS') then
    raise exception 'Missing domain scope: UNITS';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  select pt.code
    into v_property_type_code
  from app.properties p
  join app.lookup_property_types pt
    on pt.id = p.property_type_id
  where p.id = p_property_id
    and p.deleted_at is null
    and pt.deleted_at is null
  limit 1;

  if v_property_type_code is null then
    raise exception 'Property not found or property type missing';
  end if;

  if v_property_type_code <> 'HOUSE' then
    raise exception 'upsert_primary_structure_unit is only valid for HOUSE properties';
  end if;

  select u.id
    into v_existing_unit_id
  from app.units u
  where u.property_id = p_property_id
    and u.deleted_at is null
  order by u.created_at asc
  limit 1;

  if v_existing_unit_id is null then
    return app.create_unit(
      p_property_id,
      coalesce(nullif(trim(p_label), ''), 'MAIN'),
      p_floor,
      p_block,
      p_preset_code,
      p_home_type_code,
      p_bedrooms,
      p_bathrooms,
      p_parking,
      p_balconies,
      p_lift_access_code,
      p_garage_slots,
      p_waste_disposal_code,
      p_layout_code,
      p_expected_rate,
      p_notes,
      p_water_meter_no,
      p_electricity_meter_no
    );
  end if;

  perform app.update_unit(
    v_existing_unit_id,
    coalesce(nullif(trim(p_label), ''), 'MAIN'),
    p_floor,
    p_block,
    p_preset_code,
    p_home_type_code,
    p_bedrooms,
    p_bathrooms,
    p_parking,
    p_balconies,
    p_lift_access_code,
    p_garage_slots,
    p_waste_disposal_code,
    p_layout_code,
    p_expected_rate,
    p_notes,
    p_water_meter_no,
    p_electricity_meter_no
  );

  return v_existing_unit_id;
end;
$$;

revoke all on function app.upsert_primary_structure_unit(
  uuid, text, text, text, text, text, integer, integer, integer, integer, text, integer, text, text, numeric, text, text, text
) from public;
grant execute on function app.upsert_primary_structure_unit(
  uuid, text, text, text, text, text, integer, integer, integer, integer, text, integer, text, text, numeric, text, text, text
) to authenticated;

create or replace function app.complete_structure_step(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_type_code text;
  v_unit_count integer;
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'UNITS') then
    raise exception 'Missing domain scope: UNITS';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  select pt.code
    into v_property_type_code
  from app.properties p
  join app.lookup_property_types pt
    on pt.id = p.property_type_id
  where p.id = p_property_id
    and p.deleted_at is null
    and pt.deleted_at is null
  limit 1;

  if v_property_type_code is null then
    raise exception 'Property not found or property type missing';
  end if;

  select count(*)
    into v_unit_count
  from app.units u
  where u.property_id = p_property_id
    and u.deleted_at is null;

  if v_property_type_code in ('APARTMENT', 'HOUSE') and coalesce(v_unit_count, 0) < 1 then
    raise exception 'Add at least 1 structure unit before completing the Structure step';
  end if;

  update app.properties
     set current_step_key = 'ownership',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or deleted';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'ownership',
         last_activity_at = now()
   where id = v_session_id
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = auth.uid(),
         completed_at = coalesce(completed_at, now()),
         data_snapshot = jsonb_build_object(
           'propertyTypeCode', v_property_type_code,
           'unitCount', coalesce(v_unit_count, 0)
         ),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'structure'
     and deleted_at is null;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'ownership'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'structure',
        'next_step', 'ownership',
        'property_type', v_property_type_code,
        'unit_count', coalesce(v_unit_count, 0)
      )
    );
  end if;
end;
$$;

revoke all on function app.complete_structure_step(uuid) from public;
grant execute on function app.complete_structure_step(uuid) to authenticated;

-- ============================================================================
-- Property documents, ownership step, and storage policies
-- ============================================================================

create or replace function public.storage_first_segment(p_object_name text)
returns text
language sql
stable
as $$
  select (storage.foldername(p_object_name))[1];
$$;

comment on function public.storage_first_segment(text)
is 'Returns the first folder segment of a storage object path. Example: <property_id>/file.pdf -> <property_id>.';

create or replace function public.is_valid_property_path(
  p_object_name text,
  p_expected_property_id uuid
)
returns boolean
language sql
stable
as $$
  select public.storage_first_segment(p_object_name) = p_expected_property_id::text;
$$;

comment on function public.is_valid_property_path(text, uuid)
is 'Returns true when the first folder segment of a storage object path matches the supplied property_id.';

revoke all on function public.storage_first_segment(text) from public;
revoke all on function public.is_valid_property_path(text, uuid) from public;
grant execute on function public.storage_first_segment(text) to authenticated, service_role;
grant execute on function public.is_valid_property_path(text, uuid) to authenticated, service_role;

insert into storage.buckets (id, name, public)
values ('property-documents', 'property-documents', false)
on conflict (id) do update
set public = false;

drop policy if exists property_documents_insert on storage.objects;
create policy property_documents_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'property-documents'
  and auth.uid() is not null
  and public.storage_first_segment(name) is not null
  and public.storage_first_segment(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and (
    app.is_property_workspace_owner((public.storage_first_segment(name))::uuid)
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'FULL_PROPERTY')
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'OWNERSHIP')
  )
);

drop policy if exists property_documents_select on storage.objects;
create policy property_documents_select
on storage.objects
for select
to authenticated
using (false);

drop policy if exists property_documents_delete on storage.objects;
create policy property_documents_delete
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'property-documents'
  and auth.uid() is not null
  and public.storage_first_segment(name) is not null
  and public.storage_first_segment(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and (
    owner = auth.uid()
    or app.is_property_workspace_owner((public.storage_first_segment(name))::uuid)
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'FULL_PROPERTY')
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'OWNERSHIP')
  )
);

drop policy if exists property_documents_update on storage.objects;
create policy property_documents_update
on storage.objects
for update
to authenticated
using (
  bucket_id = 'property-documents'
  and auth.uid() is not null
  and public.storage_first_segment(name) is not null
  and public.storage_first_segment(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and (
    owner = auth.uid()
    or app.is_property_workspace_owner((public.storage_first_segment(name))::uuid)
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'FULL_PROPERTY')
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'OWNERSHIP')
  )
)
with check (
  bucket_id = 'property-documents'
  and auth.uid() is not null
  and public.storage_first_segment(name) is not null
  and public.storage_first_segment(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and (
    owner = auth.uid()
    or app.is_property_workspace_owner((public.storage_first_segment(name))::uuid)
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'FULL_PROPERTY')
    or app.has_domain_scope((public.storage_first_segment(name))::uuid, 'OWNERSHIP')
  )
);

create or replace function app.create_property_document(
  p_property_id uuid,
  p_document_type_code text,
  p_storage_path text,
  p_file_name text default null,
  p_mime_type text default null,
  p_size_bytes bigint default null,
  p_unit_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_document_id uuid;
  v_document_type_id uuid;
  v_session_id uuid;
  v_action_id uuid;
  v_now timestamptz := now();
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'OWNERSHIP') then
    raise exception 'Missing domain scope: OWNERSHIP';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  if p_document_type_code is null or char_length(trim(p_document_type_code)) = 0 then
    raise exception 'document_type_code is required';
  end if;

  if p_storage_path is null or char_length(trim(p_storage_path)) < 5 then
    raise exception 'storage_path is required';
  end if;

  if not public.is_valid_property_path(trim(p_storage_path), p_property_id) then
    raise exception 'storage_path must begin with the property_id folder';
  end if;

  v_document_type_id := app.get_document_type_id_by_code(trim(p_document_type_code));

  if v_document_type_id is null then
    raise exception 'Invalid document type code: %', p_document_type_code;
  end if;

  if p_unit_id is not null then
    if not exists (
      select 1
      from app.units u
      where u.id = p_unit_id
        and u.property_id = p_property_id
        and u.deleted_at is null
    ) then
      raise exception 'Invalid unit_id for this property';
    end if;
  end if;

  insert into app.property_documents (
    property_id,
    unit_id,
    document_type_id,
    storage_path,
    file_name,
    mime_type,
    size_bytes,
    uploaded_by
  )
  values (
    p_property_id,
    p_unit_id,
    v_document_type_id,
    trim(p_storage_path),
    nullif(trim(p_file_name), ''),
    nullif(trim(p_mime_type), ''),
    p_size_bytes,
    auth.uid()
  )
  returning id into v_document_id;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = coalesce(completed_by, auth.uid()),
         completed_at = coalesce(completed_at, v_now),
         data_snapshot = case
           when coalesce(data_snapshot, '{}'::jsonb) = '{}'::jsonb then
             jsonb_build_object(
               'first_document_id', v_document_id,
               'last_document_id', v_document_id,
               'at', v_now
             )
           else
             data_snapshot || jsonb_build_object(
               'last_document_id', v_document_id,
               'at', v_now
             )
         end,
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'ownership'
     and deleted_at is null;

  update app.property_onboarding_sessions
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = v_session_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.properties
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = p_property_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'accountability'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('DOC_UPLOADED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'document_id', v_document_id,
        'document_type', trim(p_document_type_code),
        'storage_path', trim(p_storage_path),
        'unit_id', p_unit_id
      )
    );
  end if;

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'ownership',
        'next_step', 'accountability',
        'document_id', v_document_id
      )
    );
  end if;

  return v_document_id;
end;
$$;

revoke all on function app.create_property_document(
  uuid, text, text, text, text, bigint, uuid
) from public;
grant execute on function app.create_property_document(
  uuid, text, text, text, text, bigint, uuid
) to authenticated;

create or replace function app.soft_delete_property_document(
  p_document_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select d.property_id
    into v_property_id
  from app.property_documents d
  where d.id = p_document_id
    and d.deleted_at is null;

  if v_property_id is null then
    raise exception 'Document not found or already deleted';
  end if;

  if not app.has_domain_scope(v_property_id, 'OWNERSHIP') then
    raise exception 'Missing domain scope: OWNERSHIP';
  end if;

  perform app.assert_property_onboarding_open(v_property_id);

  update app.property_documents
     set deleted_at = now(),
         deleted_by = auth.uid()
   where id = p_document_id
     and deleted_at is null;

  if not found then
    raise exception 'Document not found or already deleted';
  end if;

  perform app.touch_property_activity(v_property_id);

  v_action_id := app.get_audit_action_id_by_code('DOCUMENT_DELETED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      v_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'document_id', p_document_id,
        'reason', nullif(trim(p_reason), '')
      )
    );
  end if;
end;
$$;

revoke all on function app.soft_delete_property_document(uuid, text) from public;
grant execute on function app.soft_delete_property_document(uuid, text) to authenticated;

create or replace function app.complete_ownership_step(
  p_property_id uuid,
  p_snapshot jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_now timestamptz := now();
  v_step_rows integer := 0;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'OWNERSHIP') then
    raise exception 'Missing domain scope: OWNERSHIP';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = coalesce(completed_by, auth.uid()),
         completed_at = coalesce(completed_at, v_now),
         data_snapshot = coalesce(p_snapshot, '{}'::jsonb),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'ownership'
     and deleted_at is null;

  get diagnostics v_step_rows = row_count;
  if v_step_rows = 0 then
    raise exception 'Ownership step state not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = v_session_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.properties
     set current_step_key = 'accountability',
         last_activity_at = v_now
   where id = p_property_id
     and deleted_at is null
     and current_step_key not in ('review', 'done');

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'accountability'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'ownership',
        'next_step', 'accountability'
      )
    );
  end if;
end;
$$;

revoke all on function app.complete_ownership_step(uuid, jsonb) from public;
grant execute on function app.complete_ownership_step(uuid, jsonb) to authenticated;

-- ============================================================================
-- Accountability, PCA, activation, deletion, and prefills
-- ============================================================================

create or replace function app.upsert_property_admin_contact(
  p_property_id uuid,
  p_mode text default 'SELF',
  p_relationship_role_code text default null,
  p_contact_name text default null,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_notes text default null,
  p_mark_step_completed boolean default true
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_mode text := upper(coalesce(nullif(trim(p_mode), ''), 'SELF'));
  v_relationship_role_id uuid;
  v_contact_name text;
  v_contact_email text;
  v_contact_phone text;
  v_notes text;
  v_session_id uuid;
  v_step_rows integer := 0;
  v_session_rows integer := 0;
  v_property_rows integer := 0;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'ACCOUNTABILITY') then
    raise exception 'Missing domain scope: ACCOUNTABILITY';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  if v_mode not in ('SELF', 'DELEGATED') then
    raise exception 'Invalid accountability mode: %', p_mode;
  end if;

  if v_mode = 'DELEGATED' then
    v_contact_name := nullif(trim(p_contact_name), '');
    v_contact_email := nullif(lower(trim(p_contact_email)), '');
    v_contact_phone := nullif(trim(p_contact_phone), '');
    v_notes := nullif(trim(p_notes), '');

    if p_relationship_role_code is not null and char_length(trim(p_relationship_role_code)) > 0 then
      v_relationship_role_id := app.get_relationship_role_id_by_code(trim(p_relationship_role_code));

      if v_relationship_role_id is null then
        raise exception 'Invalid relationship role code: %', p_relationship_role_code;
      end if;
    end if;
  else
    v_relationship_role_id := null;
    v_contact_name := null;
    v_contact_email := null;
    v_contact_phone := null;
    v_notes := null;
  end if;

  insert into app.property_admin_contacts (
    property_id,
    mode,
    relationship_role_id,
    contact_name,
    contact_email,
    contact_phone,
    notes,
    created_by
  )
  values (
    p_property_id,
    v_mode,
    v_relationship_role_id,
    v_contact_name,
    v_contact_email,
    v_contact_phone,
    v_notes,
    auth.uid()
  )
  on conflict (property_id) do update
    set mode = excluded.mode,
        relationship_role_id = excluded.relationship_role_id,
        contact_name = excluded.contact_name,
        contact_email = excluded.contact_email,
        contact_phone = excluded.contact_phone,
        notes = excluded.notes,
        deleted_at = null,
        deleted_by = null,
        linked_user_id = case
          when excluded.mode = 'SELF' then null
          else property_admin_contacts.linked_user_id
        end;

  perform app.touch_property_activity(p_property_id);

  if coalesce(p_mark_step_completed, true) then
    select s.id
      into v_session_id
    from app.property_onboarding_sessions s
    where s.property_id = p_property_id
      and s.deleted_at is null
    limit 1;

    if v_session_id is null then
      raise exception 'Onboarding session not found for property %', p_property_id;
    end if;

    update app.property_onboarding_step_states
       set status = 'completed',
           completed_by = auth.uid(),
           completed_at = coalesce(completed_at, now()),
           data_snapshot = jsonb_build_object(
             'mode', v_mode,
             'relationshipRoleCode', nullif(trim(p_relationship_role_code), ''),
             'contactName', v_contact_name,
             'contactEmail', v_contact_email,
             'contactPhone', v_contact_phone,
             'notes', v_notes
           ),
           locked_by = null,
           locked_at = null,
           lock_expires_at = null
     where session_id = v_session_id
       and step_key = 'accountability'
       and deleted_at is null;

    get diagnostics v_step_rows = row_count;
    if v_step_rows = 0 then
      raise exception 'Accountability step state not found for property %', p_property_id;
    end if;

    update app.property_onboarding_sessions
       set current_step_key = 'review',
           last_activity_at = now()
     where id = v_session_id
       and deleted_at is null
       and current_step_key <> 'done';

    get diagnostics v_session_rows = row_count;
    if v_session_rows = 0 then
      raise exception 'Onboarding session could not advance to review for property %', p_property_id;
    end if;

    update app.properties
       set current_step_key = 'review',
           last_activity_at = now()
     where id = p_property_id
       and deleted_at is null
       and current_step_key <> 'done';

    get diagnostics v_property_rows = row_count;
    if v_property_rows = 0 then
      raise exception 'Property could not advance to review for property %', p_property_id;
    end if;

    update app.property_onboarding_step_states
       set status = 'in_progress'
     where session_id = v_session_id
       and step_key = 'review'
       and status = 'not_started'
       and deleted_at is null;
  end if;

  v_action_id := app.get_audit_action_id_by_code('PCA_SET');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'mode', v_mode,
        'relationshipRoleCode', nullif(trim(p_relationship_role_code), ''),
        'contactEmail', v_contact_email
      )
    );
  end if;

  if coalesce(p_mark_step_completed, true) then
    v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

    if v_action_id is not null then
      insert into app.audit_logs (
        property_id,
        actor_user_id,
        action_type_id,
        payload
      )
      values (
        p_property_id,
        auth.uid(),
        v_action_id,
        jsonb_build_object(
          'step', 'accountability',
          'next_step', 'review'
        )
      );
    end if;
  end if;
end;
$$;

revoke all on function app.upsert_property_admin_contact(
  uuid, text, text, text, text, text, text, boolean
) from public;
grant execute on function app.upsert_property_admin_contact(
  uuid, text, text, text, text, text, text, boolean
) to authenticated;

create or replace function app.link_pca_to_user(
  p_property_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_user_id is null then
    raise exception 'user_id is required';
  end if;

  if not app.has_domain_scope(p_property_id, 'ACCOUNTABILITY') then
    raise exception 'Missing domain scope: ACCOUNTABILITY';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  update app.property_admin_contacts
     set linked_user_id = p_user_id
   where property_id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'PCA record not found for property';
  end if;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('PCA_SET');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'linked_user_id', p_user_id
      )
    );
  end if;
end;
$$;

revoke all on function app.link_pca_to_user(uuid, uuid) from public;
grant execute on function app.link_pca_to_user(uuid, uuid) to authenticated;

create or replace function app.complete_accountability_step(
  p_property_id uuid,
  p_snapshot jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_now timestamptz := now();
  v_step_rows integer := 0;
  v_session_rows integer := 0;
  v_property_rows integer := 0;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not app.has_domain_scope(p_property_id, 'ACCOUNTABILITY') then
    raise exception 'Missing domain scope: ACCOUNTABILITY';
  end if;

  perform app.assert_property_onboarding_open(p_property_id);

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is null then
    raise exception 'Onboarding session not found for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'completed',
         completed_by = coalesce(completed_by, auth.uid()),
         completed_at = coalesce(completed_at, v_now),
         data_snapshot = coalesce(p_snapshot, '{}'::jsonb),
         locked_by = null,
         locked_at = null,
         lock_expires_at = null
   where session_id = v_session_id
     and step_key = 'accountability'
     and deleted_at is null;

  get diagnostics v_step_rows = row_count;
  if v_step_rows = 0 then
    raise exception 'Accountability step state not found for property %', p_property_id;
  end if;

  update app.property_onboarding_sessions
     set current_step_key = 'review',
         last_activity_at = v_now
   where id = v_session_id
     and deleted_at is null
     and current_step_key <> 'done';

  get diagnostics v_session_rows = row_count;
  if v_session_rows = 0 then
    raise exception 'Onboarding session could not advance to review for property %', p_property_id;
  end if;

  update app.properties
     set current_step_key = 'review',
         last_activity_at = v_now
   where id = p_property_id
     and deleted_at is null
     and current_step_key <> 'done';

  get diagnostics v_property_rows = row_count;
  if v_property_rows = 0 then
    raise exception 'Property could not advance to review for property %', p_property_id;
  end if;

  update app.property_onboarding_step_states
     set status = 'in_progress'
   where session_id = v_session_id
     and step_key = 'review'
     and status = 'not_started'
     and deleted_at is null;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('ONBOARDING_STEP_UPDATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'step', 'accountability',
        'next_step', 'review'
      )
    );
  end if;
end;
$$;

revoke all on function app.complete_accountability_step(uuid, jsonb) from public;
grant execute on function app.complete_accountability_step(uuid, jsonb) to authenticated;

create or replace function app.activate_property(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);

  update app.properties
     set status = 'active',
         onboarding_completed_at = coalesce(onboarding_completed_at, now()),
         current_step_key = 'done',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null
     and identity_completed_at is not null;

  if not found then
    raise exception 'Property not found, deleted, or identity not completed';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is not null then
    update app.property_onboarding_sessions
       set status = 'completed',
           current_step_key = 'done',
           last_activity_at = now()
     where id = v_session_id
       and deleted_at is null;

    update app.property_onboarding_step_states
       set status = 'completed',
           completed_by = coalesce(completed_by, auth.uid()),
           completed_at = coalesce(completed_at, now()),
           data_snapshot = coalesce(data_snapshot, '{}'::jsonb) || jsonb_build_object('activatedAt', now()),
           locked_by = null,
           locked_at = null,
           lock_expires_at = null
     where session_id = v_session_id
       and step_key = 'review'
       and deleted_at is null;
  end if;

  perform app.touch_property_activity(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('PROPERTY_ACTIVATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'status', 'active'
      )
    );
  end if;
end;
$$;

revoke all on function app.activate_property(uuid) from public;
grant execute on function app.activate_property(uuid) to authenticated;

create or replace function app.soft_delete_property(
  p_property_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);

  update app.properties
     set deleted_at = now(),
         deleted_by = auth.uid(),
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;

  if not found then
    raise exception 'Property not found or already deleted';
  end if;

  update app.property_onboarding_sessions
     set status = 'abandoned'
   where property_id = p_property_id
     and deleted_at is null;

  v_action_id := app.get_audit_action_id_by_code('PROPERTY_DELETED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'reason', nullif(trim(p_reason), '')
      )
    );
  end if;
end;
$$;

revoke all on function app.soft_delete_property(uuid, text) from public;
grant execute on function app.soft_delete_property(uuid, text) to authenticated;

create or replace function app.get_latest_ownership_details()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_snapshot jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select pos.data_snapshot
    into v_snapshot
  from app.property_onboarding_step_states pos
  join app.property_onboarding_sessions s
    on s.id = pos.session_id
  join app.properties p
    on p.id = s.property_id
  where pos.step_key = 'ownership'
    and pos.status = 'completed'
    and pos.deleted_at is null
    and s.deleted_at is null
    and p.deleted_at is null
    and p.created_by = auth.uid()
    and pos.data_snapshot is not null
    and pos.data_snapshot->>'ownerName' is not null
  order by pos.completed_at desc nulls last
  limit 1;

  if v_snapshot is not null then
    v_snapshot := v_snapshot - 'supportingDocuments';
  end if;

  return coalesce(v_snapshot, '{}'::jsonb);
end;
$$;

revoke all on function app.get_latest_ownership_details() from public;
grant execute on function app.get_latest_ownership_details() to authenticated;

create or replace function app.get_past_admin_contacts()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  with ranked_pacs as (
    select
      pac.mode,
      rr.code as relationship_role_code,
      pac.contact_name,
      pac.contact_email,
      pac.contact_phone,
      pac.notes,
      row_number() over (
        partition by coalesce(nullif(trim(pac.contact_email), ''), pac.contact_phone, pac.contact_name)
        order by pac.updated_at desc
      ) as rn
    from app.property_admin_contacts pac
    join app.properties p
      on p.id = pac.property_id
    left join app.lookup_relationship_roles rr
      on rr.id = pac.relationship_role_id
    where p.created_by = auth.uid()
      and pac.deleted_at is null
      and p.deleted_at is null
      and pac.mode = 'DELEGATED'
      and (pac.contact_email is not null or pac.contact_phone is not null)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'mode', mode,
        'relationshipRoleCode', relationship_role_code,
        'contactName', contact_name,
        'contactEmail', contact_email,
        'contactPhone', contact_phone,
        'notes', notes
      )
    ),
    '[]'::jsonb
  )
  into v_result
  from ranked_pacs
  where rn = 1;

  return v_result;
end;
$$;

revoke all on function app.get_past_admin_contacts() from public;
grant execute on function app.get_past_admin_contacts() to authenticated;
