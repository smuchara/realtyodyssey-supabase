-- ============================================================================
-- V 1 04: Security, RLS, and Base Access
-- ============================================================================
-- Purpose
--   - Create shared security-definer helpers used by later RPCs and RLS
--   - Enable and force RLS across the foundational tables
--   - Define the base authenticated read model and limited direct updates
--   - Establish RPC-first grants so future write flows stay intentional
--
-- Notes
--   - Public and anon access remain closed here. Later migrations can grant
--     carefully scoped anon access where public invitation flows require it.
--   - This migration assumes V 1 01 through V 1 03 already exist.
-- ============================================================================

create schema if not exists app;

create or replace function app.is_workspace_owner(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1
    from app.workspaces w
    where w.id = p_workspace_id
      and w.owner_user_id = auth.uid()
  );
$$;

create or replace function app.is_property_workspace_owner(p_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1
    from app.properties p
    join app.workspaces w
      on w.id = p.workspace_id
    where p.id = p_property_id
      and p.deleted_at is null
      and w.owner_user_id = auth.uid()
  );
$$;

create or replace function app.is_property_member(p_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1
    from app.property_memberships pm
    where pm.property_id = p_property_id
      and pm.user_id = auth.uid()
      and pm.status = 'active'
      and pm.deleted_at is null
      and (pm.ends_at is null or pm.ends_at > now())
  );
$$;

create or replace function app.is_property_member_or_owner(p_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select
    app.is_property_workspace_owner(p_property_id)
    or app.is_property_member(p_property_id);
$$;

create or replace function app.has_domain_scope(p_property_id uuid, p_scope_code text)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select
    app.is_property_workspace_owner(p_property_id)
    or exists (
      select 1
      from app.property_memberships pm
      join app.lookup_domain_scopes ds
        on ds.id = pm.domain_scope_id
      where pm.property_id = p_property_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.deleted_at is null
        and ds.deleted_at is null
        and ds.code = p_scope_code
        and (pm.ends_at is null or pm.ends_at > now())
    )
    or exists (
      select 1
      from app.property_memberships pm
      join app.lookup_domain_scopes ds
        on ds.id = pm.domain_scope_id
      where pm.property_id = p_property_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.deleted_at is null
        and ds.deleted_at is null
        and ds.code = 'FULL_PROPERTY'
        and (pm.ends_at is null or pm.ends_at > now())
    );
$$;

create or replace function app.hash_token(p_token text)
returns text
language sql
immutable
security definer
set search_path = app, public, extensions
as $$
  select encode(
    extensions.digest(convert_to(coalesce(p_token, ''), 'utf8'), 'sha256'),
    'hex'
  );
$$;

create or replace function app.get_role_id_by_key(p_role_key text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select r.id
  from app.roles r
  where r.key = p_role_key
    and r.deleted_at is null
    and r.is_active = true
  limit 1;
$$;

create or replace function app.get_scope_id_by_code(p_scope_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select s.id
  from app.lookup_domain_scopes s
  where s.code = p_scope_code
    and s.deleted_at is null
    and s.is_active = true
  limit 1;
$$;

create or replace function app.get_property_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select t.id
  from app.lookup_property_types t
  where t.code = p_code
    and t.deleted_at is null
    and t.is_active = true
  limit 1;
$$;

create or replace function app.get_usage_type_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select u.id
  from app.lookup_usage_types u
  where u.code = p_code
    and u.deleted_at is null
    and u.is_active = true
  limit 1;
$$;

create or replace function app.get_map_source_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select ms.id
  from app.lookup_map_sources ms
  where ms.code = p_code
    and ms.deleted_at is null
    and ms.is_active = true
  limit 1;
$$;

create or replace function app.get_audit_action_id_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = app, public
as $$
  select a.id
  from app.lookup_audit_action_types a
  where a.code = p_code
    and a.deleted_at is null
    and a.is_active = true
  limit 1;
$$;

create or replace function app.touch_property_activity(p_property_id uuid)
returns void
language sql
volatile
security definer
set search_path = app, public
as $$
  update app.properties
     set last_activity_at = now()
   where id = p_property_id
     and deleted_at is null;
$$;

create or replace function app.get_step_index(p_step_key text)
returns integer
language sql
immutable
security definer
set search_path = app, public
as $$
  select case lower(coalesce(p_step_key, ''))
    when 'identity' then 1
    when 'usage' then 2
    when 'structure' then 3
    when 'ownership' then 4
    when 'accountability' then 5
    when 'review' then 6
    when 'done' then 7
    else 999
  end;
$$;

create or replace function app.assert_property_full_access(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not (
    app.is_property_workspace_owner(p_property_id)
    or app.has_domain_scope(p_property_id, 'FULL_PROPERTY')
  ) then
    raise exception 'Forbidden: requires workspace owner or FULL_PROPERTY scope';
  end if;
end;
$$;

create or replace function app.assert_property_onboarding_open(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_status app.property_status_enum;
  v_onboarding_completed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select
    p.status,
    p.onboarding_completed_at
  into
    v_status,
    v_onboarding_completed_at
  from app.properties p
  where p.id = p_property_id
    and p.deleted_at is null
  limit 1;

  if v_status is null then
    raise exception 'Property not found or deleted';
  end if;

  if v_status <> 'draft' or v_onboarding_completed_at is not null then
    raise exception 'Onboarding is closed for this property';
  end if;
end;
$$;

grant execute on function app.is_workspace_owner(uuid) to authenticated;
grant execute on function app.is_active_member(uuid) to authenticated;
grant execute on function app.is_workspace_admin(uuid) to authenticated;
grant execute on function app.is_property_workspace_owner(uuid) to authenticated;
grant execute on function app.is_property_member(uuid) to authenticated;
grant execute on function app.is_property_member_or_owner(uuid) to authenticated;
grant execute on function app.has_domain_scope(uuid, text) to authenticated;
grant execute on function app.create_owner_workspace(text) to authenticated;

revoke all on function app.is_workspace_owner(uuid) from public;
revoke all on function app.hash_token(text) from public, authenticated;
revoke all on function app.get_role_id_by_key(text) from public, authenticated;
revoke all on function app.get_scope_id_by_code(text) from public, authenticated;
revoke all on function app.get_property_type_id_by_code(text) from public, authenticated;
revoke all on function app.get_usage_type_id_by_code(text) from public, authenticated;
revoke all on function app.get_map_source_id_by_code(text) from public, authenticated;
revoke all on function app.get_audit_action_id_by_code(text) from public, authenticated;
revoke all on function app.touch_property_activity(uuid) from public, authenticated;
revoke all on function app.get_step_index(text) from public, authenticated;
revoke all on function app.assert_property_full_access(uuid) from public, authenticated;
revoke all on function app.assert_property_onboarding_open(uuid) from public, authenticated;

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'profiles',
    'workspaces',
    'workspace_memberships',
    'lookup_property_types',
    'lookup_usage_types',
    'lookup_map_sources',
    'lookup_layout_types',
    'lookup_waste_disposal_types',
    'lookup_lift_access_types',
    'lookup_unit_presets',
    'lookup_home_types',
    'lookup_document_types',
    'lookup_verification_statuses',
    'lookup_relationship_roles',
    'lookup_domain_scopes',
    'lookup_audit_action_types',
    'roles',
    'permissions',
    'role_permissions',
    'properties',
    'units',
    'property_documents',
    'property_admin_contacts',
    'property_memberships',
    'collaboration_invites',
    'property_onboarding_sessions',
    'property_onboarding_step_states',
    'audit_logs'
  ]
  loop
    execute format('alter table app.%I enable row level security', v_table_name);
    execute format('alter table app.%I force row level security', v_table_name);
  end loop;
end
$$;

drop policy if exists profiles_select_own on app.profiles;
create policy profiles_select_own
on app.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists profiles_update_own on app.profiles;
create policy profiles_update_own
on app.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists workspaces_select_if_owner_or_member on app.workspaces;
create policy workspaces_select_if_owner_or_member
on app.workspaces
for select
to authenticated
using (
  owner_user_id = auth.uid()
  or app.is_active_member(id)
);

drop policy if exists workspaces_update_if_admin on app.workspaces;
create policy workspaces_update_if_admin
on app.workspaces
for update
to authenticated
using (
  owner_user_id = auth.uid()
  or app.is_workspace_admin(id)
)
with check (
  owner_user_id = auth.uid()
  or app.is_workspace_admin(id)
);

drop policy if exists workspace_memberships_select_if_same_workspace on app.workspace_memberships;
create policy workspace_memberships_select_if_same_workspace
on app.workspace_memberships
for select
to authenticated
using (
  app.is_workspace_owner(workspace_id)
  or app.is_active_member(workspace_id)
);

drop policy if exists workspace_memberships_insert_if_admin on app.workspace_memberships;
create policy workspace_memberships_insert_if_admin
on app.workspace_memberships
for insert
to authenticated
with check (
  app.is_workspace_owner(workspace_id)
  or app.is_workspace_admin(workspace_id)
);

drop policy if exists workspace_memberships_update_if_admin on app.workspace_memberships;
create policy workspace_memberships_update_if_admin
on app.workspace_memberships
for update
to authenticated
using (
  app.is_workspace_owner(workspace_id)
  or app.is_workspace_admin(workspace_id)
)
with check (
  app.is_workspace_owner(workspace_id)
  or app.is_workspace_admin(workspace_id)
);

drop policy if exists workspace_memberships_delete_if_admin on app.workspace_memberships;
create policy workspace_memberships_delete_if_admin
on app.workspace_memberships
for delete
to authenticated
using (
  app.is_workspace_owner(workspace_id)
  or app.is_workspace_admin(workspace_id)
);

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'lookup_property_types',
    'lookup_usage_types',
    'lookup_map_sources',
    'lookup_layout_types',
    'lookup_waste_disposal_types',
    'lookup_lift_access_types',
    'lookup_unit_presets',
    'lookup_home_types',
    'lookup_document_types',
    'lookup_verification_statuses',
    'lookup_relationship_roles',
    'lookup_domain_scopes',
    'lookup_audit_action_types'
  ]
  loop
    execute format('drop policy if exists app_reference_select on app.%I', v_table_name);
    execute format(
      'create policy app_reference_select on app.%I for select to authenticated using (deleted_at is null and is_active = true)',
      v_table_name
    );
  end loop;
end
$$;

drop policy if exists roles_select_active on app.roles;
create policy roles_select_active
on app.roles
for select
to authenticated
using (
  deleted_at is null
  and is_active = true
);

drop policy if exists permissions_select_active on app.permissions;
create policy permissions_select_active
on app.permissions
for select
to authenticated
using (deleted_at is null);

drop policy if exists role_permissions_select_active on app.role_permissions;
create policy role_permissions_select_active
on app.role_permissions
for select
to authenticated
using (deleted_at is null);

drop policy if exists properties_select_owner_or_member on app.properties;
create policy properties_select_owner_or_member
on app.properties
for select
to authenticated
using (
  deleted_at is null
  and (
    app.is_workspace_owner(workspace_id)
    or app.is_property_member(id)
  )
);

drop policy if exists properties_insert_owner_only on app.properties;
create policy properties_insert_owner_only
on app.properties
for insert
to authenticated
with check (
  deleted_at is null
  and app.is_workspace_owner(workspace_id)
);

drop policy if exists properties_update_owner_or_full_scope on app.properties;
create policy properties_update_owner_or_full_scope
on app.properties
for update
to authenticated
using (
  deleted_at is null
  and (
    app.is_workspace_owner(workspace_id)
    or app.has_domain_scope(id, 'FULL_PROPERTY')
  )
)
with check (
  deleted_at is null
  and (
    app.is_workspace_owner(workspace_id)
    or app.has_domain_scope(id, 'FULL_PROPERTY')
  )
);

drop policy if exists units_select_if_property_member on app.units;
create policy units_select_if_property_member
on app.units
for select
to authenticated
using (
  deleted_at is null
  and app.is_property_member_or_owner(property_id)
);

drop policy if exists units_insert_if_units_scope on app.units;
create policy units_insert_if_units_scope
on app.units
for insert
to authenticated
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'UNITS')
);

drop policy if exists units_update_if_units_scope on app.units;
create policy units_update_if_units_scope
on app.units
for update
to authenticated
using (
  deleted_at is null
  and app.has_domain_scope(property_id, 'UNITS')
)
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'UNITS')
);

drop policy if exists property_documents_select_if_member on app.property_documents;
create policy property_documents_select_if_member
on app.property_documents
for select
to authenticated
using (
  deleted_at is null
  and app.is_property_member_or_owner(property_id)
);

drop policy if exists property_documents_insert_if_ownership_scope on app.property_documents;
create policy property_documents_insert_if_ownership_scope
on app.property_documents
for insert
to authenticated
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'OWNERSHIP')
);

drop policy if exists property_documents_update_if_ownership_scope on app.property_documents;
create policy property_documents_update_if_ownership_scope
on app.property_documents
for update
to authenticated
using (
  deleted_at is null
  and app.has_domain_scope(property_id, 'OWNERSHIP')
)
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'OWNERSHIP')
);

drop policy if exists property_admin_contacts_select_if_member on app.property_admin_contacts;
create policy property_admin_contacts_select_if_member
on app.property_admin_contacts
for select
to authenticated
using (
  deleted_at is null
  and app.is_property_member_or_owner(property_id)
);

drop policy if exists property_admin_contacts_insert_if_accountability_scope on app.property_admin_contacts;
create policy property_admin_contacts_insert_if_accountability_scope
on app.property_admin_contacts
for insert
to authenticated
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'ACCOUNTABILITY')
);

drop policy if exists property_admin_contacts_update_if_accountability_scope on app.property_admin_contacts;
create policy property_admin_contacts_update_if_accountability_scope
on app.property_admin_contacts
for update
to authenticated
using (
  deleted_at is null
  and app.has_domain_scope(property_id, 'ACCOUNTABILITY')
)
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'ACCOUNTABILITY')
);

drop policy if exists property_memberships_select_if_member on app.property_memberships;
create policy property_memberships_select_if_member
on app.property_memberships
for select
to authenticated
using (
  deleted_at is null
  and app.is_property_member_or_owner(property_id)
);

drop policy if exists property_memberships_insert_owner_or_full_scope on app.property_memberships;
create policy property_memberships_insert_owner_or_full_scope
on app.property_memberships
for insert
to authenticated
with check (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
);

drop policy if exists property_memberships_update_owner_or_full_scope on app.property_memberships;
create policy property_memberships_update_owner_or_full_scope
on app.property_memberships
for update
to authenticated
using (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
)
with check (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
);

drop policy if exists collaboration_invites_select_owner_or_full_scope on app.collaboration_invites;
create policy collaboration_invites_select_owner_or_full_scope
on app.collaboration_invites
for select
to authenticated
using (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
);

drop policy if exists collaboration_invites_insert_owner_or_full_scope on app.collaboration_invites;
create policy collaboration_invites_insert_owner_or_full_scope
on app.collaboration_invites
for insert
to authenticated
with check (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
);

drop policy if exists collaboration_invites_update_owner_or_full_scope on app.collaboration_invites;
create policy collaboration_invites_update_owner_or_full_scope
on app.collaboration_invites
for update
to authenticated
using (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
)
with check (
  deleted_at is null
  and (
    app.is_property_workspace_owner(property_id)
    or app.has_domain_scope(property_id, 'FULL_PROPERTY')
  )
);

drop policy if exists onboarding_sessions_select_if_member on app.property_onboarding_sessions;
create policy onboarding_sessions_select_if_member
on app.property_onboarding_sessions
for select
to authenticated
using (
  deleted_at is null
  and app.is_property_member_or_owner(property_id)
);

drop policy if exists onboarding_sessions_update_if_full_scope on app.property_onboarding_sessions;
create policy onboarding_sessions_update_if_full_scope
on app.property_onboarding_sessions
for update
to authenticated
using (
  deleted_at is null
  and app.has_domain_scope(property_id, 'FULL_PROPERTY')
)
with check (
  deleted_at is null
  and app.has_domain_scope(property_id, 'FULL_PROPERTY')
);

drop policy if exists step_states_select_if_member on app.property_onboarding_step_states;
create policy step_states_select_if_member
on app.property_onboarding_step_states
for select
to authenticated
using (
  deleted_at is null
  and exists (
    select 1
    from app.property_onboarding_sessions s
    where s.id = session_id
      and s.deleted_at is null
      and app.is_property_member_or_owner(s.property_id)
  )
);

drop policy if exists audit_logs_select_if_member on app.audit_logs;
create policy audit_logs_select_if_member
on app.audit_logs
for select
to authenticated
using (
  deleted_at is null
  and (
    property_id is null
    or app.is_property_member_or_owner(property_id)
  )
);

revoke all on schema app from public;
revoke all on schema app from anon;
revoke all on schema app from authenticated;
grant usage on schema app to authenticated;

revoke all on all tables in schema app from public;
revoke all on all tables in schema app from anon;
revoke all on all tables in schema app from authenticated;
grant select on all tables in schema app to authenticated;

revoke all on all sequences in schema app from public;
revoke all on all sequences in schema app from anon;
revoke all on all sequences in schema app from authenticated;
grant usage, select on all sequences in schema app to authenticated;

alter default privileges in schema app revoke all on tables from public;
alter default privileges in schema app revoke all on tables from anon;
alter default privileges in schema app revoke all on tables from authenticated;
alter default privileges in schema app grant select on tables to authenticated;

alter default privileges in schema app revoke all on sequences from public;
alter default privileges in schema app revoke all on sequences from anon;
alter default privileges in schema app revoke all on sequences from authenticated;
alter default privileges in schema app grant usage, select on sequences to authenticated;

do $$
declare
  v_view_name text;
begin
  for v_view_name in
    select table_name
    from information_schema.views
    where table_schema = 'app'
  loop
    execute format('revoke all on app.%I from public', v_view_name);
    execute format('revoke all on app.%I from anon', v_view_name);
    execute format('revoke all on app.%I from authenticated', v_view_name);
    execute format('grant select on app.%I to authenticated', v_view_name);
  end loop;
end
$$;
