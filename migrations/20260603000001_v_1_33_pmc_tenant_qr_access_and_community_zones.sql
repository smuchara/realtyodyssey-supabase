-- ============================================================================
-- V1.33 – PMC tenant QR access fix + property community zone auto-creation
-- ============================================================================
-- Bug 1: accept_pending_tenant_invite (v1.13) was never updated when v1.26
--        added access-profile auto-creation to accept_tenant_invitation.
--        PMC-invited tenants who accept in-app (no deep-link token) never
--        received a QR access profile, so the Access tab never appeared.
--        Fix: fetch pmc_company_id/occupant_type from the invite, stamp them
--        on unit_tenancies, and call internal_create_access_profile_and_token.
--
-- Bug 2: Community zones were only auto-created when an owner first opened
--        /owner/community-hub in the web app. After a DB reset (or before
--        that page was visited), tenants saw "not within a community zone"
--        on first load even though a property was fully onboarded.
--        Fix: auto-create the zone at activate_property time when the
--        property has coordinates.
-- ============================================================================

-- ─── Fix 1: accept_pending_tenant_invite with PMC access profile creation ─────

create or replace function app.accept_pending_tenant_invite(p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_user_id               uuid := auth.uid();
  v_user_email            text;
  v_invite                record;
  v_tenancy_id            uuid;
  v_target_tenancy_status app.unit_tenancy_status_enum;
  v_effective_status      app.tenant_invitation_status_enum;
  v_access_result         jsonb;
  v_action_id             uuid;
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

  -- Find and lock the pending invite row (includes pmc_company_id + occupant_type
  -- which were missing from the v1.13 version of this function).
  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    i.pmc_company_id,
    i.occupant_type,
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

  -- Create or update tenancy; now stamps pmc_company_id + occupant_type
  -- so the tenancy record correctly reflects the PMC context.
  insert into app.unit_tenancies (
    property_id, unit_id, lease_agreement_id, tenant_invitation_id,
    tenant_user_id, status, starts_on, ends_on, activated_at,
    created_by_user_id, notes, pmc_company_id, occupant_type
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
    nullif(trim(coalesce(p_notes, '')), ''),
    v_invite.pmc_company_id,
    v_invite.occupant_type
  )
  on conflict (lease_agreement_id)
  do update
    set tenant_user_id       = excluded.tenant_user_id,
        tenant_invitation_id = excluded.tenant_invitation_id,
        status               = excluded.status,
        starts_on            = excluded.starts_on,
        ends_on              = excluded.ends_on,
        activated_at         = excluded.activated_at,
        pmc_company_id       = excluded.pmc_company_id,
        occupant_type        = excluded.occupant_type,
        updated_at           = now()
  returning id into v_tenancy_id;

  -- Auto-generate QR access profile for PMC tenant occupants (mirrors the
  -- same block in accept_tenant_invitation that was added in v1.26).
  if v_invite.pmc_company_id is not null then
    v_access_result := app.internal_create_access_profile_and_token(
      p_user_id              => v_user_id,
      p_pmc_company_id       => v_invite.pmc_company_id,
      p_property_id          => v_invite.property_id,
      p_unit_id              => v_invite.unit_id,
      p_occupant_type        => 'tenant_occupant',
      p_lease_agreement_id   => v_invite.lease_agreement_id,
      p_tenant_invitation_id => v_invite.id
    );
  end if;

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
        'acceptance_method',    'authenticated_user_lookup',
        'access_profile_id',    v_access_result->>'access_profile_id'
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
    'lease_status',         case when v_invite.start_date <= current_date then 'active' else 'confirmed' end,
    'access_profile_id',    v_access_result->>'access_profile_id'
  );
end;
$$;

revoke all on function app.accept_pending_tenant_invite(text) from public, anon, authenticated;
grant execute on function app.accept_pending_tenant_invite(text) to authenticated;

-- ─── Fix 2: activate_property auto-creates a community zone ──────────────────
-- Rebuilds the function from v1.07 with one addition: after activating the
-- property, insert a community_zones row if the property has lat/lng and no
-- zone is already anchored to it (idempotent via ON CONFLICT DO NOTHING).

create or replace function app.activate_property(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_session_id  uuid;
  v_action_id   uuid;
  v_prop        record;
  v_zone_title  text;
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

  perform app.initialize_unit_occupancy_snapshots_for_property(p_property_id, auth.uid());
  perform app.touch_property_activity(p_property_id);
  perform app.enqueue_property_activation_notifications(p_property_id);

  -- Auto-create a 10 km community zone centred on the property if it has
  -- coordinates. Idempotent: the unique index on (property_id) prevents
  -- duplicates, so repeated calls or web-page loads are safe.
  select workspace_id, latitude, longitude, display_name, area_neighborhood, city_town
    into v_prop
  from app.properties
  where id = p_property_id;

  if v_prop.latitude is not null and v_prop.longitude is not null then
    v_zone_title := case
      when v_prop.area_neighborhood is not null and v_prop.city_town is not null
        then v_prop.area_neighborhood || ' – ' || v_prop.city_town || ' Community'
      when v_prop.area_neighborhood is not null
        then v_prop.area_neighborhood || ' Community'
      when v_prop.city_town is not null
        then v_prop.city_town || ' Community'
      else coalesce(nullif(trim(v_prop.display_name), ''), 'Unnamed') || ' Community'
    end;

    insert into app.community_zones (
      id, workspace_id, property_id,
      center_lat, center_lng, radius_km,
      title, auto_title, color,
      created_at, updated_at
    ) values (
      extensions.gen_random_uuid(),
      v_prop.workspace_id,
      p_property_id,
      v_prop.latitude,
      v_prop.longitude,
      10,
      v_zone_title,
      v_zone_title,
      '#3b82f6',
      now(),
      now()
    )
    on conflict (property_id) where property_id is not null do nothing;
  end if;

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
      jsonb_build_object('status', 'active')
    );
  end if;
end;
$$;

revoke all on function app.activate_property(uuid) from public, anon;
grant execute on function app.activate_property(uuid) to authenticated;
