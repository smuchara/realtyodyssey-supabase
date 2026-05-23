-- ============================================================================
-- V1.26: Access & Entry Management — QR Code Logic
-- ============================================================================
-- Purpose
--   - Introduce occupant_type classification (owner_occupant / tenant_occupant)
--     for Property Management Company (PMC) accounts
--   - PMC owner-occupant invite flow (no lease required)
--   - QR access profiles, tokens (7-day rotation), and check-in/out event log
--   - Guest invitation system with separate QR tokens per guest
--   - Extend tenant_invitations + unit_tenancies with PMC context columns
--   - Auto-generate access profiles on tenant acceptance when under a PMC
-- ============================================================================

-- ── Enums ────────────────────────────────────────────────────────────────────

do $$ begin
  create type app.occupant_type_enum as enum ('owner_occupant', 'tenant_occupant');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.access_profile_status_enum as enum ('active', 'suspended', 'ended');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.access_token_status_enum as enum ('active', 'rotated', 'invalidated');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.access_event_type_enum as enum ('check_in', 'check_out');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.guest_access_status_enum as enum ('active', 'revoked');
exception when duplicate_object then null; end $$;

-- ── Extend existing tables ────────────────────────────────────────────────────

-- tenant_invitations: stamp PMC context and occupant type at creation time
alter table app.tenant_invitations
  add column if not exists pmc_company_id   uuid references auth.users(id) on delete set null,
  add column if not exists occupant_type    app.occupant_type_enum;

-- unit_tenancies: carry forward PMC context for access profile generation
alter table app.unit_tenancies
  add column if not exists pmc_company_id   uuid references auth.users(id) on delete set null,
  add column if not exists occupant_type    app.occupant_type_enum;

-- ── PMC Owner-Occupant Invitations ───────────────────────────────────────────
-- For owner_occupant invites: no lease required, so this is a separate table.

create table if not exists app.pmc_owner_occupant_invitations (
  id                   uuid primary key default gen_random_uuid(),
  pmc_company_id       uuid not null references auth.users(id) on delete restrict,
  property_id          uuid not null references app.properties(id) on delete cascade,
  unit_id              uuid not null references app.units(id) on delete cascade,
  invited_by_user_id   uuid not null references auth.users(id) on delete restrict,
  linked_user_id       uuid references auth.users(id) on delete set null,
  invited_email        text,
  invited_phone        text,
  invited_name         text,
  token_hash           text not null,
  status               app.tenant_invitation_status_enum not null default 'sent',
  sent_at              timestamptz not null default now(),
  expires_at           timestamptz not null,
  accepted_at          timestamptz,
  cancelled_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint chk_pmc_ooi_email_or_phone
    check (invited_email is not null or invited_phone is not null),
  constraint chk_pmc_ooi_email_len
    check (invited_email is null or char_length(trim(invited_email)) between 5 and 320),
  constraint chk_pmc_ooi_phone_len
    check (invited_phone is null or char_length(trim(invited_phone)) between 7 and 32),
  constraint chk_pmc_ooi_name_len
    check (invited_name is null or char_length(trim(invited_name)) between 2 and 160)
);

create unique index if not exists uq_pmc_ooi_token_hash
  on app.pmc_owner_occupant_invitations (token_hash);
create unique index if not exists uq_pmc_ooi_unit_live
  on app.pmc_owner_occupant_invitations (unit_id)
  where status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started');
create index if not exists idx_pmc_ooi_pmc_company
  on app.pmc_owner_occupant_invitations (pmc_company_id);
create index if not exists idx_pmc_ooi_unit
  on app.pmc_owner_occupant_invitations (unit_id);
create index if not exists idx_pmc_ooi_invited_email
  on app.pmc_owner_occupant_invitations (lower(invited_email))
  where invited_email is not null;
create index if not exists idx_pmc_ooi_expires_at
  on app.pmc_owner_occupant_invitations (expires_at);

drop trigger if exists trg_pmc_ooi_updated_at on app.pmc_owner_occupant_invitations;
create trigger trg_pmc_ooi_updated_at
before update on app.pmc_owner_occupant_invitations
for each row execute function app.set_updated_at();

-- ── Access Profiles ───────────────────────────────────────────────────────────
-- One profile per occupant per unit under a PMC.

create table if not exists app.access_profiles (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references auth.users(id) on delete restrict,
  pmc_company_id            uuid not null references auth.users(id) on delete restrict,
  property_id               uuid not null references app.properties(id) on delete cascade,
  unit_id                   uuid not null references app.units(id) on delete cascade,
  occupant_type             app.occupant_type_enum not null,
  lease_agreement_id        uuid references app.lease_agreements(id) on delete set null,
  tenant_invitation_id      uuid references app.tenant_invitations(id) on delete set null,
  owner_invitation_id       uuid references app.pmc_owner_occupant_invitations(id) on delete set null,
  status                    app.access_profile_status_enum not null default 'active',
  activated_at              timestamptz not null default now(),
  ended_at                  timestamptz,
  ended_reason              text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  -- One active profile per user per unit (allows re-onboarding after ending)
  constraint chk_access_profiles_invitation_kind
    check (
      (occupant_type = 'owner_occupant' and owner_invitation_id is not null)
      or (occupant_type = 'tenant_occupant' and tenant_invitation_id is not null)
    )
);

create unique index if not exists uq_access_profiles_user_unit_active
  on app.access_profiles (user_id, unit_id)
  where status = 'active';
create index if not exists idx_access_profiles_user on app.access_profiles (user_id);
create index if not exists idx_access_profiles_unit on app.access_profiles (unit_id);
create index if not exists idx_access_profiles_pmc on app.access_profiles (pmc_company_id);
create index if not exists idx_access_profiles_status on app.access_profiles (status);

drop trigger if exists trg_access_profiles_updated_at on app.access_profiles;
create trigger trg_access_profiles_updated_at
before update on app.access_profiles
for each row execute function app.set_updated_at();

-- ── Access Tokens ─────────────────────────────────────────────────────────────
-- One active token per profile; rotates every 7 days.
-- token_value is stored plaintext (RLS restricts reads to profile owner only)
-- and used to generate the QR code on the mobile app.
-- token_hash is used by the guard validation RPC without exposing the raw value.

create table if not exists app.access_tokens (
  id                uuid primary key default gen_random_uuid(),
  access_profile_id uuid not null references app.access_profiles(id) on delete cascade,
  token_value       text not null,
  token_hash        text not null,
  status            app.access_token_status_enum not null default 'active',
  valid_from        timestamptz not null default now(),
  valid_until       timestamptz not null,
  rotated_at        timestamptz,
  invalidated_at    timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create unique index if not exists uq_access_tokens_token_hash
  on app.access_tokens (token_hash);
create unique index if not exists uq_access_tokens_profile_active
  on app.access_tokens (access_profile_id)
  where status = 'active';
create index if not exists idx_access_tokens_valid_until
  on app.access_tokens (valid_until)
  where status = 'active';

drop trigger if exists trg_access_tokens_updated_at on app.access_tokens;
create trigger trg_access_tokens_updated_at
before update on app.access_tokens
for each row execute function app.set_updated_at();

-- ── Access Events (resident check-in/check-out log) ──────────────────────────

create table if not exists app.access_events (
  id                uuid primary key default gen_random_uuid(),
  access_profile_id uuid not null references app.access_profiles(id) on delete cascade,
  access_token_id   uuid not null references app.access_tokens(id) on delete restrict,
  event_type        app.access_event_type_enum not null,
  pmc_company_id    uuid not null references auth.users(id) on delete restrict,
  property_id       uuid not null references app.properties(id) on delete cascade,
  unit_id           uuid not null references app.units(id) on delete cascade,
  scanned_by        uuid references auth.users(id) on delete set null,
  event_at          timestamptz not null default now(),
  notes             text,
  created_at        timestamptz not null default now()
);

create index if not exists idx_access_events_profile
  on app.access_events (access_profile_id, event_at desc);
create index if not exists idx_access_events_unit
  on app.access_events (unit_id, event_at desc);
create index if not exists idx_access_events_pmc
  on app.access_events (pmc_company_id, event_at desc);

-- ── Guest Invitations ─────────────────────────────────────────────────────────

create table if not exists app.guest_invitations (
  id                         uuid primary key default gen_random_uuid(),
  inviter_access_profile_id  uuid not null references app.access_profiles(id) on delete cascade,
  inviter_user_id            uuid not null references auth.users(id) on delete restrict,
  pmc_company_id             uuid not null references auth.users(id) on delete restrict,
  property_id                uuid not null references app.properties(id) on delete cascade,
  unit_id                    uuid not null references app.units(id) on delete cascade,
  guest_name                 text not null,
  guest_phone                text,
  guest_email                text,
  status                     app.guest_access_status_enum not null default 'active',
  invited_at                 timestamptz not null default now(),
  revoked_at                 timestamptz,
  revoked_by_user_id         uuid references auth.users(id) on delete set null,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  constraint chk_guest_invitations_name_len
    check (char_length(trim(guest_name)) between 2 and 160),
  constraint chk_guest_invitations_phone_len
    check (guest_phone is null or char_length(trim(guest_phone)) between 7 and 32),
  constraint chk_guest_invitations_email_len
    check (guest_email is null or char_length(trim(guest_email)) between 5 and 320)
);

create index if not exists idx_guest_invitations_inviter_profile
  on app.guest_invitations (inviter_access_profile_id);
create index if not exists idx_guest_invitations_unit
  on app.guest_invitations (unit_id, status);
create index if not exists idx_guest_invitations_pmc
  on app.guest_invitations (pmc_company_id);

drop trigger if exists trg_guest_invitations_updated_at on app.guest_invitations;
create trigger trg_guest_invitations_updated_at
before update on app.guest_invitations
for each row execute function app.set_updated_at();

-- ── Guest Access Tokens ───────────────────────────────────────────────────────

create table if not exists app.guest_access_tokens (
  id                    uuid primary key default gen_random_uuid(),
  guest_invitation_id   uuid not null references app.guest_invitations(id) on delete cascade,
  token_value           text not null,
  token_hash            text not null,
  status                app.guest_access_status_enum not null default 'active',
  issued_at             timestamptz not null default now(),
  revoked_at            timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create unique index if not exists uq_guest_access_tokens_token_hash
  on app.guest_access_tokens (token_hash);
create unique index if not exists uq_guest_access_tokens_invitation_active
  on app.guest_access_tokens (guest_invitation_id)
  where status = 'active';

drop trigger if exists trg_guest_access_tokens_updated_at on app.guest_access_tokens;
create trigger trg_guest_access_tokens_updated_at
before update on app.guest_access_tokens
for each row execute function app.set_updated_at();

-- ── Guest Access Events ───────────────────────────────────────────────────────

create table if not exists app.guest_access_events (
  id                    uuid primary key default gen_random_uuid(),
  guest_invitation_id   uuid not null references app.guest_invitations(id) on delete cascade,
  guest_access_token_id uuid not null references app.guest_access_tokens(id) on delete restrict,
  event_type            app.access_event_type_enum not null,
  pmc_company_id        uuid not null references auth.users(id) on delete restrict,
  property_id           uuid not null references app.properties(id) on delete cascade,
  unit_id               uuid not null references app.units(id) on delete cascade,
  scanned_by            uuid references auth.users(id) on delete set null,
  event_at              timestamptz not null default now(),
  created_at            timestamptz not null default now()
);

create index if not exists idx_guest_access_events_invitation
  on app.guest_access_events (guest_invitation_id, event_at desc);
create index if not exists idx_guest_access_events_unit
  on app.guest_access_events (unit_id, event_at desc);

-- ── RLS (revoke defaults, grant via RPCs only) ────────────────────────────────

revoke all on table app.pmc_owner_occupant_invitations from public, anon, authenticated;
revoke all on table app.access_profiles                from public, anon, authenticated;
revoke all on table app.access_tokens                  from public, anon, authenticated;
revoke all on table app.access_events                  from public, anon, authenticated;
revoke all on table app.guest_invitations              from public, anon, authenticated;
revoke all on table app.guest_access_tokens            from public, anon, authenticated;
revoke all on table app.guest_access_events            from public, anon, authenticated;

-- ── Audit action types ────────────────────────────────────────────────────────

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('PMC_OWNER_OCCUPANT_INVITE_SENT',   'PMC Owner-Occupant Invite Sent',   200),
  ('PMC_OWNER_OCCUPANT_INVITE_ACCEPTED','PMC Owner-Occupant Invite Accepted',201),
  ('ACCESS_PROFILE_CREATED',           'Access Profile Created',            202),
  ('ACCESS_TOKEN_ROTATED',             'Access Token Rotated',              203),
  ('ACCESS_EVENT_RECORDED',            'Access Event Recorded',             204),
  ('OCCUPANT_ACCESS_ENDED',            'Occupant Access Ended',             205),
  ('GUEST_INVITE_CREATED',             'Guest Invite Created',              206),
  ('GUEST_ACCESS_ENDED',               'Guest Access Ended',                207)
on conflict (code) do update
set label = excluded.label, sort_order = excluded.sort_order;

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- Generate a cryptographically random hex token and return (raw, hash) pair.
create or replace function app.generate_access_token_pair()
returns table (token_value text, token_hash text)
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_raw text;
begin
  v_raw := encode(extensions.gen_random_bytes(32), 'hex');
  return query select v_raw, app.hash_token(v_raw);
end;
$$;

-- Create an access profile and issue its first token.
-- Called by both owner-occupant and tenant-occupant acceptance RPCs.
create or replace function app.internal_create_access_profile_and_token(
  p_user_id              uuid,
  p_pmc_company_id       uuid,
  p_property_id          uuid,
  p_unit_id              uuid,
  p_occupant_type        app.occupant_type_enum,
  p_lease_agreement_id   uuid default null,
  p_tenant_invitation_id uuid default null,
  p_owner_invitation_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_profile_id    uuid;
  v_token_value   text;
  v_token_hash    text;
  v_token_id      uuid;
  v_valid_until   timestamptz := now() + interval '7 days';
  v_action_id     uuid;
begin
  -- Upsert: if ended profile exists for same user+unit, create a fresh active one.
  insert into app.access_profiles (
    user_id, pmc_company_id, property_id, unit_id, occupant_type,
    lease_agreement_id, tenant_invitation_id, owner_invitation_id,
    status, activated_at
  )
  values (
    p_user_id, p_pmc_company_id, p_property_id, p_unit_id, p_occupant_type,
    p_lease_agreement_id, p_tenant_invitation_id, p_owner_invitation_id,
    'active', now()
  )
  returning id into v_profile_id;

  -- Issue first token (7-day validity).
  select t.token_value, t.token_hash
    into v_token_value, v_token_hash
  from app.generate_access_token_pair() t;

  insert into app.access_tokens (
    access_profile_id, token_value, token_hash, status, valid_from, valid_until
  )
  values (v_profile_id, v_token_value, v_token_hash, 'active', now(), v_valid_until)
  returning id into v_token_id;

  v_action_id := app.get_audit_action_id_by_code('ACCESS_PROFILE_CREATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      p_property_id, p_unit_id, p_user_id, v_action_id,
      jsonb_build_object(
        'access_profile_id', v_profile_id,
        'pmc_company_id', p_pmc_company_id,
        'occupant_type', p_occupant_type::text,
        'access_token_id', v_token_id,
        'valid_until', v_valid_until
      )
    );
  end if;

  return jsonb_build_object(
    'access_profile_id', v_profile_id,
    'access_token_id', v_token_id,
    'occupant_type', p_occupant_type::text,
    'valid_until', v_valid_until
  );
end;
$$;

-- ============================================================================
-- PMC OWNER-OCCUPANT INVITE FLOW
-- ============================================================================

create or replace function app.create_pmc_owner_occupant_invite(
  p_unit_id       uuid,
  p_email         text,
  p_name          text default null,
  p_phone         text default null,
  p_expires_days  integer default 14
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_caller_profile  record;
  v_unit            record;
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

  -- Caller must be a property_management_company account.
  select account_type into v_caller_profile
  from app.profiles
  where id = auth.uid()
  limit 1;

  if v_caller_profile.account_type is null or
     v_caller_profile.account_type::text <> 'property_management_company' then
    raise exception 'Only property management company accounts can send owner-occupant invites';
  end if;

  v_email      := nullif(trim(lower(coalesce(p_email, ''))), '');
  v_phone      := nullif(trim(coalesce(p_phone, '')), '');
  v_name       := nullif(trim(coalesce(p_name, '')), '');
  v_expires_at := now() + make_interval(days => greatest(coalesce(p_expires_days, 14), 1));

  if v_email is null and v_phone is null then
    raise exception 'An email or phone number is required';
  end if;

  -- Resolve unit + verify PMC has access to the property.
  select
    u.id   as unit_id,
    u.property_id,
    p.status as property_status
  into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.unit_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  perform app.assert_tenancy_management_access(v_unit.property_id);

  if v_unit.property_status <> 'active' then
    raise exception 'Owner-occupant invites can only be sent for active properties';
  end if;

  -- Block if there is already a live owner-occupant invite for this unit.
  if exists (
    select 1
    from app.pmc_owner_occupant_invitations i
    where i.unit_id = p_unit_id
      and i.status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
      and i.expires_at > now()
  ) then
    raise exception 'A live owner-occupant invite already exists for this unit';
  end if;

  -- Block if there is already an active access profile for this unit.
  if exists (
    select 1
    from app.access_profiles ap
    where ap.unit_id = p_unit_id
      and ap.occupant_type = 'owner_occupant'
      and ap.status = 'active'
  ) then
    raise exception 'An active owner-occupant already has access to this unit';
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into app.pmc_owner_occupant_invitations (
    pmc_company_id, property_id, unit_id, invited_by_user_id,
    invited_email, invited_phone, invited_name,
    token_hash, status, sent_at, expires_at
  )
  values (
    auth.uid(), v_unit.property_id, p_unit_id, auth.uid(),
    v_email, v_phone, v_name,
    app.hash_token(v_token), 'sent', now(), v_expires_at
  )
  returning id into v_invite_id;

  v_action_id := app.get_audit_action_id_by_code('PMC_OWNER_OCCUPANT_INVITE_SENT');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_unit.property_id, p_unit_id, auth.uid(), v_action_id,
      jsonb_build_object(
        'pmc_owner_occupant_invitation_id', v_invite_id,
        'invited_email', v_email,
        'expires_at', v_expires_at
      )
    );
  end if;

  return jsonb_build_object(
    'pmc_owner_occupant_invitation_id', v_invite_id,
    'unit_id', p_unit_id,
    'property_id', v_unit.property_id,
    'expires_at', v_expires_at,
    'token', v_token
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────

create or replace function app.accept_pmc_owner_occupant_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite      record;
  v_user_email  text;
  v_result      jsonb;
  v_action_id   uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select u.email into v_user_email
  from auth.users u
  where u.id = auth.uid()
  limit 1;

  select i.*
    into v_invite
  from app.pmc_owner_occupant_invitations i
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Owner-occupant invitation not found';
  end if;
  if v_invite.accepted_at is not null or v_invite.status = 'accepted' then
    raise exception 'Invitation has already been accepted';
  end if;
  if v_invite.cancelled_at is not null or v_invite.status = 'cancelled' then
    raise exception 'Invitation has been cancelled';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'Invitation has expired';
  end if;

  if v_invite.invited_email is not null
     and lower(trim(v_invite.invited_email)) <> lower(trim(coalesce(v_user_email, ''))) then
    raise exception 'Authenticated email does not match the invited email';
  end if;

  -- Link user and mark accepted.
  update app.pmc_owner_occupant_invitations
     set linked_user_id = auth.uid(),
         status         = 'accepted',
         accepted_at    = now(),
         updated_at     = now()
   where id = v_invite.id;

  -- Create access profile + first QR token.
  v_result := app.internal_create_access_profile_and_token(
    p_user_id              => auth.uid(),
    p_pmc_company_id       => v_invite.pmc_company_id,
    p_property_id          => v_invite.property_id,
    p_unit_id              => v_invite.unit_id,
    p_occupant_type        => 'owner_occupant',
    p_owner_invitation_id  => v_invite.id
  );

  v_action_id := app.get_audit_action_id_by_code('PMC_OWNER_OCCUPANT_INVITE_ACCEPTED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id, v_invite.unit_id, auth.uid(), v_action_id,
      jsonb_build_object(
        'pmc_owner_occupant_invitation_id', v_invite.id,
        'access_profile_id', v_result->>'access_profile_id'
      )
    );
  end if;

  return jsonb_build_object(
    'pmc_owner_occupant_invitation_id', v_invite.id,
    'unit_id', v_invite.unit_id,
    'property_id', v_invite.property_id,
    'access_profile_id', v_result->>'access_profile_id',
    'occupant_type', 'owner_occupant'
  );
end;
$$;

-- ============================================================================
-- EXTEND TENANT INVITE ACCEPTANCE TO AUTO-GENERATE ACCESS PROFILES
-- ============================================================================

-- Rebuild create_tenant_invitation to stamp pmc_company_id when the caller
-- is a property_management_company account.
create or replace function app.create_tenant_invitation(
  p_unit_id uuid,
  p_tenant_phone text default null,
  p_tenant_email text default null,
  p_delivery_channel app.tenant_invitation_delivery_channel_enum default 'email',
  p_tenant_name text default null,
  p_lease_type app.lease_type_enum default 'fixed_term',
  p_start_date date default current_date,
  p_end_date date default null,
  p_rent_amount numeric default 0,
  p_notes text default null,
  p_billing_cycle app.lease_billing_cycle_enum default 'monthly',
  p_rent_due_day_of_month integer default 5,
  p_collection_grace_period_days integer default 2,
  p_currency_code text default 'KES',
  p_expires_in_days integer default 7,
  p_template_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_unit record;
  v_snapshot record;
  v_caller_account_type text;
  v_pmc_company_id uuid;
  v_tenant_phone text;
  v_tenant_email text;
  v_tenant_name text;
  v_notes text;
  v_currency_code text;
  v_token text;
  v_expires_at timestamptz;
  v_lease_id uuid;
  v_invitation_id uuid;
  v_lease_action_id uuid;
  v_invite_action_id uuid;
  v_template_uuid uuid;
  v_template_version_id uuid;
  v_content_snapshot jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Detect PMC caller to stamp pmc context on the invitation.
  select account_type::text into v_caller_account_type
  from app.profiles
  where id = auth.uid()
  limit 1;

  if v_caller_account_type = 'property_management_company' then
    v_pmc_company_id := auth.uid();
  end if;

  v_tenant_phone := nullif(trim(coalesce(p_tenant_phone, '')), '');
  v_tenant_email := nullif(trim(lower(coalesce(p_tenant_email, ''))), '');
  v_tenant_name := nullif(trim(coalesce(p_tenant_name, '')), '');
  v_notes := nullif(trim(coalesce(p_notes, '')), '');
  v_currency_code := upper(coalesce(nullif(trim(p_currency_code), ''), 'KES'));
  v_expires_at := now() + make_interval(days => greatest(coalesce(p_expires_in_days, 7), 1));

  if p_template_id is not null and length(trim(p_template_id)) > 0 then
    begin
      v_template_uuid := trim(p_template_id)::uuid;
    exception when invalid_text_representation then
      v_template_uuid := null;
    end;

    if v_template_uuid is not null then
      select ltv.id, ltv.sections
        into v_template_version_id, v_content_snapshot
      from app.lease_template_versions ltv
      where ltv.template_id = v_template_uuid
        and ltv.status = 'active'
      order by ltv.version_number desc
      limit 1;
    end if;
  end if;

  if p_delivery_channel = 'email' and v_tenant_email is null then
    raise exception 'Tenant email is required for email delivery';
  end if;
  if p_delivery_channel = 'sms' and v_tenant_phone is null then
    raise exception 'Tenant phone number is required for SMS delivery';
  end if;
  if p_rent_amount is null or p_rent_amount < 0 then
    raise exception 'Rent amount must be zero or greater';
  end if;
  if p_rent_due_day_of_month is null or p_rent_due_day_of_month < 1 or p_rent_due_day_of_month > 28 then
    raise exception 'Rent due day must be between 1 and 28';
  end if;
  if p_collection_grace_period_days is null or p_collection_grace_period_days < 0 or p_collection_grace_period_days > 14 then
    raise exception 'Collection grace period must be between 0 and 14 days';
  end if;

  select
    u.id as unit_id,
    u.property_id,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label,
    u.expected_rate,
    p.status as property_status,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name
  into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.unit_id is null then
    raise exception 'Unit not found or deleted';
  end if;
  if v_unit.property_status <> 'active' then
    raise exception 'Tenant invites can only be created for active properties';
  end if;

  perform app.assert_tenancy_management_access(v_unit.property_id);
  perform app.expire_tenant_invitations(v_unit.property_id, p_unit_id);
  perform app.refresh_lease_agreement_statuses(v_unit.property_id, p_unit_id);
  perform app.refresh_unit_tenancy_statuses(v_unit.property_id, p_unit_id);
  perform app.ensure_unit_occupancy_snapshot_exists(p_unit_id, auth.uid());

  select occupancy_status into v_snapshot
  from app.unit_occupancy_snapshots
  where unit_id = p_unit_id
  limit 1;

  if coalesce(v_snapshot.occupancy_status::text, '') in ('occupied', 'disputed') then
    raise exception 'This unit is not currently available for a new tenant invite';
  end if;

  if exists (
    select 1
    from app.tenant_invitations i
    where i.unit_id = p_unit_id
      and app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at)
          in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  ) then
    raise exception 'A live tenant invitation already exists for this unit';
  end if;

  if exists (
    select 1
    from app.lease_agreements l
    where l.unit_id = p_unit_id
      and app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date)
          in ('pending_confirmation', 'confirmed', 'active', 'disputed')
  ) then
    raise exception 'A live lease agreement already exists for this unit';
  end if;

  if exists (
    select 1
    from app.unit_tenancies t
    where t.unit_id = p_unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
  ) then
    raise exception 'This unit already has an open tenancy';
  end if;

  if p_lease_type = 'fixed_term' and (p_end_date is null or p_end_date <= p_start_date) then
    raise exception 'Fixed-term leases require an end date after the start date';
  end if;
  if p_lease_type <> 'fixed_term' and p_end_date is not null and p_end_date <= p_start_date then
    raise exception 'Lease end date must be after the start date';
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into app.lease_agreements (
    property_id, unit_id, tenant_name, tenant_phone, entered_by_user_id, lease_type,
    start_date, end_date, billing_cycle, rent_due_day_of_month, collection_grace_period_days,
    rent_amount, currency_code, status,
    confirmation_status, agreement_notes, terms_snapshot,
    template_version_id, content_snapshot
  )
  values (
    v_unit.property_id,
    p_unit_id,
    v_tenant_name,
    v_tenant_phone,
    auth.uid(),
    p_lease_type,
    p_start_date,
    p_end_date,
    coalesce(p_billing_cycle, 'monthly'),
    p_rent_due_day_of_month,
    p_collection_grace_period_days,
    p_rent_amount,
    v_currency_code,
    'pending_confirmation',
    'awaiting_tenant',
    v_notes,
    jsonb_build_object(
      'captured_from', 'owner_web_invite',
      'captured_at', now(),
      'expected_rate_at_capture', v_unit.expected_rate,
      'unit_label', v_unit.unit_label,
      'property_name', v_unit.property_name,
      'rent_due_day_of_month', p_rent_due_day_of_month,
      'collection_grace_period_days', p_collection_grace_period_days,
      'collection_policy_label', format(
        'Rent due by the %s with collection follow-up through day %s of the month.',
        p_rent_due_day_of_month,
        p_rent_due_day_of_month + p_collection_grace_period_days
      ),
      'delivery_channel', p_delivery_channel::text,
      'tenant_email', v_tenant_email
    ),
    v_template_version_id,
    v_content_snapshot
  )
  returning id into v_lease_id;

  insert into app.tenant_invitations (
    property_id, unit_id, lease_agreement_id, invited_by_user_id, invited_phone_number,
    invited_email, invited_name, token_hash, delivery_channel, status, sent_at,
    expires_at, template_id, template_version_id, metadata,
    pmc_company_id, occupant_type
  )
  values (
    v_unit.property_id,
    p_unit_id,
    v_lease_id,
    auth.uid(),
    v_tenant_phone,
    v_tenant_email,
    v_tenant_name,
    app.hash_token(v_token),
    p_delivery_channel,
    'sent',
    now(),
    v_expires_at,
    v_template_uuid,
    v_template_version_id,
    jsonb_build_object(
      'lease_type', p_lease_type::text,
      'lease_start_date', p_start_date,
      'lease_end_date', p_end_date,
      'rent_amount', p_rent_amount,
      'currency_code', v_currency_code,
      'billing_cycle', coalesce(p_billing_cycle, 'monthly')::text,
      'rent_due_day_of_month', p_rent_due_day_of_month,
      'collection_grace_period_days', p_collection_grace_period_days,
      'notes', v_notes
    ),
    v_pmc_company_id,
    case when v_pmc_company_id is not null then 'tenant_occupant'::app.occupant_type_enum else null end
  )
  returning id into v_invitation_id;

  perform app.sync_unit_occupancy_snapshot(p_unit_id, auth.uid());
  perform app.touch_property_activity(v_unit.property_id);
  perform app.enqueue_tenant_invitation_notifications(v_invitation_id);

  v_lease_action_id := app.get_audit_action_id_by_code('LEASE_CAPTURED');
  if v_lease_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_unit.property_id,
      p_unit_id,
      auth.uid(),
      v_lease_action_id,
      jsonb_build_object(
        'lease_agreement_id', v_lease_id,
        'lease_type', p_lease_type::text,
        'billing_cycle', coalesce(p_billing_cycle, 'monthly')::text,
        'rent_due_day_of_month', p_rent_due_day_of_month,
        'collection_grace_period_days', p_collection_grace_period_days,
        'rent_amount', p_rent_amount,
        'currency_code', v_currency_code
      )
    );
  end if;

  v_invite_action_id := app.get_audit_action_id_by_code('TENANT_INVITE_SENT');
  if v_invite_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_unit.property_id,
      p_unit_id,
      auth.uid(),
      v_invite_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invitation_id,
        'lease_agreement_id', v_lease_id,
        'delivery_channel', p_delivery_channel::text,
        'expires_at', v_expires_at,
        'pmc_company_id', v_pmc_company_id
      )
    );
  end if;

  return jsonb_build_object(
    'property_id', v_unit.property_id,
    'unit_id', p_unit_id,
    'lease_agreement_id', v_lease_id,
    'tenant_invitation_id', v_invitation_id,
    'status', 'sent',
    'delivery_channel', p_delivery_channel::text,
    'expires_at', v_expires_at,
    'token', v_token
  );
end;
$$;

-- Rebuild accept_tenant_invitation to auto-generate access profile for PMC tenants.
create or replace function app.accept_tenant_invitation(
  p_token text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite record;
  v_user_email text;
  v_effective_status app.tenant_invitation_status_enum;
  v_tenancy_id uuid;
  v_target_tenancy_status app.unit_tenancy_status_enum;
  v_action_id uuid;
  v_access_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select u.email into v_user_email
  from auth.users u
  where u.id = auth.uid()
  limit 1;

  select
    i.*,
    l.start_date,
    l.end_date,
    l.confirmation_status,
    l.status as lease_status
  into v_invite
  from app.tenant_invitations i
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired' then
    raise exception 'Invitation has expired';
  end if;
  if v_effective_status = 'cancelled' then
    raise exception 'Invitation has been cancelled';
  end if;
  if v_effective_status = 'accepted' then
    raise exception 'Invitation has already been accepted';
  end if;

  if v_invite.invited_email is not null
     and lower(trim(v_invite.invited_email)) <> lower(trim(coalesce(v_user_email, ''))) then
    raise exception 'Authenticated email does not match the invited email';
  end if;

  if exists (
    select 1
    from app.unit_tenancies t
    where t.unit_id = v_invite.unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
      and t.tenant_user_id <> auth.uid()
  ) then
    raise exception 'This unit already has an active or scheduled tenant';
  end if;

  v_target_tenancy_status := case
    when v_invite.start_date <= current_date then 'active'::app.unit_tenancy_status_enum
    else 'scheduled'::app.unit_tenancy_status_enum
  end;

  update app.tenant_invitations
     set linked_user_id = auth.uid(),
         status = 'accepted'::app.tenant_invitation_status_enum,
         accepted_at = now(),
         updated_at = now()
   where id = v_invite.id;

  update app.lease_agreements
     set tenant_user_id = auth.uid(),
         confirmation_status = 'confirmed'::app.lease_confirmation_status_enum,
         tenant_confirmed_at = now(),
         tenant_response_notes = nullif(trim(coalesce(p_notes, '')), ''),
         status = case
           when start_date <= current_date then 'active'::app.lease_agreement_status_enum
           else 'confirmed'::app.lease_agreement_status_enum
         end,
         updated_at = now()
   where id = v_invite.lease_agreement_id;

  insert into app.unit_tenancies (
    property_id, unit_id, lease_agreement_id, tenant_invitation_id, tenant_user_id,
    status, starts_on, ends_on, activated_at, created_by_user_id, notes,
    pmc_company_id, occupant_type
  )
  values (
    v_invite.property_id,
    v_invite.unit_id,
    v_invite.lease_agreement_id,
    v_invite.id,
    auth.uid(),
    v_target_tenancy_status,
    v_invite.start_date,
    v_invite.end_date,
    case when v_target_tenancy_status = 'active' then now() else null end,
    auth.uid(),
    nullif(trim(coalesce(p_notes, '')), ''),
    v_invite.pmc_company_id,
    v_invite.occupant_type
  )
  on conflict (lease_agreement_id)
  do update
    set tenant_user_id = excluded.tenant_user_id,
        tenant_invitation_id = excluded.tenant_invitation_id,
        status = excluded.status,
        starts_on = excluded.starts_on,
        ends_on = excluded.ends_on,
        activated_at = excluded.activated_at,
        pmc_company_id = excluded.pmc_company_id,
        occupant_type = excluded.occupant_type,
        updated_at = now()
  returning id into v_tenancy_id;

  -- Auto-generate QR access profile for PMC tenant occupants.
  if v_invite.pmc_company_id is not null then
    v_access_result := app.internal_create_access_profile_and_token(
      p_user_id              => auth.uid(),
      p_pmc_company_id       => v_invite.pmc_company_id,
      p_property_id          => v_invite.property_id,
      p_unit_id              => v_invite.unit_id,
      p_occupant_type        => 'tenant_occupant',
      p_lease_agreement_id   => v_invite.lease_agreement_id,
      p_tenant_invitation_id => v_invite.id
    );
  end if;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, auth.uid());
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('LEASE_CONFIRMATION_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'lease_agreement_id', v_invite.lease_agreement_id,
        'tenancy_id', v_tenancy_id,
        'confirmation_status', 'confirmed',
        'tenancy_status', v_target_tenancy_status::text,
        'access_profile_id', v_access_result->>'access_profile_id'
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id', v_invite.lease_agreement_id,
    'tenancy_id', v_tenancy_id,
    'unit_id', v_invite.unit_id,
    'property_id', v_invite.property_id,
    'tenancy_status', v_target_tenancy_status::text,
    'lease_status', case when v_invite.start_date <= current_date then 'active' else 'confirmed' end,
    'access_profile_id', v_access_result->>'access_profile_id'
  );
end;
$$;

-- ============================================================================
-- QR TOKEN MANAGEMENT
-- ============================================================================

-- Rotate a single expired or soon-to-expire token for a profile.
-- Returns the new raw token value so the mobile app can display the updated QR.
create or replace function app.rotate_access_token(p_access_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_old_token_id  uuid;
  v_new_token_id  uuid;
  v_token_value   text;
  v_token_hash    text;
  v_valid_until   timestamptz := now() + interval '7 days';
  v_action_id     uuid;
  v_profile       record;
begin
  select ap.user_id, ap.property_id, ap.unit_id, ap.status
    into v_profile
  from app.access_profiles ap
  where ap.id = p_access_profile_id
  limit 1;

  if v_profile.user_id is null then
    raise exception 'Access profile not found';
  end if;
  if v_profile.status <> 'active' then
    raise exception 'Access profile is not active';
  end if;

  -- Mark the current active token as rotated.
  update app.access_tokens
     set status = 'rotated', rotated_at = now(), updated_at = now()
   where access_profile_id = p_access_profile_id
     and status = 'active'
  returning id into v_old_token_id;

  -- Issue fresh token.
  select t.token_value, t.token_hash
    into v_token_value, v_token_hash
  from app.generate_access_token_pair() t;

  insert into app.access_tokens (
    access_profile_id, token_value, token_hash, status, valid_from, valid_until
  )
  values (p_access_profile_id, v_token_value, v_token_hash, 'active', now(), v_valid_until)
  returning id into v_new_token_id;

  v_action_id := app.get_audit_action_id_by_code('ACCESS_TOKEN_ROTATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_profile.property_id, v_profile.unit_id, v_profile.user_id, v_action_id,
      jsonb_build_object(
        'access_profile_id', p_access_profile_id,
        'old_token_id', v_old_token_id,
        'new_token_id', v_new_token_id,
        'valid_until', v_valid_until
      )
    );
  end if;

  return jsonb_build_object(
    'access_token_id', v_new_token_id,
    'token_value', v_token_value,
    'valid_until', v_valid_until
  );
end;
$$;

-- Batch rotation: called by a scheduled job or lazily on first access per day.
create or replace function app.rotate_expired_access_tokens()
returns integer
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_profile_ids uuid[];
  v_pid         uuid;
  v_count       integer := 0;
begin
  select coalesce(array_agg(distinct at2.access_profile_id), array[]::uuid[])
    into v_profile_ids
  from app.access_tokens at2
  join app.access_profiles ap on ap.id = at2.access_profile_id
  where at2.status = 'active'
    and at2.valid_until < now()
    and ap.status = 'active';

  foreach v_pid in array v_profile_ids loop
    perform app.rotate_access_token(v_pid);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ============================================================================
-- MOBILE APP: GET MY ACCESS PROFILE
-- ============================================================================
-- Called by the mobile app on every load of the Access screen.
-- Auto-rotates the token if expired before returning.
-- Returns the raw token_value so the mobile app can render the QR code.

create or replace function app.get_my_access_profile()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_profile   record;
  v_token     record;
  v_events    jsonb;
  v_result    jsonb;
  v_rotated   jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select
    ap.id,
    ap.pmc_company_id,
    ap.property_id,
    ap.unit_id,
    ap.occupant_type,
    ap.status,
    ap.activated_at,
    p.display_name   as property_name,
    u.label          as unit_label,
    pmc_p.company_name as pmc_company_name
  into v_profile
  from app.access_profiles ap
  join app.properties p  on p.id = ap.property_id
  join app.units u        on u.id = ap.unit_id
  join app.profiles pmc_p on pmc_p.id = ap.pmc_company_id
  where ap.user_id = auth.uid()
    and ap.status = 'active'
  order by ap.activated_at desc
  limit 1;

  if v_profile.id is null then
    return jsonb_build_object('has_access', false);
  end if;

  -- Load active token; rotate lazily if expired.
  select at2.id, at2.token_value, at2.status, at2.valid_from, at2.valid_until
    into v_token
  from app.access_tokens at2
  where at2.access_profile_id = v_profile.id
    and at2.status = 'active'
  limit 1;

  if v_token.id is null or v_token.valid_until < now() then
    v_rotated   := app.rotate_access_token(v_profile.id);
    v_token.id          := (v_rotated->>'access_token_id')::uuid;
    v_token.token_value := v_rotated->>'token_value';
    v_token.valid_until := (v_rotated->>'valid_until')::timestamptz;
    v_token.valid_from  := now();
    v_token.status      := 'active';
  end if;

  -- Fetch last 10 access events for the log display.
  select coalesce(jsonb_agg(row_to_json(ev)::jsonb order by ev.event_at desc), '[]'::jsonb)
    into v_events
  from (
    select
      ae.id,
      ae.event_type,
      ae.event_at,
      ae.notes
    from app.access_events ae
    where ae.access_profile_id = v_profile.id
    order by ae.event_at desc
    limit 10
  ) ev;

  return jsonb_build_object(
    'has_access',      true,
    'access_profile_id', v_profile.id,
    'pmc_company_id',  v_profile.pmc_company_id,
    'pmc_company_name', coalesce(v_profile.pmc_company_name, 'Property Management'),
    'property_id',     v_profile.property_id,
    'property_name',   coalesce(nullif(trim(v_profile.property_name), ''), 'Untitled Property'),
    'unit_id',         v_profile.unit_id,
    'unit_label',      coalesce(nullif(trim(v_profile.unit_label), ''), 'My Unit'),
    'occupant_type',   v_profile.occupant_type::text,
    'status',          v_profile.status::text,
    'activated_at',    v_profile.activated_at,
    'token_value',     v_token.token_value,
    'token_valid_from', v_token.valid_from,
    'token_valid_until', v_token.valid_until,
    'recent_events',   v_events
  );
end;
$$;

-- ============================================================================
-- RESIDENT ACCESS EVENT RECORDING (guard scan)
-- ============================================================================

create or replace function app.record_resident_access_event(
  p_token_value text,
  p_event_type  app.access_event_type_enum,
  p_notes       text default null,
  p_scanned_by  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_token   record;
  v_profile record;
  v_last    record;
  v_event_id uuid;
  v_action_id uuid;
begin
  if p_token_value is null or length(trim(p_token_value)) = 0 then
    raise exception 'Token value is required';
  end if;

  -- Validate token.
  select at2.id, at2.access_profile_id, at2.status, at2.valid_until
    into v_token
  from app.access_tokens at2
  where at2.token_hash = app.hash_token(trim(p_token_value))
  limit 1;

  if v_token.id is null then
    return jsonb_build_object('valid', false, 'reason', 'Token not found');
  end if;
  if v_token.status <> 'active' then
    return jsonb_build_object('valid', false, 'reason', 'Token is no longer active');
  end if;
  if v_token.valid_until < now() then
    return jsonb_build_object('valid', false, 'reason', 'Token has expired — resident QR will refresh automatically');
  end if;

  select ap.id, ap.user_id, ap.pmc_company_id, ap.property_id, ap.unit_id, ap.status,
         ap.occupant_type
    into v_profile
  from app.access_profiles ap
  where ap.id = v_token.access_profile_id
  limit 1;

  if v_profile.status <> 'active' then
    return jsonb_build_object('valid', false, 'reason', 'Resident no longer has active access');
  end if;

  -- Enforce check-in/check-out sequencing to prevent duplicate active check-ins.
  select ae.event_type
    into v_last
  from app.access_events ae
  where ae.access_profile_id = v_profile.id
  order by ae.event_at desc
  limit 1;

  if p_event_type = 'check_in' and v_last.event_type = 'check_in' then
    return jsonb_build_object(
      'valid', true,
      'blocked', true,
      'reason', 'This resident is already checked in. Please check them out first before recording another check-in.'
    );
  end if;

  insert into app.access_events (
    access_profile_id, access_token_id, event_type,
    pmc_company_id, property_id, unit_id,
    scanned_by, event_at, notes
  )
  values (
    v_profile.id, v_token.id, p_event_type,
    v_profile.pmc_company_id, v_profile.property_id, v_profile.unit_id,
    p_scanned_by, now(), nullif(trim(coalesce(p_notes, '')), '')
  )
  returning id into v_event_id;

  return jsonb_build_object(
    'valid',            true,
    'blocked',          false,
    'access_event_id',  v_event_id,
    'event_type',       p_event_type::text,
    'access_profile_id', v_profile.id,
    'occupant_type',    v_profile.occupant_type::text,
    'unit_id',          v_profile.unit_id,
    'property_id',      v_profile.property_id,
    'event_at',         now()
  );
end;
$$;

-- ============================================================================
-- END OCCUPANT ACCESS
-- ============================================================================

create or replace function app.end_occupant_access(
  p_access_profile_id uuid,
  p_reason            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_profile  record;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select ap.id, ap.user_id, ap.pmc_company_id, ap.property_id, ap.unit_id, ap.status
    into v_profile
  from app.access_profiles ap
  where ap.id = p_access_profile_id
  limit 1;

  if v_profile.id is null then
    raise exception 'Access profile not found';
  end if;
  if v_profile.status = 'ended' then
    raise exception 'Access profile is already ended';
  end if;

  -- Caller must be the PMC that owns this profile or have property access.
  if v_profile.pmc_company_id <> auth.uid() then
    perform app.assert_tenancy_management_access(v_profile.property_id);
  end if;

  -- Invalidate active token.
  update app.access_tokens
     set status = 'invalidated', invalidated_at = now(), updated_at = now()
   where access_profile_id = p_access_profile_id
     and status = 'active';

  -- End profile.
  update app.access_profiles
     set status = 'ended', ended_at = now(),
         ended_reason = nullif(trim(coalesce(p_reason, '')), ''),
         updated_at = now()
   where id = p_access_profile_id;

  -- Also revoke any active guest invitations tied to this profile.
  update app.guest_invitations
     set status = 'revoked', revoked_at = now(), revoked_by_user_id = auth.uid(), updated_at = now()
   where inviter_access_profile_id = p_access_profile_id
     and status = 'active';

  -- Invalidate guest tokens for revoked guests.
  update app.guest_access_tokens gat
     set status = 'revoked', revoked_at = now(), updated_at = now()
  from app.guest_invitations gi
  where gat.guest_invitation_id = gi.id
    and gi.inviter_access_profile_id = p_access_profile_id
    and gat.status = 'active';

  v_action_id := app.get_audit_action_id_by_code('OCCUPANT_ACCESS_ENDED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_profile.property_id, v_profile.unit_id, auth.uid(), v_action_id,
      jsonb_build_object(
        'access_profile_id', p_access_profile_id,
        'occupant_user_id', v_profile.user_id,
        'reason', p_reason
      )
    );
  end if;

  return jsonb_build_object(
    'access_profile_id', p_access_profile_id,
    'status', 'ended'
  );
end;
$$;

-- ============================================================================
-- GUEST INVITE FLOW
-- ============================================================================

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
  v_profile       record;
  v_guest_name    text;
  v_guest_phone   text;
  v_guest_email   text;
  v_invite_id     uuid;
  v_token_value   text;
  v_token_hash    text;
  v_token_id      uuid;
  v_action_id     uuid;
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

  -- Create guest invitation.
  insert into app.guest_invitations (
    inviter_access_profile_id, inviter_user_id, pmc_company_id,
    property_id, unit_id, guest_name, guest_phone, guest_email,
    status, invited_at
  )
  values (
    v_profile.id, auth.uid(), v_profile.pmc_company_id,
    v_profile.property_id, v_profile.unit_id, v_guest_name, v_guest_phone, v_guest_email,
    'active', now()
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
    'guest_name', v_guest_name,
    'token_value', v_token_value,
    'unit_id', v_profile.unit_id,
    'property_id', v_profile.property_id,
    'status', 'active'
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────

create or replace function app.end_guest_access(p_guest_invitation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite  record;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select gi.id, gi.inviter_user_id, gi.status, gi.pmc_company_id,
         gi.property_id, gi.unit_id, gi.guest_name
    into v_invite
  from app.guest_invitations gi
  where gi.id = p_guest_invitation_id
  limit 1;

  if v_invite.id is null then
    raise exception 'Guest invitation not found';
  end if;
  if v_invite.inviter_user_id <> auth.uid() then
    raise exception 'Only the person who invited this guest can end their access';
  end if;
  if v_invite.status = 'revoked' then
    raise exception 'Guest access has already been ended';
  end if;

  update app.guest_invitations
     set status = 'revoked', revoked_at = now(), revoked_by_user_id = auth.uid(), updated_at = now()
   where id = p_guest_invitation_id;

  update app.guest_access_tokens
     set status = 'revoked', revoked_at = now(), updated_at = now()
   where guest_invitation_id = p_guest_invitation_id
     and status = 'active';

  v_action_id := app.get_audit_action_id_by_code('GUEST_ACCESS_ENDED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id, v_invite.unit_id, auth.uid(), v_action_id,
      jsonb_build_object(
        'guest_invitation_id', p_guest_invitation_id,
        'guest_name', v_invite.guest_name
      )
    );
  end if;

  return jsonb_build_object(
    'guest_invitation_id', p_guest_invitation_id,
    'guest_name', v_invite.guest_name,
    'status', 'revoked'
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────

create or replace function app.get_my_guest_invitations()
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_profile_id uuid;
  v_guests     jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select ap.id into v_profile_id
  from app.access_profiles ap
  where ap.user_id = auth.uid() and ap.status = 'active'
  order by ap.activated_at desc
  limit 1;

  if v_profile_id is null then
    return jsonb_build_object('guests', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(g order by g.invited_at desc), '[]'::jsonb)
    into v_guests
  from (
    select
      gi.id,
      gi.guest_name,
      gi.guest_phone,
      gi.guest_email,
      gi.status,
      gi.invited_at,
      gi.revoked_at,
      gat.token_value,
      gat.issued_at as token_issued_at,
      -- Last event for this guest
      (
        select gae.event_type
        from app.guest_access_events gae
        where gae.guest_invitation_id = gi.id
        order by gae.event_at desc
        limit 1
      ) as last_event_type,
      (
        select gae.event_at
        from app.guest_access_events gae
        where gae.guest_invitation_id = gi.id
        order by gae.event_at desc
        limit 1
      ) as last_event_at
    from app.guest_invitations gi
    left join app.guest_access_tokens gat
           on gat.guest_invitation_id = gi.id
          and gat.status = 'active'
    where gi.inviter_access_profile_id = v_profile_id
    order by gi.invited_at desc
    limit 50
  ) g;

  return jsonb_build_object('guests', v_guests);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────

create or replace function app.record_guest_access_event(
  p_token_value text,
  p_event_type  app.access_event_type_enum,
  p_scanned_by  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_token   record;
  v_invite  record;
  v_last    record;
  v_event_id uuid;
begin
  if p_token_value is null or length(trim(p_token_value)) = 0 then
    raise exception 'Token value is required';
  end if;

  select gat.id, gat.guest_invitation_id, gat.status
    into v_token
  from app.guest_access_tokens gat
  where gat.token_hash = app.hash_token(trim(p_token_value))
  limit 1;

  if v_token.id is null then
    return jsonb_build_object('valid', false, 'reason', 'Guest token not found');
  end if;
  if v_token.status <> 'active' then
    return jsonb_build_object('valid', false, 'reason', 'Guest access has been revoked');
  end if;

  select gi.id, gi.status, gi.guest_name, gi.pmc_company_id,
         gi.property_id, gi.unit_id
    into v_invite
  from app.guest_invitations gi
  where gi.id = v_token.guest_invitation_id
  limit 1;

  if v_invite.status <> 'active' then
    return jsonb_build_object('valid', false, 'reason', 'Guest access has been revoked');
  end if;

  -- Prevent duplicate active check-ins for guests.
  select gae.event_type into v_last
  from app.guest_access_events gae
  where gae.guest_invitation_id = v_invite.id
  order by gae.event_at desc
  limit 1;

  if p_event_type = 'check_in' and v_last.event_type = 'check_in' then
    return jsonb_build_object(
      'valid', true,
      'blocked', true,
      'reason', format(
        'This guest (%s) is already checked in. Please check them out before recording another check-in.',
        v_invite.guest_name
      )
    );
  end if;

  insert into app.guest_access_events (
    guest_invitation_id, guest_access_token_id, event_type,
    pmc_company_id, property_id, unit_id, scanned_by, event_at
  )
  values (
    v_invite.id, v_token.id, p_event_type,
    v_invite.pmc_company_id, v_invite.property_id, v_invite.unit_id,
    p_scanned_by, now()
  )
  returning id into v_event_id;

  return jsonb_build_object(
    'valid',              true,
    'blocked',            false,
    'guest_access_event_id', v_event_id,
    'event_type',         p_event_type::text,
    'guest_name',         v_invite.guest_name,
    'unit_id',            v_invite.unit_id,
    'property_id',        v_invite.property_id,
    'event_at',           now()
  );
end;
$$;
