-- ============================================================================
-- V1.25: Property Management Company Onboarding
-- ============================================================================
-- Purpose
--   - Extend account_type_enum with 'property_management_company'
--   - Add company_name, primary_contact_name, primary_contact_phone columns
--     to app.profiles for PMC accounts
--   - Update handle_new_user() trigger to accept and persist the new type
--     and company-specific metadata fields
-- ============================================================================

-- Add new value to the enum (idempotent: ignored if already present)
do $$
begin
  alter type app.account_type_enum add value if not exists 'property_management_company';
exception
  when others then null;
end
$$;

-- Add company metadata columns to profiles
alter table app.profiles
  add column if not exists company_name          text,
  add column if not exists primary_contact_name  text,
  add column if not exists primary_contact_phone text;

-- Rebuild handle_new_user to accept the new account type and persist company fields.
-- For PMC accounts the caller passes:
--   company_name          → the organisation being onboarded
--   primary_contact_name  → full name of the company representative
--   primary_contact_phone → phone number of the company representative
-- first_name / last_name are derived from primary_contact_name so existing
-- queries that read those columns continue to work.
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_account_type        app.account_type_enum := 'owner';
  v_account_type_raw    text;
  v_contact_name        text;
  v_first_name          text;
  v_last_name           text;
  v_last_space          int;
begin
  v_account_type_raw := lower(coalesce(new.raw_user_meta_data->>'account_type', 'owner'));

  if v_account_type_raw in (
    'owner', 'resident', 'investor', 'artist', 'property_management_company'
  ) then
    v_account_type := v_account_type_raw::app.account_type_enum;
  end if;

  -- For PMC accounts derive first/last name from primary_contact_name so that
  -- existing queries on first_name / last_name continue to return meaningful data.
  if v_account_type_raw = 'property_management_company' then
    v_contact_name := trim(coalesce(new.raw_user_meta_data->>'primary_contact_name', ''));
    v_last_space   := length(v_contact_name) - position(' ' in reverse(v_contact_name)) + 1;

    if v_last_space > 1 and v_last_space < length(v_contact_name) then
      v_first_name := trim(left(v_contact_name, v_last_space - 1));
      v_last_name  := trim(substr(v_contact_name, v_last_space + 1));
    else
      v_first_name := v_contact_name;
      v_last_name  := '';
    end if;
  else
    v_first_name := coalesce(new.raw_user_meta_data->>'first_name', '');
    v_last_name  := coalesce(new.raw_user_meta_data->>'last_name', '');
  end if;

  insert into app.profiles (
    id,
    email,
    first_name,
    last_name,
    account_type,
    company_name,
    primary_contact_name,
    primary_contact_phone
  )
  values (
    new.id,
    new.email,
    v_first_name,
    v_last_name,
    v_account_type,
    nullif(trim(coalesce(new.raw_user_meta_data->>'company_name', '')), ''),
    nullif(trim(coalesce(new.raw_user_meta_data->>'primary_contact_name', '')), ''),
    nullif(trim(coalesce(new.raw_user_meta_data->>'primary_contact_phone', '')), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
