-- ─────────────────────────────────────────────────────────────────────────────
-- V1.37 — Service Provider Invites
-- Stores invitations sent to external fundis and contractors before they
-- accept and register on the platform.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─── 1. Table ─────────────────────────────────────────────────────────────────

create table if not exists app.vendor_invites (
  id               uuid primary key default gen_random_uuid(),
  workspace_id     uuid not null references app.workspaces(id) on delete cascade,

  -- Provider type
  profile_type     text not null check (profile_type in ('individual', 'company')),

  -- Individual Fundi fields
  full_name        text,
  email            text not null,
  phone            text,
  id_number        text,

  -- Company fields
  company_name     text,
  company_email    text,
  company_phone    text,
  contact_person   text,

  -- Service profile
  specializations  text[]      not null default '{}',
  regions          jsonb       not null default '[]',
  -- regions shape: [{ placeId, name, lat, lng }]

  -- Invite tracking
  status           text        not null default 'pending'
                   check (status in ('pending', 'accepted', 'declined')),
  token            text        unique not null
                   default encode(extensions.gen_random_bytes(32), 'hex'),
  invited_by       uuid        not null references auth.users(id) on delete restrict,
  invited_at       timestamptz not null default now(),
  accepted_at      timestamptz,

  -- Linked fundi profile once accepted
  fundi_profile_id uuid        references app.fundi_profiles(id) on delete set null
);

create index if not exists idx_vendor_invites_workspace
  on app.vendor_invites (workspace_id);
create index if not exists idx_vendor_invites_email
  on app.vendor_invites (email);
create index if not exists idx_vendor_invites_token
  on app.vendor_invites (token);
create index if not exists idx_vendor_invites_status
  on app.vendor_invites (workspace_id, status);

-- ─── 2. RLS ───────────────────────────────────────────────────────────────────

alter table app.vendor_invites enable row level security;

create policy "vendor_invites_select"
  on app.vendor_invites for select to authenticated
  using (app.is_active_member(workspace_id));

create policy "vendor_invites_insert"
  on app.vendor_invites for insert to authenticated
  with check (
    app.is_active_member(workspace_id)
    and invited_by = auth.uid()
  );

create policy "vendor_invites_update"
  on app.vendor_invites for update to authenticated
  using (app.is_active_member(workspace_id));

grant select, insert, update on app.vendor_invites to authenticated;

-- ─── 3. RPC: invite_service_provider ──────────────────────────────────────────

create or replace function app.invite_service_provider(
  p_workspace_id    uuid,
  p_profile_type    text,
  p_email           text,
  p_full_name       text     default null,
  p_phone           text     default null,
  p_id_number       text     default null,
  p_company_name    text     default null,
  p_company_email   text     default null,
  p_company_phone   text     default null,
  p_contact_person  text     default null,
  p_specializations text[]   default '{}',
  p_regions         jsonb    default '[]'
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite_id uuid;
  v_token     text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0403';
  end if;

  if p_email is null or char_length(trim(p_email)) < 3 then
    raise exception 'A valid email address is required';
  end if;

  if p_profile_type not in ('individual', 'company') then
    raise exception 'profile_type must be individual or company';
  end if;

  insert into app.vendor_invites (
    workspace_id, profile_type,
    full_name, email, phone, id_number,
    company_name, company_email, company_phone, contact_person,
    specializations, regions, invited_by
  ) values (
    p_workspace_id, p_profile_type,
    nullif(trim(coalesce(p_full_name, '')), ''),
    trim(lower(p_email)),
    nullif(trim(coalesce(p_phone, '')), ''),
    nullif(trim(coalesce(p_id_number, '')), ''),
    nullif(trim(coalesce(p_company_name, '')), ''),
    nullif(trim(lower(coalesce(p_company_email, ''))), ''),
    nullif(trim(coalesce(p_company_phone, '')), ''),
    nullif(trim(coalesce(p_contact_person, '')), ''),
    p_specializations,
    p_regions,
    auth.uid()
  )
  returning id, token into v_invite_id, v_token;

  -- Email delivery is handled by the application layer using the returned token.
  -- The caller constructs the invite URL: /join/vendor?token={v_token}

  return jsonb_build_object(
    'invite_id', v_invite_id,
    'token',     v_token,
    'email',     trim(lower(p_email))
  );
end;
$$;

grant execute on function app.invite_service_provider(
  uuid, text, text, text, text, text, text, text, text, text, text[], jsonb
) to authenticated;

-- ─── 4. RPC: get_workspace_vendor_invites ─────────────────────────────────────

create or replace function app.get_workspace_vendor_invites(p_workspace_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  if not app.is_active_member(p_workspace_id) then
    raise exception 'Access denied' using errcode = 'P0403';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.invited_at desc)
      from (
        select
          vi.id,
          vi.profile_type,
          coalesce(vi.full_name, vi.company_name)   as display_name,
          coalesce(vi.email, vi.company_email)       as display_email,
          coalesce(vi.phone, vi.company_phone)       as display_phone,
          vi.specializations,
          vi.regions,
          vi.status,
          vi.invited_at,
          vi.accepted_at
        from app.vendor_invites vi
        where vi.workspace_id = p_workspace_id
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_workspace_vendor_invites(uuid) to authenticated;
