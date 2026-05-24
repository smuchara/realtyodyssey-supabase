-- ============================================================================
-- V1.29: Guest Invite Portal
-- ============================================================================
-- Adds a public invite_link_token to guest_invitations so residents can share
-- a URL with their guest. The guest opens a public web portal, views context
-- (inviter name, property, unit), and downloads their QR code — no account
-- required.
--
-- Changes:
--   1. Add invite_link_token column to app.guest_invitations
--   2. Patch create_guest_invite to generate + return the token
--   3. New public RPC: get_guest_portal_details — anon/authenticated access
-- ============================================================================

-- ── 1. Add invite_link_token column ──────────────────────────────────────────

alter table app.guest_invitations
  add column if not exists invite_link_token text;

-- Backfill any existing rows.
update app.guest_invitations
  set invite_link_token = encode(extensions.gen_random_bytes(24), 'hex')
where invite_link_token is null;

-- Now enforce NOT NULL + unique.
alter table app.guest_invitations
  alter column invite_link_token set not null;

create unique index if not exists guest_invitations_invite_link_token_idx
  on app.guest_invitations (invite_link_token);

-- ── 2. Patch create_guest_invite to generate + return invite_link_token ───────

create or replace function app.create_guest_invite(
  p_guest_name  text,
  p_guest_phone text default null,
  p_guest_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_profile          record;
  v_guest_name       text;
  v_guest_phone      text;
  v_guest_email      text;
  v_invite_id        uuid;
  v_token_value      text;
  v_token_hash       text;
  v_token_id         uuid;
  v_invite_link_token text;
  v_action_id        uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_guest_name  := nullif(trim(coalesce(p_guest_name, '')), '');
  v_guest_phone := nullif(trim(coalesce(p_guest_phone, '')), '');
  v_guest_email := nullif(trim(lower(coalesce(p_guest_email, ''))), '');

  if v_guest_name is null or char_length(v_guest_name) < 2 then
    raise exception 'Guest name must be at least 2 characters';
  end if;

  -- Caller must have an active access profile under a PMC.
  select ap.id, ap.pmc_company_id, ap.property_id, ap.unit_id, ap.status
    into v_profile
  from app.access_profiles ap
  where ap.user_id = auth.uid()
    and ap.status = 'active'
  order by ap.activated_at desc
  limit 1;

  if v_profile.id is null then
    raise exception 'You do not have an active access profile. Only occupants under a property management company can invite guests.';
  end if;

  -- Generate the public invite-link token (shorter, URL-safe hex string).
  v_invite_link_token := encode(gen_random_bytes(24), 'hex');

  -- Create guest invitation.
  insert into app.guest_invitations (
    inviter_access_profile_id, inviter_user_id, pmc_company_id,
    property_id, unit_id, guest_name, guest_phone, guest_email,
    status, invited_at, invite_link_token
  )
  values (
    v_profile.id, auth.uid(), v_profile.pmc_company_id,
    v_profile.property_id, v_profile.unit_id,
    v_guest_name, v_guest_phone, v_guest_email,
    'active', now(), v_invite_link_token
  )
  returning id into v_invite_id;

  -- Issue guest QR token.
  select t.token_value, t.token_hash
    into v_token_value, v_token_hash
  from app.generate_access_token_pair() t;

  insert into app.guest_access_tokens (
    guest_invitation_id, token_value, token_hash, status, issued_at
  )
  values (v_invite_id, v_token_value, v_token_hash, 'active', now())
  returning id into v_token_id;

  v_action_id := app.get_audit_action_id_by_code('GUEST_INVITE_CREATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_profile.property_id, v_profile.unit_id, auth.uid(), v_action_id,
      jsonb_build_object(
        'guest_invitation_id', v_invite_id,
        'guest_name', v_guest_name
      )
    );
  end if;

  return jsonb_build_object(
    'guest_invitation_id', v_invite_id,
    'guest_name',          v_guest_name,
    'token_value',         v_token_value,
    'invite_link_token',   v_invite_link_token,
    'unit_id',             v_profile.unit_id,
    'property_id',         v_profile.property_id,
    'status',              'active'
  );
end;
$$;

-- ── 3. Public RPC: get_guest_portal_details ───────────────────────────────────
-- Callable by anyone (anon + authenticated).
-- Returns limited context for the guest to view their QR code.
-- No sensitive data is exposed beyond what the inviter explicitly shared.

create or replace function app.get_guest_portal_details(p_invite_token text)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite  record;
  v_token   record;
  v_profile record;
  v_unit    record;
  v_prop    record;
begin
  if p_invite_token is null or length(trim(p_invite_token)) = 0 then
    return jsonb_build_object('valid', false, 'reason', 'Invalid invite link.');
  end if;

  select gi.id, gi.status, gi.guest_name, gi.guest_phone, gi.guest_email,
         gi.inviter_user_id, gi.property_id, gi.unit_id, gi.invited_at
    into v_invite
  from app.guest_invitations gi
  where gi.invite_link_token = trim(p_invite_token)
  limit 1;

  if v_invite.id is null then
    return jsonb_build_object(
      'valid',  false,
      'reason', 'Invite not found. Please ask the resident for a new invite link.'
    );
  end if;

  if v_invite.status = 'revoked' then
    return jsonb_build_object(
      'valid',  false,
      'reason', 'This guest access has been ended by the resident. Please ask for a new invite.'
    );
  end if;

  -- Active QR token.
  select gat.token_value
    into v_token
  from app.guest_access_tokens gat
  where gat.guest_invitation_id = v_invite.id
    and gat.status = 'active'
  order by gat.issued_at desc
  limit 1;

  -- Inviter first name only (privacy).
  select pr.first_name
    into v_profile
  from app.profiles pr
  where pr.id = v_invite.inviter_user_id
  limit 1;

  -- Unit label.
  select u.label
    into v_unit
  from app.units u
  where u.id = v_invite.unit_id
  limit 1;

  -- Property display name.
  select p.display_name
    into v_prop
  from app.properties p
  where p.id = v_invite.property_id
  limit 1;

  return jsonb_build_object(
    'valid',           true,
    'status',          v_invite.status,
    'guest_name',      v_invite.guest_name,
    'guest_phone',     v_invite.guest_phone,
    'guest_email',     v_invite.guest_email,
    'inviter_name',    coalesce(v_profile.first_name, 'Your host'),
    'unit_label',      coalesce(v_unit.label, ''),
    'property_name',   coalesce(v_prop.display_name, ''),
    'qr_token_value',  v_token.token_value,
    'invited_at',      v_invite.invited_at
  );
end;
$$;

-- Grant anon + authenticated access (no session required for guest portal).
grant execute on function app.get_guest_portal_details(text) to anon, authenticated;
