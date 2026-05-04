-- ─────────────────────────────────────────────────────────────────────────────
-- V1.39 — Vendor invite acceptance flow
-- Adds user linkage to vendor_invites and fundi_profiles, and RPCs for the
-- invite acceptance page and provider-side queries.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─── 1. Schema additions ──────────────────────────────────────────────────────

-- Link accepted invite to the auth user that claimed it
alter table app.vendor_invites
  add column if not exists user_id uuid references auth.users(id) on delete set null;

-- Link fundi profile to auth user (one profile per user)
alter table app.fundi_profiles
  add column if not exists user_id uuid unique references auth.users(id) on delete set null;

-- ─── 2. RPC: get_vendor_invite_by_token (public — no auth required) ───────────
-- Used by the invite acceptance page to pre-fill the form.

create or replace function public.get_vendor_invite_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_invite app.vendor_invites;
begin
  select * into v_invite
  from app.vendor_invites
  where token = p_token
    and status = 'pending';

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id',              v_invite.id,
    'profile_type',    v_invite.profile_type,
    'full_name',       v_invite.full_name,
    'company_name',    v_invite.company_name,
    'contact_person',  v_invite.contact_person,
    'email',           v_invite.email,
    'phone',           coalesce(v_invite.phone, v_invite.company_phone),
    'specializations', v_invite.specializations,
    'regions',         v_invite.regions,
    'workspace_id',    v_invite.workspace_id
  );
end;
$$;

grant execute on function public.get_vendor_invite_by_token(text) to anon, authenticated;

-- ─── 3. RPC: accept_vendor_invite (authenticated) ────────────────────────────
-- Called after OTP verification. Creates the fundi_profile and marks invite accepted.

create or replace function app.accept_vendor_invite(
  p_token    text,
  p_name     text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_invite   app.vendor_invites;
  v_profile  app.fundi_profiles;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Find the invite (allow re-accepting for idempotency)
  select * into v_invite
  from app.vendor_invites
  where token = p_token
    and status in ('pending', 'accepted');

  if not found then
    raise exception 'Invite not found or already declined' using errcode = 'P0404';
  end if;

  -- Upsert fundi profile (idempotent)
  insert into app.fundi_profiles (
    workspace_id,
    user_id,
    name,
    specialty,
    phone,
    available
  ) values (
    v_invite.workspace_id,
    v_user_id,
    coalesce(
      nullif(trim(coalesce(p_name, '')), ''),
      v_invite.full_name,
      v_invite.contact_person,
      v_invite.company_name,
      'Provider'
    ),
    -- Use first specialization as primary specialty
    coalesce(v_invite.specializations[1], 'general_repairs'),
    coalesce(v_invite.phone, v_invite.company_phone),
    true
  )
  on conflict (user_id)
    do update set
      name      = excluded.name,
      specialty = excluded.specialty,
      phone     = excluded.phone,
      updated_at = now()
  returning * into v_profile;

  -- Mark invite as accepted
  update app.vendor_invites
  set status     = 'accepted',
      user_id    = v_user_id,
      accepted_at = now()
  where id = v_invite.id;

  return jsonb_build_object(
    'fundi_profile_id', v_profile.id,
    'workspace_id',     v_invite.workspace_id,
    'name',             v_profile.name,
    'specializations',  v_invite.specializations,
    'regions',          v_invite.regions
  );
end;
$$;

grant execute on function app.accept_vendor_invite(text, text) to authenticated;

-- ─── 4. RPC: get_my_provider_profile (authenticated) ─────────────────────────
-- Returns the provider's profile and assigned tickets count.

create or replace function app.get_my_provider_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile app.fundi_profiles;
  v_invite  app.vendor_invites;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select * into v_profile
  from app.fundi_profiles
  where user_id = v_user_id
  limit 1;

  if not found then
    return null;
  end if;

  select * into v_invite
  from app.vendor_invites
  where user_id = v_user_id
  limit 1;

  return jsonb_build_object(
    'id',              v_profile.id,
    'name',            v_profile.name,
    'specialty',       v_profile.specialty,
    'phone',           v_profile.phone,
    'rating',          v_profile.rating,
    'completed_jobs',  v_profile.completed_jobs,
    'available',       v_profile.available,
    'workspace_id',    v_profile.workspace_id,
    'specializations', coalesce(v_invite.specializations, '[]'::jsonb),
    'regions',         coalesce(v_invite.regions, '[]'::jsonb),
    'profile_type',    coalesce(v_invite.profile_type, 'individual')
  );
end;
$$;

grant execute on function app.get_my_provider_profile() to authenticated;

-- ─── 5. RPC: get_my_assigned_tickets ─────────────────────────────────────────
-- Returns maintenance tickets assigned to the authenticated provider.

create or replace function app.get_my_assigned_tickets()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_user_id   uuid := auth.uid();
  v_profile   app.fundi_profiles;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select * into v_profile
  from app.fundi_profiles
  where user_id = v_user_id
  limit 1;

  if not found then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          t.id                                                    as ticket_id,
          t.reference                                             as ticket_reference,
          r.title,
          r.description,
          c.label                                                 as category,
          a.label                                                 as area,
          p.display_name                                          as property_name,
          coalesce(nullif(trim(u.label), ''), 'Unit')             as unit_name,
          t.priority,
          t.status,
          t.estimated_cost,
          t.actual_cost,
          t.assigned_at,
          t.started_at,
          t.completed_at,
          t.created_at
        from app.maintenance_tickets   t
        join app.maintenance_requests  r on r.id = t.request_id
        join app.maintenance_categories c on c.id = r.category_id
        join app.maintenance_areas      a on a.id = r.area_id
        join app.properties             p on p.id = t.property_id
        join app.units                  u on u.id = t.unit_id
        where t.assigned_fundi_id = v_profile.id
        order by t.created_at desc
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_my_assigned_tickets() to authenticated;

-- ─── 6. RLS update: provider can see their own fundi profile ──────────────────

create policy "fundi_profiles_self_select"
  on app.fundi_profiles for select to authenticated
  using (user_id = auth.uid());

create policy "fundi_profiles_self_update"
  on app.fundi_profiles for update to authenticated
  using (user_id = auth.uid());
