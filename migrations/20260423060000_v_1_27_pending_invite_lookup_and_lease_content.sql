-- ============================================================================
-- V 1 27: Pending Invite Lookup and Lease Content for Authenticated Tenants
-- ============================================================================
-- Purpose
--   - Allow authenticated tenants to find their pending invite by email match,
--     without needing the plaintext invite token (deep-link bypass).
--   - Allow tenant to accept the invite they were found with, without a token.
--   - Extend get_tenant_invitation_by_token to return content_snapshot so
--     the mobile app can render the full template-rendered lease clauses.
--
-- Context
--   - An owner invites a tenant → lease_agreement + tenant_invitation created.
--   - Tenant opens the app (already authenticated or logs in fresh).
--   - get_pending_tenant_invite() checks for any live invite matching the
--     authenticated user's email and surfaces it automatically.
--   - accept_pending_tenant_invite() performs the same acceptance logic as
--     accept_tenant_invitation() but uses auth.uid() + email matching instead
--     of a token hash, enabling the in-app acceptance flow.
-- ============================================================================

create schema if not exists app;

-- ─── Update get_tenant_invitation_by_token ────────────────────────────────────
-- Adds content_snapshot to the returned payload so the mobile app can display
-- the full rendered lease sections (from V 1 25 template engine).

create or replace function app.get_tenant_invitation_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite              record;
  v_effective_status    app.tenant_invitation_status_enum;
  v_response_status     text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.invited_name,
    i.invited_email,
    i.invited_phone_number,
    i.delivery_channel,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    i.opened_at,
    i.signup_started_at,
    p.display_name  as property_name,
    u.label         as unit_label,
    l.lease_type,
    l.start_date,
    l.end_date,
    l.billing_cycle,
    l.rent_amount,
    l.currency_code,
    l.confirmation_status,
    l.status        as lease_status,
    l.content_snapshot          -- NEW: rendered sections from template engine
  into v_invite
  from app.tenant_invitations i
  join app.properties p on p.id = i.property_id
  join app.units u       on u.id = i.unit_id
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired'   then raise exception 'Invitation has expired';   end if;
  if v_effective_status = 'cancelled' then raise exception 'Invitation has been cancelled'; end if;

  update app.tenant_invitations
     set status    = case
                       when status in ('pending_delivery', 'pending', 'sent') then 'opened'
                       else status
                     end,
         opened_at = coalesce(opened_at, now()),
         updated_at = now()
   where id = v_invite.id;

  v_response_status := case
    when v_effective_status in ('pending_delivery', 'pending', 'sent') then 'opened'
    else v_effective_status::text
  end;

  return jsonb_build_object(
    'tenant_invitation_id',   v_invite.id,
    'property_id',            v_invite.property_id,
    'unit_id',                v_invite.unit_id,
    'lease_agreement_id',     v_invite.lease_agreement_id,
    'property_name',          coalesce(nullif(trim(v_invite.property_name), ''), 'Untitled Property'),
    'unit_label',             coalesce(nullif(trim(v_invite.unit_label), ''), 'Unlabelled Unit'),
    'invited_name',           v_invite.invited_name,
    'invited_email',          v_invite.invited_email,
    'invited_phone_number',   v_invite.invited_phone_number,
    'delivery_channel',       v_invite.delivery_channel::text,
    'status',                 v_response_status,
    'content_snapshot',       v_invite.content_snapshot,   -- NEW
    'lease', jsonb_build_object(
      'lease_type',           v_invite.lease_type::text,
      'start_date',           v_invite.start_date,
      'end_date',             v_invite.end_date,
      'billing_cycle',        v_invite.billing_cycle::text,
      'rent_amount',          v_invite.rent_amount,
      'currency_code',        v_invite.currency_code,
      'confirmation_status',  v_invite.confirmation_status::text,
      'status',               v_invite.lease_status::text
    )
  );
end;
$$;

-- ─── get_pending_tenant_invite ────────────────────────────────────────────────
-- Called on app startup and after login/signup for any authenticated user.
-- Returns the live invite (if any) whose invited_email matches the caller's
-- account email. Returns NULL (not an error) when no pending invite exists.
-- Marks the invite as 'opened' on first lookup.

create or replace function app.get_pending_tenant_invite()
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id           uuid := auth.uid();
  v_user_email        text;
  v_invite            record;
  v_effective_status  app.tenant_invitation_status_enum;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select lower(trim(u.email))
    into v_user_email
  from auth.users u
  where u.id = v_user_id
  limit 1;

  if v_user_email is null or v_user_email = '' then
    return null;
  end if;

  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.invited_name,
    i.invited_email,
    i.invited_phone_number,
    i.delivery_channel,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    i.opened_at,
    p.display_name  as property_name,
    u.label         as unit_label,
    l.lease_type,
    l.start_date,
    l.end_date,
    l.billing_cycle,
    l.rent_amount,
    l.currency_code,
    l.confirmation_status,
    l.status        as lease_status,
    l.content_snapshot
  into v_invite
  from app.tenant_invitations i
  join app.properties p       on p.id = i.property_id and p.deleted_at is null
  join app.units u             on u.id = i.unit_id and u.deleted_at is null
  join app.lease_agreements l  on l.id = i.lease_agreement_id
  where lower(trim(coalesce(i.invited_email, ''))) = v_user_email
    and app.get_effective_tenant_invitation_status(
          i.status, i.expires_at, i.accepted_at, i.cancelled_at
        ) in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  order by i.created_at desc
  limit 1;

  -- No pending invite — return null silently (not an error condition)
  if v_invite.id is null then
    return null;
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  -- Mark as opened on first authenticated lookup
  update app.tenant_invitations
     set status     = case
                        when status in ('pending_delivery', 'pending', 'sent') then 'opened'
                        else status
                      end,
         opened_at  = coalesce(opened_at, now()),
         updated_at = now()
   where id = v_invite.id;

  return jsonb_build_object(
    'tenant_invitation_id',   v_invite.id,
    'property_id',            v_invite.property_id,
    'unit_id',                v_invite.unit_id,
    'lease_agreement_id',     v_invite.lease_agreement_id,
    'property_name',          coalesce(nullif(trim(v_invite.property_name), ''), 'Untitled Property'),
    'unit_label',             coalesce(nullif(trim(v_invite.unit_label), ''), 'Unlabelled Unit'),
    'invited_name',           v_invite.invited_name,
    'invited_email',          v_invite.invited_email,
    'invited_phone_number',   v_invite.invited_phone_number,
    'delivery_channel',       v_invite.delivery_channel::text,
    'status',                 case
                                when v_effective_status in ('pending_delivery','pending','sent')
                                then 'opened'
                                else v_effective_status::text
                              end,
    'content_snapshot',       v_invite.content_snapshot,
    'lease', jsonb_build_object(
      'lease_type',           v_invite.lease_type::text,
      'start_date',           v_invite.start_date,
      'end_date',             v_invite.end_date,
      'billing_cycle',        v_invite.billing_cycle::text,
      'rent_amount',          v_invite.rent_amount,
      'currency_code',        v_invite.currency_code,
      'confirmation_status',  v_invite.confirmation_status::text,
      'status',               v_invite.lease_status::text
    )
  );
end;
$$;

-- ─── accept_pending_tenant_invite ─────────────────────────────────────────────
-- Accepts the pending invite for the authenticated user without requiring the
-- plaintext token. Mirrors accept_tenant_invitation() logic exactly, but uses
-- email matching on auth.uid() instead of token_hash matching.
-- Called by the mobile app when a tenant accepts from the in-app flow
-- (i.e. no deep-link token was involved).

create or replace function app.accept_pending_tenant_invite(p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id             uuid := auth.uid();
  v_user_email          text;
  v_invite              record;
  v_tenancy_id          uuid;
  v_target_tenancy_status app.unit_tenancy_status_enum;
  v_effective_status    app.tenant_invitation_status_enum;
  v_action_id           uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select lower(trim(u.email))
    into v_user_email
  from auth.users u
  where u.id = v_user_id
  limit 1;

  if v_user_email is null or v_user_email = '' then
    raise exception 'Could not determine account email for acceptance';
  end if;

  -- Find and lock the pending invite row
  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    l.start_date,
    l.end_date
  into v_invite
  from app.tenant_invitations i
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where lower(trim(coalesce(i.invited_email, ''))) = v_user_email
    and app.get_effective_tenant_invitation_status(
          i.status, i.expires_at, i.accepted_at, i.cancelled_at
        ) in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  order by i.created_at desc
  limit 1
  for update;

  if v_invite.id is null then
    raise exception 'No pending invitation was found for your account.';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired' then
    raise exception 'This invitation has expired. Please request a new one.';
  end if;
  if v_effective_status = 'cancelled' then
    raise exception 'This invitation was cancelled by the property manager.';
  end if;

  -- Guard: unit must not already have a different active tenant
  if exists (
    select 1 from app.unit_tenancies t
    where t.unit_id = v_invite.unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
      and t.tenant_user_id <> v_user_id
  ) then
    raise exception 'This unit already has an active or scheduled tenant.';
  end if;

  v_target_tenancy_status := case
    when v_invite.start_date <= current_date then 'active'
    else 'scheduled'
  end::app.unit_tenancy_status_enum;

  -- Accept the invitation
  update app.tenant_invitations
     set linked_user_id = v_user_id,
         status         = 'accepted',
         accepted_at    = now(),
         updated_at     = now()
   where id = v_invite.id;

  -- Confirm the lease
  update app.lease_agreements
     set tenant_user_id         = v_user_id,
         confirmation_status    = 'confirmed',
         tenant_confirmed_at    = now(),
         tenant_response_notes  = nullif(trim(coalesce(p_notes, '')), ''),
         status                 = case
                                    when start_date <= current_date then 'active'
                                    else 'confirmed'
                                  end,
         updated_at             = now()
   where id = v_invite.lease_agreement_id;

  -- Create or update tenancy
  insert into app.unit_tenancies (
    property_id, unit_id, lease_agreement_id, tenant_invitation_id,
    tenant_user_id, status, starts_on, ends_on, activated_at,
    created_by_user_id, notes
  ) values (
    v_invite.property_id,
    v_invite.unit_id,
    v_invite.lease_agreement_id,
    v_invite.id,
    v_user_id,
    v_target_tenancy_status,
    v_invite.start_date,
    v_invite.end_date,
    case when v_target_tenancy_status = 'active' then now() else null end,
    v_user_id,
    nullif(trim(coalesce(p_notes, '')), '')
  )
  on conflict (lease_agreement_id)
  do update
    set tenant_user_id       = excluded.tenant_user_id,
        tenant_invitation_id = excluded.tenant_invitation_id,
        status               = excluded.status,
        starts_on            = excluded.starts_on,
        ends_on              = excluded.ends_on,
        activated_at         = excluded.activated_at,
        updated_at           = now()
  returning id into v_tenancy_id;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, v_user_id);
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('LEASE_CONFIRMATION_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      v_user_id,
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'lease_agreement_id',   v_invite.lease_agreement_id,
        'tenancy_id',           v_tenancy_id,
        'confirmation_status',  'confirmed',
        'tenancy_status',       v_target_tenancy_status::text,
        'acceptance_method',    'authenticated_user_lookup'
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id',   v_invite.lease_agreement_id,
    'tenancy_id',           v_tenancy_id,
    'unit_id',              v_invite.unit_id,
    'property_id',          v_invite.property_id,
    'tenancy_status',       v_target_tenancy_status::text,
    'lease_status',         case when v_invite.start_date <= current_date then 'active' else 'confirmed' end
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on function app.get_pending_tenant_invite()
  from public, anon, authenticated;
revoke all on function app.accept_pending_tenant_invite(text)
  from public, anon, authenticated;

-- Any authenticated user can check for their own pending invite
grant execute on function app.get_pending_tenant_invite()
  to authenticated;

-- Any authenticated user can accept their own pending invite
grant execute on function app.accept_pending_tenant_invite(text)
  to authenticated;
