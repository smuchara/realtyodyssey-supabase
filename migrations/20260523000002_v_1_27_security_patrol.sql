-- ============================================================================
-- V1.27: Security / Patrol Portal
-- ============================================================================
-- Adds security staff invite flow, location assignments, scan validation,
-- and scan event logging. Visible only to property_management_company accounts.
-- ============================================================================

-- ── Enums ─────────────────────────────────────────────────────────────────────

do $$ begin
  create type app.security_staff_role_enum as enum (
    'security_guard',
    'gate_supervisor',
    'security_admin'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.security_staff_status_enum as enum (
    'invited',
    'active',
    'suspended',
    'deactivated'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.security_scan_action_enum as enum ('entry', 'exit');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.security_scan_result_enum as enum ('approved', 'denied', 'warning');
exception when duplicate_object then null; end $$;

-- ── Security Staff Invitations ─────────────────────────────────────────────────

create table if not exists app.security_staff_invitations (
  id                   uuid primary key default gen_random_uuid(),
  pmc_company_id       uuid not null references auth.users(id) on delete restrict,
  invited_by_user_id   uuid not null references auth.users(id) on delete restrict,
  linked_user_id       uuid references auth.users(id) on delete set null,
  full_name            text not null,
  email                text not null,
  phone                text,
  role                 app.security_staff_role_enum not null default 'security_guard',
  property_id          uuid references app.properties(id) on delete cascade,
  gate_zone_name       text,
  token_hash           text not null,
  status               app.tenant_invitation_status_enum not null default 'sent',
  sent_at              timestamptz not null default now(),
  expires_at           timestamptz not null,
  accepted_at          timestamptz,
  cancelled_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint chk_security_invite_name_len
    check (char_length(trim(full_name)) between 2 and 160),
  constraint chk_security_invite_email_len
    check (char_length(trim(email)) between 5 and 320)
);

create unique index if not exists uq_security_staff_invitations_token_hash
  on app.security_staff_invitations (token_hash);
create unique index if not exists uq_security_staff_invitations_unit_live
  on app.security_staff_invitations (pmc_company_id, lower(email))
  where status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started');
create index if not exists idx_security_staff_invitations_pmc
  on app.security_staff_invitations (pmc_company_id);
create index if not exists idx_security_staff_invitations_expires
  on app.security_staff_invitations (expires_at);

drop trigger if exists trg_security_staff_invitations_updated_at
  on app.security_staff_invitations;
create trigger trg_security_staff_invitations_updated_at
before update on app.security_staff_invitations
for each row execute function app.set_updated_at();

-- ── Security Staff Profiles ────────────────────────────────────────────────────

create table if not exists app.security_staff_profiles (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete restrict,
  pmc_company_id      uuid not null references auth.users(id) on delete restrict,
  invitation_id       uuid references app.security_staff_invitations(id) on delete set null,
  full_name           text not null,
  email               text not null,
  phone               text,
  role                app.security_staff_role_enum not null default 'security_guard',
  status              app.security_staff_status_enum not null default 'active',
  profile_photo_url   text,
  activated_at        timestamptz not null default now(),
  deactivated_at      timestamptz,
  deactivated_reason  text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create unique index if not exists uq_security_staff_profiles_user_pmc
  on app.security_staff_profiles (user_id, pmc_company_id)
  where status = 'active';
create index if not exists idx_security_staff_profiles_pmc
  on app.security_staff_profiles (pmc_company_id);
create index if not exists idx_security_staff_profiles_status
  on app.security_staff_profiles (status);

drop trigger if exists trg_security_staff_profiles_updated_at
  on app.security_staff_profiles;
create trigger trg_security_staff_profiles_updated_at
before update on app.security_staff_profiles
for each row execute function app.set_updated_at();

-- ── Security Location Assignments ─────────────────────────────────────────────

create table if not exists app.security_location_assignments (
  id                uuid primary key default gen_random_uuid(),
  staff_profile_id  uuid not null references app.security_staff_profiles(id) on delete cascade,
  pmc_company_id    uuid not null references auth.users(id) on delete restrict,
  property_id       uuid not null references app.properties(id) on delete cascade,
  gate_zone_name    text,
  is_active         boolean not null default true,
  assigned_at       timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists idx_security_location_assignments_staff
  on app.security_location_assignments (staff_profile_id);
create index if not exists idx_security_location_assignments_property
  on app.security_location_assignments (property_id);
create index if not exists idx_security_location_assignments_pmc
  on app.security_location_assignments (pmc_company_id);

drop trigger if exists trg_security_location_assignments_updated_at
  on app.security_location_assignments;
create trigger trg_security_location_assignments_updated_at
before update on app.security_location_assignments
for each row execute function app.set_updated_at();

-- ── Security Scan Events ───────────────────────────────────────────────────────

create table if not exists app.security_scan_events (
  id                      uuid primary key default gen_random_uuid(),
  pmc_company_id          uuid not null references auth.users(id) on delete restrict,
  property_id             uuid not null references app.properties(id) on delete cascade,
  unit_id                 uuid references app.units(id) on delete set null,
  scanned_by_staff_id     uuid not null references app.security_staff_profiles(id) on delete restrict,
  scanned_by_user_id      uuid not null references auth.users(id) on delete restrict,
  location_assignment_id  uuid references app.security_location_assignments(id) on delete set null,
  gate_zone_name          text,
  -- Subject
  access_profile_id       uuid references app.access_profiles(id) on delete set null,
  guest_invitation_id     uuid references app.guest_invitations(id) on delete set null,
  person_type             text,
  person_name             text,
  unit_label              text,
  -- Result
  scan_action             app.security_scan_action_enum not null,
  scan_result             app.security_scan_result_enum not null,
  denial_reason           text,
  scanned_at              timestamptz not null default now(),
  created_at              timestamptz not null default now()
);

create index if not exists idx_security_scan_events_staff
  on app.security_scan_events (scanned_by_staff_id, scanned_at desc);
create index if not exists idx_security_scan_events_property
  on app.security_scan_events (property_id, scanned_at desc);
create index if not exists idx_security_scan_events_pmc
  on app.security_scan_events (pmc_company_id, scanned_at desc);
create index if not exists idx_security_scan_events_unit
  on app.security_scan_events (unit_id, scanned_at desc);

-- ── RLS (all access via security-definer RPCs only) ────────────────────────────

revoke all on table app.security_staff_invitations   from public, anon, authenticated;
revoke all on table app.security_staff_profiles      from public, anon, authenticated;
revoke all on table app.security_location_assignments from public, anon, authenticated;
revoke all on table app.security_scan_events         from public, anon, authenticated;

-- ── Audit action types ─────────────────────────────────────────────────────────

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('SECURITY_STAFF_INVITED',   'Security Staff Invited',   300),
  ('SECURITY_STAFF_ACCEPTED',  'Security Staff Accepted',  301),
  ('SECURITY_STAFF_DEACTIVATED','Security Staff Deactivated',302),
  ('SECURITY_QR_SCANNED',      'Security QR Scanned',      303)
on conflict (code) do update
set label = excluded.label, sort_order = excluded.sort_order;

-- ============================================================================
-- RPC: INVITE SECURITY STAFF (PMC admin)
-- ============================================================================

create or replace function app.invite_security_staff(
  p_full_name     text,
  p_email         text,
  p_phone         text default null,
  p_role          app.security_staff_role_enum default 'security_guard',
  p_property_id   uuid default null,
  p_gate_zone     text default null,
  p_expires_days  integer default 7
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_caller_profile  record;
  v_email           text;
  v_phone           text;
  v_name            text;
  v_token           text;
  v_expires_at      timestamptz;
  v_invite_id       uuid;
  v_action_id       uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select account_type into v_caller_profile
  from app.profiles
  where id = auth.uid()
  limit 1;

  if v_caller_profile.account_type::text <> 'property_management_company' then
    raise exception 'Only property management company accounts can invite security staff';
  end if;

  v_email := nullif(trim(lower(coalesce(p_email, ''))), '');
  v_phone := nullif(trim(coalesce(p_phone, '')), '');
  v_name  := nullif(trim(coalesce(p_full_name, '')), '');

  if v_email is null then
    raise exception 'Email is required';
  end if;
  if v_name is null or char_length(v_name) < 2 then
    raise exception 'Full name must be at least 2 characters';
  end if;

  v_expires_at := now() + make_interval(days => greatest(coalesce(p_expires_days, 7), 1));

  -- Block if a live invite already exists for this email under this PMC.
  if exists (
    select 1
    from app.security_staff_invitations i
    where i.pmc_company_id = auth.uid()
      and lower(i.email) = v_email
      and i.status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
      and i.expires_at > now()
  ) then
    raise exception 'A live invite already exists for this email address';
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into app.security_staff_invitations (
    pmc_company_id, invited_by_user_id,
    full_name, email, phone, role,
    property_id, gate_zone_name,
    token_hash, status, sent_at, expires_at
  )
  values (
    auth.uid(), auth.uid(),
    v_name, v_email, v_phone, p_role,
    p_property_id, nullif(trim(coalesce(p_gate_zone, '')), ''),
    app.hash_token(v_token), 'sent', now(), v_expires_at
  )
  returning id into v_invite_id;

  v_action_id := app.get_audit_action_id_by_code('SECURITY_STAFF_INVITED');
  if v_action_id is not null then
    insert into app.audit_logs (actor_user_id, action_type_id, payload)
    values (
      auth.uid(), v_action_id,
      jsonb_build_object(
        'security_staff_invitation_id', v_invite_id,
        'invited_email', v_email,
        'role', p_role::text
      )
    );
  end if;

  return jsonb_build_object(
    'security_staff_invitation_id', v_invite_id,
    'token', v_token,
    'expires_at', v_expires_at
  );
end;
$$;

-- ============================================================================
-- RPC: ACCEPT SECURITY STAFF INVITE
-- ============================================================================

create or replace function app.accept_security_staff_invite(
  p_token     text,
  p_full_name text default null,
  p_phone     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite      record;
  v_user_email  text;
  v_staff_id    uuid;
  v_action_id   uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select u.email into v_user_email
  from auth.users u where u.id = auth.uid() limit 1;

  select i.*
    into v_invite
  from app.security_staff_invitations i
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;
  if v_invite.accepted_at is not null or v_invite.status = 'accepted' then
    raise exception 'Invitation has already been accepted';
  end if;
  if v_invite.cancelled_at is not null or v_invite.status = 'cancelled' then
    raise exception 'Invitation has been cancelled';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'Invitation has expired. Please ask your administrator to resend the invite.';
  end if;
  if lower(trim(coalesce(v_user_email, ''))) <> lower(trim(v_invite.email)) then
    raise exception 'The logged-in account email does not match the invited email address';
  end if;

  -- Mark invite accepted.
  update app.security_staff_invitations
     set linked_user_id = auth.uid(),
         status = 'accepted',
         accepted_at = now(),
         updated_at = now()
   where id = v_invite.id;

  -- Create staff profile.
  insert into app.security_staff_profiles (
    user_id, pmc_company_id, invitation_id,
    full_name, email, phone, role, status, activated_at
  )
  values (
    auth.uid(), v_invite.pmc_company_id, v_invite.id,
    coalesce(nullif(trim(coalesce(p_full_name, '')), ''), v_invite.full_name),
    v_invite.email,
    coalesce(nullif(trim(coalesce(p_phone, '')), ''), v_invite.phone),
    v_invite.role,
    'active',
    now()
  )
  returning id into v_staff_id;

  -- Create location assignment if the invite had a property.
  if v_invite.property_id is not null then
    insert into app.security_location_assignments (
      staff_profile_id, pmc_company_id, property_id, gate_zone_name, is_active
    )
    values (
      v_staff_id, v_invite.pmc_company_id, v_invite.property_id,
      v_invite.gate_zone_name, true
    );
  end if;

  v_action_id := app.get_audit_action_id_by_code('SECURITY_STAFF_ACCEPTED');
  if v_action_id is not null then
    insert into app.audit_logs (actor_user_id, action_type_id, payload)
    values (
      auth.uid(), v_action_id,
      jsonb_build_object(
        'security_staff_invitation_id', v_invite.id,
        'security_staff_profile_id', v_staff_id,
        'pmc_company_id', v_invite.pmc_company_id
      )
    );
  end if;

  return jsonb_build_object(
    'security_staff_profile_id', v_staff_id,
    'pmc_company_id', v_invite.pmc_company_id,
    'role', v_invite.role::text,
    'full_name', coalesce(nullif(trim(coalesce(p_full_name,'')),  ''), v_invite.full_name)
  );
end;
$$;

-- ============================================================================
-- RPC: GET MY SECURITY PATROL PROFILE (security staff user)
-- ============================================================================

create or replace function app.get_my_security_patrol_profile()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_staff   record;
  v_locs    jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select
    sp.id,
    sp.pmc_company_id,
    sp.full_name,
    sp.email,
    sp.phone,
    sp.role,
    sp.status,
    sp.activated_at,
    pmc_p.company_name as pmc_company_name
  into v_staff
  from app.security_staff_profiles sp
  join app.profiles pmc_p on pmc_p.id = sp.pmc_company_id
  where sp.user_id = auth.uid()
    and sp.status = 'active'
  order by sp.activated_at desc
  limit 1;

  if v_staff.id is null then
    return jsonb_build_object('has_profile', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',              la.id,
    'property_id',     la.property_id,
    'property_name',   p.display_name,
    'gate_zone_name',  la.gate_zone_name,
    'is_active',       la.is_active
  )), '[]'::jsonb)
  into v_locs
  from app.security_location_assignments la
  join app.properties p on p.id = la.property_id
  where la.staff_profile_id = v_staff.id
    and la.is_active = true;

  return jsonb_build_object(
    'has_profile',      true,
    'staff_profile_id', v_staff.id,
    'pmc_company_id',   v_staff.pmc_company_id,
    'pmc_company_name', coalesce(v_staff.pmc_company_name, 'Your Company'),
    'full_name',        v_staff.full_name,
    'email',            v_staff.email,
    'role',             v_staff.role::text,
    'status',           v_staff.status::text,
    'activated_at',     v_staff.activated_at,
    'locations',        v_locs
  );
end;
$$;

-- ============================================================================
-- RPC: SECURITY VALIDATE QR SCAN
-- ============================================================================
-- Security staff calls this with the decoded token value and desired action.
-- Returns a rich result object. Also records the event.

create or replace function app.security_validate_qr_scan(
  p_token_value text,
  p_scan_action app.security_scan_action_enum
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_staff       record;
  v_location    record;
  -- resident path
  v_res_token   record;
  v_res_profile record;
  v_res_invite  record;
  v_last_res    record;
  -- guest path
  v_gst_token   record;
  v_gst_invite  record;
  v_last_gst    record;
  -- result
  v_person_type text;
  v_person_name text;
  v_unit_label  text;
  v_property_id uuid;
  v_unit_id     uuid;
  v_profile_id  uuid;
  v_guest_inv_id uuid;
  v_scan_result app.security_scan_result_enum;
  v_denial_msg  text;
  v_result_data jsonb;
  v_scan_id     uuid;
  v_action_id   uuid;
begin
  if p_token_value is null or length(trim(p_token_value)) = 0 then
    return jsonb_build_object('scan_result', 'denied', 'denial_reason', 'Token is empty');
  end if;

  -- Resolve the scanning staff member.
  select
    sp.id, sp.pmc_company_id, sp.full_name, sp.role, sp.status
  into v_staff
  from app.security_staff_profiles sp
  where sp.user_id = auth.uid()
    and sp.status = 'active'
  order by sp.activated_at desc
  limit 1;

  if v_staff.id is null then
    return jsonb_build_object('scan_result', 'denied',
      'denial_reason', 'Your security profile is not active. Contact your administrator.');
  end if;

  -- Get primary location assignment.
  select la.id, la.property_id, la.gate_zone_name, p.display_name as property_name
    into v_location
  from app.security_location_assignments la
  join app.properties p on p.id = la.property_id
  where la.staff_profile_id = v_staff.id
    and la.is_active = true
  order by la.assigned_at desc
  limit 1;

  -- ── Try resident token first ──────────────────────────────────────────────
  select at2.id, at2.access_profile_id, at2.status, at2.valid_until
    into v_res_token
  from app.access_tokens at2
  where at2.token_hash = app.hash_token(trim(p_token_value))
  limit 1;

  if v_res_token.id is not null then
    -- Validate token status and expiry.
    if v_res_token.status <> 'active' then
      v_scan_result := 'denied';
      v_denial_msg  := 'This QR code is no longer active.';
    elsif v_res_token.valid_until < now() then
      v_scan_result := 'denied';
      v_denial_msg  := 'This QR code has expired — the resident should open their app to refresh it.';
    else
      -- Load access profile.
      select ap.id, ap.user_id, ap.pmc_company_id, ap.property_id, ap.unit_id,
             ap.occupant_type, ap.status, u.label as unit_label,
             pr.first_name || ' ' || pr.last_name as resident_name
        into v_res_profile
      from app.access_profiles ap
      join app.units u   on u.id = ap.unit_id
      join app.profiles pr on pr.id = ap.user_id
      where ap.id = v_res_token.access_profile_id
      limit 1;

      if v_res_profile.status <> 'active' then
        v_scan_result := 'denied';
        v_denial_msg  := 'Resident access profile is no longer active.';
      elsif v_res_profile.pmc_company_id <> v_staff.pmc_company_id then
        v_scan_result := 'denied';
        v_denial_msg  := 'This QR code belongs to a different property management company.';
      else
        -- Check location assignment matches.
        if v_location.property_id is not null and
           v_location.property_id <> v_res_profile.property_id then
          v_scan_result := 'denied';
          v_denial_msg  := 'This QR code does not belong to your assigned property.';
        else
          -- Check presence state for duplicate check-in prevention.
          select ae.event_type into v_last_res
          from app.access_events ae
          where ae.access_profile_id = v_res_profile.id
          order by ae.event_at desc
          limit 1;

          if p_scan_action = 'entry' and v_last_res.event_type = 'check_in' then
            v_scan_result := 'warning';
            v_denial_msg  := 'This resident is already checked in. Record an exit first before logging another entry.';
          else
            v_scan_result := 'approved';
            -- Log to access_events.
            insert into app.access_events (
              access_profile_id, access_token_id, event_type,
              pmc_company_id, property_id, unit_id,
              scanned_by, event_at, notes
            )
            values (
              v_res_profile.id, v_res_token.id,
              case when p_scan_action = 'entry' then 'check_in' else 'check_out' end,
              v_res_profile.pmc_company_id, v_res_profile.property_id, v_res_profile.unit_id,
              auth.uid(), now(),
              'Logged via Security Patrol Portal'
            );
          end if;

          v_person_type := v_res_profile.occupant_type::text;
          v_person_name := v_res_profile.resident_name;
          v_unit_label  := v_res_profile.unit_label;
          v_property_id := v_res_profile.property_id;
          v_unit_id     := v_res_profile.unit_id;
          v_profile_id  := v_res_profile.id;

          v_result_data := jsonb_build_object(
            'person_type',    v_person_type,
            'person_name',    v_person_name,
            'unit_label',     v_unit_label,
            'property_name',  coalesce(v_location.property_name, ''),
            'occupant_type',  v_res_profile.occupant_type::text
          );
        end if;
      end if;
    end if;

    -- Record scan event (resident path).
    insert into app.security_scan_events (
      pmc_company_id, property_id, unit_id,
      scanned_by_staff_id, scanned_by_user_id, location_assignment_id, gate_zone_name,
      access_profile_id, person_type, person_name, unit_label,
      scan_action, scan_result, denial_reason, scanned_at
    )
    values (
      v_staff.pmc_company_id,
      coalesce(v_property_id, v_location.property_id),
      v_unit_id,
      v_staff.id, auth.uid(), v_location.id, v_location.gate_zone_name,
      v_profile_id, v_person_type, v_person_name, v_unit_label,
      p_scan_action, v_scan_result, v_denial_msg, now()
    )
    returning id into v_scan_id;

    return jsonb_build_object(
      'scan_id',        v_scan_id,
      'scan_result',    v_scan_result::text,
      'scan_action',    p_scan_action::text,
      'denial_reason',  v_denial_msg,
      'token_type',     'resident',
      'scanned_at',     now()
    ) || coalesce(v_result_data, '{}'::jsonb);
  end if;

  -- ── Try guest token ────────────────────────────────────────────────────────
  select gat.id, gat.guest_invitation_id, gat.status
    into v_gst_token
  from app.guest_access_tokens gat
  where gat.token_hash = app.hash_token(trim(p_token_value))
  limit 1;

  if v_gst_token.id is not null then
    if v_gst_token.status <> 'active' then
      v_scan_result := 'denied';
      v_denial_msg  := 'This guest QR code has been revoked.';
    else
      select gi.id, gi.status, gi.guest_name, gi.pmc_company_id,
             gi.property_id, gi.unit_id,
             ap_u.label as unit_label,
             pr.first_name || ' ' || pr.last_name as inviter_name
        into v_gst_invite
      from app.guest_invitations gi
      join app.units ap_u on ap_u.id = gi.unit_id
      join app.access_profiles ap2 on ap2.id = gi.inviter_access_profile_id
      join app.profiles pr on pr.id = ap2.user_id
      where gi.id = v_gst_token.guest_invitation_id
      limit 1;

      if v_gst_invite.status <> 'active' then
        v_scan_result := 'denied';
        v_denial_msg  := 'Guest access has been revoked.';
      elsif v_gst_invite.pmc_company_id <> v_staff.pmc_company_id then
        v_scan_result := 'denied';
        v_denial_msg  := 'This guest QR code belongs to a different property management company.';
      else
        if v_location.property_id is not null and
           v_location.property_id <> v_gst_invite.property_id then
          v_scan_result := 'denied';
          v_denial_msg  := 'This guest QR code does not belong to your assigned property.';
        else
          select gae.event_type into v_last_gst
          from app.guest_access_events gae
          where gae.guest_invitation_id = v_gst_invite.id
          order by gae.event_at desc
          limit 1;

          if p_scan_action = 'entry' and v_last_gst.event_type = 'check_in' then
            v_scan_result := 'warning';
            v_denial_msg  := format(
              'Guest %s is already checked in. Record an exit first.',
              v_gst_invite.guest_name
            );
          else
            v_scan_result := 'approved';
            insert into app.guest_access_events (
              guest_invitation_id, guest_access_token_id, event_type,
              pmc_company_id, property_id, unit_id, scanned_by, event_at
            )
            values (
              v_gst_invite.id, v_gst_token.id,
              case when p_scan_action = 'entry' then 'check_in' else 'check_out' end,
              v_gst_invite.pmc_company_id, v_gst_invite.property_id, v_gst_invite.unit_id,
              auth.uid(), now()
            );
          end if;

          v_person_type  := 'guest';
          v_person_name  := v_gst_invite.guest_name;
          v_unit_label   := v_gst_invite.unit_label;
          v_property_id  := v_gst_invite.property_id;
          v_unit_id      := v_gst_invite.unit_id;
          v_guest_inv_id := v_gst_invite.id;

          v_result_data := jsonb_build_object(
            'person_type',    'guest',
            'person_name',    v_gst_invite.guest_name,
            'inviter_name',   v_gst_invite.inviter_name,
            'unit_label',     v_unit_label,
            'property_name',  coalesce(v_location.property_name, '')
          );
        end if;
      end if;
    end if;

    insert into app.security_scan_events (
      pmc_company_id, property_id, unit_id,
      scanned_by_staff_id, scanned_by_user_id, location_assignment_id, gate_zone_name,
      guest_invitation_id, person_type, person_name, unit_label,
      scan_action, scan_result, denial_reason, scanned_at
    )
    values (
      v_staff.pmc_company_id,
      coalesce(v_property_id, v_location.property_id),
      v_unit_id,
      v_staff.id, auth.uid(), v_location.id, v_location.gate_zone_name,
      v_guest_inv_id, v_person_type, v_person_name, v_unit_label,
      p_scan_action, v_scan_result, v_denial_msg, now()
    )
    returning id into v_scan_id;

    return jsonb_build_object(
      'scan_id',        v_scan_id,
      'scan_result',    v_scan_result::text,
      'scan_action',    p_scan_action::text,
      'denial_reason',  v_denial_msg,
      'token_type',     'guest',
      'scanned_at',     now()
    ) || coalesce(v_result_data, '{}'::jsonb);
  end if;

  -- Token not found in any table.
  insert into app.security_scan_events (
    pmc_company_id, property_id,
    scanned_by_staff_id, scanned_by_user_id, location_assignment_id, gate_zone_name,
    scan_action, scan_result, denial_reason, scanned_at
  )
  values (
    v_staff.pmc_company_id, v_location.property_id,
    v_staff.id, auth.uid(), v_location.id, v_location.gate_zone_name,
    p_scan_action, 'denied', 'Invalid or unrecognised QR code', now()
  )
  returning id into v_scan_id;

  return jsonb_build_object(
    'scan_id',       v_scan_id,
    'scan_result',   'denied',
    'scan_action',   p_scan_action::text,
    'denial_reason', 'Invalid or unrecognised QR code. Contact the resident or your administrator.',
    'token_type',    'unknown',
    'scanned_at',    now()
  );
end;
$$;

-- ============================================================================
-- RPC: GET SECURITY TEAM PAGE DATA (PMC admin)
-- ============================================================================

create or replace function app.get_security_team_page_data()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_caller_profile record;
  v_metrics        jsonb;
  v_staff_list     jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select account_type into v_caller_profile
  from app.profiles where id = auth.uid() limit 1;

  if v_caller_profile.account_type::text <> 'property_management_company' then
    raise exception 'Access denied';
  end if;

  -- Metrics.
  select jsonb_build_object(
    'total_staff',      count(*) filter (where status in ('active', 'suspended')),
    'active_staff',     count(*) filter (where status = 'active'),
    'pending_invites',  (
      select count(*) from app.security_staff_invitations
      where pmc_company_id = auth.uid()
        and status in ('sent', 'pending', 'pending_delivery')
        and expires_at > now()
    ),
    'scans_today',      (
      select count(*) from app.security_scan_events
      where pmc_company_id = auth.uid()
        and scanned_at >= current_date
    ),
    'entries_today',    (
      select count(*) from app.security_scan_events
      where pmc_company_id = auth.uid()
        and scan_action = 'entry' and scan_result = 'approved'
        and scanned_at >= current_date
    ),
    'exits_today',      (
      select count(*) from app.security_scan_events
      where pmc_company_id = auth.uid()
        and scan_action = 'exit' and scan_result = 'approved'
        and scanned_at >= current_date
    )
  )
  into v_metrics
  from app.security_staff_profiles
  where pmc_company_id = auth.uid();

  -- Staff list with location assignments.
  select coalesce(jsonb_agg(s order by s.activated_at desc), '[]'::jsonb)
    into v_staff_list
  from (
    select
      sp.id,
      sp.full_name,
      sp.email,
      sp.phone,
      sp.role,
      sp.status,
      sp.activated_at,
      sp.deactivated_at,
      -- Most recent scan
      (select sse.scanned_at from app.security_scan_events sse
       where sse.scanned_by_staff_id = sp.id
       order by sse.scanned_at desc limit 1) as last_scan_at,
      -- Location assignments
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', la.id,
          'property_id', la.property_id,
          'property_name', p.display_name,
          'gate_zone_name', la.gate_zone_name,
          'is_active', la.is_active
        ))
        from app.security_location_assignments la
        join app.properties p on p.id = la.property_id
        where la.staff_profile_id = sp.id
      ), '[]'::jsonb) as location_assignments
    from app.security_staff_profiles sp
    where sp.pmc_company_id = auth.uid()
    order by sp.activated_at desc
  ) s;

  -- Pending invites (not yet accepted).
  select v_staff_list || coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'is_invite', true,
      'full_name', i.full_name,
      'email', i.email,
      'phone', i.phone,
      'role', i.role,
      'status', 'invited',
      'sent_at', i.sent_at,
      'expires_at', i.expires_at,
      'location_assignments', coalesce(
        case when i.property_id is not null then
          jsonb_build_array(jsonb_build_object(
            'property_id', i.property_id,
            'property_name', (select display_name from app.properties where id = i.property_id),
            'gate_zone_name', i.gate_zone_name
          ))
        end,
        '[]'::jsonb
      )
    ) order by i.sent_at desc)
    from app.security_staff_invitations i
    where i.pmc_company_id = auth.uid()
      and i.status in ('sent', 'pending', 'pending_delivery')
      and i.expires_at > now()
  ), '[]'::jsonb)
  into v_staff_list;

  return jsonb_build_object(
    'metrics',    v_metrics,
    'staff_list', v_staff_list
  );
end;
$$;

-- ============================================================================
-- RPC: DEACTIVATE SECURITY STAFF (PMC admin)
-- ============================================================================

create or replace function app.deactivate_security_staff(
  p_staff_profile_id uuid,
  p_reason           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_staff record;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;

  select sp.id, sp.pmc_company_id, sp.status
    into v_staff
  from app.security_staff_profiles sp
  where sp.id = p_staff_profile_id
  limit 1;

  if v_staff.id is null then raise exception 'Staff profile not found'; end if;
  if v_staff.pmc_company_id <> auth.uid() then raise exception 'Access denied'; end if;
  if v_staff.status = 'deactivated' then raise exception 'Already deactivated'; end if;

  update app.security_staff_profiles
     set status = 'deactivated',
         deactivated_at = now(),
         deactivated_reason = nullif(trim(coalesce(p_reason, '')), ''),
         updated_at = now()
   where id = p_staff_profile_id;

  update app.security_location_assignments
     set is_active = false, updated_at = now()
   where staff_profile_id = p_staff_profile_id;

  return jsonb_build_object('staff_profile_id', p_staff_profile_id, 'status', 'deactivated');
end;
$$;

-- ============================================================================
-- RPC: RESEND SECURITY STAFF INVITE (PMC admin)
-- ============================================================================

create or replace function app.resend_security_staff_invite(p_invitation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite record;
  v_token  text;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;

  select i.* into v_invite
  from app.security_staff_invitations i
  where i.id = p_invitation_id
  limit 1;

  if v_invite.id is null then raise exception 'Invitation not found'; end if;
  if v_invite.pmc_company_id <> auth.uid() then raise exception 'Access denied'; end if;
  if v_invite.accepted_at is not null then raise exception 'Invite already accepted'; end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  update app.security_staff_invitations
     set token_hash = app.hash_token(v_token),
         status     = 'sent',
         sent_at    = now(),
         expires_at = now() + interval '7 days',
         updated_at = now()
   where id = p_invitation_id;

  return jsonb_build_object(
    'security_staff_invitation_id', p_invitation_id,
    'token',          v_token,
    'expires_at',     now() + interval '7 days',
    'email',          v_invite.email,
    'full_name',      v_invite.full_name,
    'role',           v_invite.role::text,
    'gate_zone_name', v_invite.gate_zone_name,
    'property_id',    v_invite.property_id
  );
end;
$$;

-- ============================================================================
-- RPC: GET PATROL RECENT ACTIVITY (security staff user)
-- ============================================================================

create or replace function app.get_patrol_recent_activity(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_staff_id uuid;
  v_events   jsonb;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;

  select sp.id into v_staff_id
  from app.security_staff_profiles sp
  where sp.user_id = auth.uid() and sp.status = 'active'
  order by sp.activated_at desc
  limit 1;

  if v_staff_id is null then
    return jsonb_build_object('events', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(e order by e.scanned_at desc), '[]'::jsonb)
    into v_events
  from (
    select
      sse.id,
      sse.scan_action,
      sse.scan_result,
      sse.denial_reason,
      sse.person_type,
      sse.person_name,
      sse.unit_label,
      sse.gate_zone_name,
      sse.scanned_at,
      p.display_name as property_name
    from app.security_scan_events sse
    left join app.properties p on p.id = sse.property_id
    where sse.scanned_by_staff_id = v_staff_id
    order by sse.scanned_at desc
    limit greatest(coalesce(p_limit, 30), 1)
  ) e;

  return jsonb_build_object('events', v_events);
end;
$$;

-- ============================================================================
-- RPC: GET SECURITY INVITE PUBLIC DETAILS (unauthenticated — invite acceptance)
-- ============================================================================

create or replace function app.get_security_invite_public_details(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_token_hash text;
  v_invite      record;
  v_prop        record;
begin
  v_token_hash := app.hash_token(nullif(trim(p_token), ''));

  if v_token_hash is null then
    raise exception 'Token is required';
  end if;

  select i.*, pr.display_name as property_name_resolved
    into v_invite
  from app.security_staff_invitations i
  left join app.properties pr on pr.id = i.property_id
  where i.token_hash = v_token_hash
  limit 1;

  if v_invite.id is null then
    raise exception 'Invite not found or already accepted';
  end if;

  if v_invite.accepted_at is not null then
    raise exception 'This invite has already been accepted';
  end if;

  if v_invite.expires_at < now() then
    raise exception 'This invite has expired. Please contact your supervisor to resend it.';
  end if;

  if v_invite.cancelled_at is not null then
    raise exception 'This invite has been cancelled';
  end if;

  -- Resolve PMC company name from profile
  declare
    v_pmc_name text;
  begin
    select coalesce(p.company_name, p.first_name || ' ' || p.last_name)
      into v_pmc_name
    from app.profiles p
    where p.id = v_invite.pmc_company_id
    limit 1;

    v_pmc_name := coalesce(v_pmc_name, 'Property Management Company');
  end;

  return jsonb_build_object(
    'invitation_id',    v_invite.id,
    'invited_email',    v_invite.email,
    'invited_name',     v_invite.full_name,
    'invited_phone',    v_invite.phone,
    'pmc_company_name', (select coalesce(p.company_name, p.first_name || ' ' || p.last_name, 'PMC')
                         from app.profiles p where p.id = v_invite.pmc_company_id limit 1),
    'role',             v_invite.role::text,
    'property_name',    coalesce(v_invite.property_name_resolved, ''),
    'gate_zone_name',   v_invite.gate_zone_name,
    'expires_at',       v_invite.expires_at
  );
end;
$$;

grant execute on function app.get_security_invite_public_details(text) to anon, authenticated;
