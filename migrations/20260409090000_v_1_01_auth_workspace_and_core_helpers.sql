-- ============================================================================
-- REBUILD 01: Auth, Workspace, and Core Helpers
-- ============================================================================
-- Purpose
--   - Establish the base app schema and foundational extensions
--   - Create the workspace tenancy boundary and user profile records
--   - Define core helper functions used by later domain migrations
--
-- Notes
--   - Security policies and grants are intentionally deferred to a later
--     dedicated security migration.
--   - This migration should remain small, stable, and dependency-light.
-- ============================================================================

create extension if not exists pgcrypto;

create schema if not exists app;

do $$
begin
  create type app.account_type_enum as enum (
    'owner',
    'resident',
    'investor',
    'artist'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type app.workspace_role_enum as enum (
    'workspace_admin',
    'workspace_member'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type app.membership_status_enum as enum (
    'active',
    'pending',
    'suspended'
  );
exception
  when duplicate_object then null;
end
$$;

create or replace function app.set_updated_at()
returns trigger
language plpgsql
set search_path = app, public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function app.slugify(p_text text)
returns text
language sql
immutable
set search_path = app, public
as $$
  select trim(
    both '-'
    from regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g')
  );
$$;

create table if not exists app.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  first_name text,
  last_name text,
  account_type app.account_type_enum not null default 'owner',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_profiles_updated_at on app.profiles;
create trigger trg_profiles_updated_at
before update on app.profiles
for each row execute function app.set_updated_at();

create index if not exists idx_profiles_email_lower
  on app.profiles (lower(email));

create table if not exists app.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_workspaces_owner unique (owner_user_id),
  constraint chk_workspaces_name_len check (char_length(name) between 2 and 80)
);

drop trigger if exists trg_workspaces_updated_at on app.workspaces;
create trigger trg_workspaces_updated_at
before update on app.workspaces
for each row execute function app.set_updated_at();

create index if not exists idx_workspaces_owner_user_id
  on app.workspaces (owner_user_id);

create table if not exists app.workspace_memberships (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references app.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role app.workspace_role_enum not null default 'workspace_member',
  status app.membership_status_enum not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_workspace_memberships_workspace_user unique (workspace_id, user_id)
);

drop trigger if exists trg_workspace_memberships_updated_at on app.workspace_memberships;
create trigger trg_workspace_memberships_updated_at
before update on app.workspace_memberships
for each row execute function app.set_updated_at();

create index if not exists idx_workspace_memberships_user_id
  on app.workspace_memberships (user_id);

create index if not exists idx_workspace_memberships_workspace_id
  on app.workspace_memberships (workspace_id);

create index if not exists idx_workspace_memberships_workspace_user
  on app.workspace_memberships (workspace_id, user_id);

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_account_type app.account_type_enum := 'owner';
  v_account_type_raw text;
begin
  v_account_type_raw := lower(coalesce(new.raw_user_meta_data->>'account_type', 'owner'));

  if v_account_type_raw in ('owner', 'resident', 'investor', 'artist') then
    v_account_type := v_account_type_raw::app.account_type_enum;
  end if;

  insert into app.profiles (
    id,
    email,
    first_name,
    last_name,
    account_type
  )
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'first_name', ''),
    coalesce(new.raw_user_meta_data->>'last_name', ''),
    v_account_type
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function app.handle_new_user();

create or replace function app.is_active_member(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1
    from app.workspace_memberships m
    where m.workspace_id = p_workspace_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  );
$$;

create or replace function app.is_workspace_admin(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1
    from app.workspace_memberships m
    where m.workspace_id = p_workspace_id
      and m.user_id = auth.uid()
      and m.status = 'active'
      and m.role = 'workspace_admin'
  );
$$;

create or replace function app.create_owner_workspace(p_name text)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_workspace_id uuid;
  v_base_slug text;
  v_slug text;
  v_suffix integer := 1;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_name is null or char_length(trim(p_name)) < 2 or char_length(trim(p_name)) > 80 then
    raise exception 'Workspace name must be between 2 and 80 characters';
  end if;

  if exists (
    select 1
    from app.workspaces w
    where w.owner_user_id = auth.uid()
  ) then
    raise exception 'Owner already has a workspace';
  end if;

  v_base_slug := app.slugify(p_name);
  if v_base_slug = '' then
    v_base_slug := 'workspace';
  end if;

  v_slug := v_base_slug;

  while exists (
    select 1
    from app.workspaces w
    where w.slug = v_slug
  ) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base_slug || '-' || v_suffix::text;
  end loop;

  insert into app.workspaces (
    name,
    slug,
    owner_user_id,
    created_by
  )
  values (
    trim(p_name),
    v_slug,
    auth.uid(),
    auth.uid()
  )
  returning id into v_workspace_id;

  insert into app.workspace_memberships (
    workspace_id,
    user_id,
    role,
    status
  )
  values (
    v_workspace_id,
    auth.uid(),
    'workspace_admin',
    'active'
  );

  return v_workspace_id;
end;
$$;

create or replace view app.my_workspace_context
with (security_invoker = on) as
select
  w.id as workspace_id,
  w.name as workspace_name,
  w.slug as workspace_slug,
  w.owner_user_id,
  m.role as my_role,
  m.status as my_membership_status
from app.workspaces w
join app.workspace_memberships m
  on m.workspace_id = w.id
where m.user_id = auth.uid()
  and m.status = 'active';

revoke all on function app.handle_new_user() from public;
revoke all on function app.is_active_member(uuid) from public;
revoke all on function app.is_workspace_admin(uuid) from public;
revoke all on function app.create_owner_workspace(text) from public;
