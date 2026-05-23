-- ============================================================================
-- V1.27 PATCH: Fix access_event_type_enum cast + resend invite email fields
-- ============================================================================
-- 1. security_validate_qr_scan: text literals 'check_in'/'check_out' need an
--    explicit ::app.access_event_type_enum cast when inserted into those columns.
-- 2. resend_security_staff_invite: return email/name/role/property fields so the
--    server action can send the invite email without querying the locked table.
-- Both functions are replaced in full; no schema changes.
-- ============================================================================

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
  v_last_res    record;
  -- guest path
  v_gst_token   record;
  v_gst_invite  record;
  v_last_gst    record;
  -- result
  v_person_type  text;
  v_person_name  text;
  v_unit_label   text;
  v_property_id  uuid;
  v_unit_id      uuid;
  v_profile_id   uuid;
  v_guest_inv_id uuid;
  v_scan_result  app.security_scan_result_enum;
  v_denial_msg   text;
  v_result_data  jsonb;
  v_scan_id      uuid;
begin
  if p_token_value is null or length(trim(p_token_value)) = 0 then
    return jsonb_build_object('scan_result', 'denied', 'denial_reason', 'Token is empty');
  end if;

  -- Resolve the scanning staff member.
  select sp.id, sp.pmc_company_id, sp.full_name, sp.role, sp.status
    into v_staff
  from app.security_staff_profiles sp
  where sp.user_id = auth.uid()
    and sp.status = 'active'
  order by sp.activated_at desc
  limit 1;

  if v_staff.id is null then
    return jsonb_build_object(
      'scan_result',   'denied',
      'denial_reason', 'Your security profile is not active. Contact your administrator.'
    );
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

  -- ── Try resident token ─────────────────────────────────────────────────────
  select at2.id, at2.access_profile_id, at2.status, at2.valid_until
    into v_res_token
  from app.access_tokens at2
  where at2.token_hash = app.hash_token(trim(p_token_value))
  limit 1;

  if v_res_token.id is not null then
    if v_res_token.status <> 'active' then
      v_scan_result := 'denied';
      v_denial_msg  := 'This QR code is no longer active.';
    elsif v_res_token.valid_until < now() then
      v_scan_result := 'denied';
      v_denial_msg  := 'This QR code has expired — the resident should open their app to refresh it.';
    else
      select ap.id, ap.user_id, ap.pmc_company_id, ap.property_id, ap.unit_id,
             ap.occupant_type, ap.status,
             u.label  as unit_label,
             pr.first_name || ' ' || pr.last_name as resident_name
        into v_res_profile
      from app.access_profiles ap
      join app.units    u  on u.id  = ap.unit_id
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
        if v_location.property_id is not null and
           v_location.property_id <> v_res_profile.property_id then
          v_scan_result := 'denied';
          v_denial_msg  := 'This QR code does not belong to your assigned property.';
        else
          select ae.event_type into v_last_res
          from app.access_events ae
          where ae.access_profile_id = v_res_profile.id
          order by ae.event_at desc
          limit 1;

          if p_scan_action = 'entry' and v_last_res.event_type = 'check_in'::app.access_event_type_enum then
            v_scan_result := 'warning';
            v_denial_msg  := 'This resident is already checked in. Record an exit first before logging another entry.';
          else
            v_scan_result := 'approved';
            insert into app.access_events (
              access_profile_id, access_token_id, event_type,
              pmc_company_id, property_id, unit_id,
              scanned_by, event_at, notes
            )
            values (
              v_res_profile.id,
              v_res_token.id,
              (case when p_scan_action = 'entry' then 'check_in' else 'check_out' end)::app.access_event_type_enum,
              v_res_profile.pmc_company_id,
              v_res_profile.property_id,
              v_res_profile.unit_id,
              auth.uid(),
              now(),
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
            'person_type',   v_person_type,
            'person_name',   v_person_name,
            'unit_label',    v_unit_label,
            'property_name', coalesce(v_location.property_name, ''),
            'occupant_type', v_res_profile.occupant_type::text
          );
        end if;
      end if;
    end if;

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
      'scan_id',       v_scan_id,
      'scan_result',   v_scan_result::text,
      'scan_action',   p_scan_action::text,
      'denial_reason', v_denial_msg,
      'token_type',    'resident',
      'scanned_at',    now()
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
      join app.units          ap_u on ap_u.id = gi.unit_id
      join app.access_profiles ap2  on ap2.id  = gi.inviter_access_profile_id
      join app.profiles        pr   on pr.id   = ap2.user_id
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

          if p_scan_action = 'entry' and v_last_gst.event_type = 'check_in'::app.access_event_type_enum then
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
              v_gst_invite.id,
              v_gst_token.id,
              (case when p_scan_action = 'entry' then 'check_in' else 'check_out' end)::app.access_event_type_enum,
              v_gst_invite.pmc_company_id,
              v_gst_invite.property_id,
              v_gst_invite.unit_id,
              auth.uid(),
              now()
            );
          end if;

          v_person_type  := 'guest';
          v_person_name  := v_gst_invite.guest_name;
          v_unit_label   := v_gst_invite.unit_label;
          v_property_id  := v_gst_invite.property_id;
          v_unit_id      := v_gst_invite.unit_id;
          v_guest_inv_id := v_gst_invite.id;

          v_result_data := jsonb_build_object(
            'person_type',   'guest',
            'person_name',   v_gst_invite.guest_name,
            'inviter_name',  v_gst_invite.inviter_name,
            'unit_label',    v_unit_label,
            'property_name', coalesce(v_location.property_name, '')
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
      'scan_id',       v_scan_id,
      'scan_result',   v_scan_result::text,
      'scan_action',   p_scan_action::text,
      'denial_reason', v_denial_msg,
      'token_type',    'guest',
      'scanned_at',    now()
    ) || coalesce(v_result_data, '{}'::jsonb);
  end if;

  -- ── Token not found ────────────────────────────────────────────────────────
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
-- PATCH: resend_security_staff_invite — return fields needed for email sending
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
