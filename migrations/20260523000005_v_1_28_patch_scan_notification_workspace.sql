-- ============================================================================
-- V1.28 PATCH: Fix enqueue_access_scan_notification missing workspace_id/unit_id
-- ============================================================================
-- tenant_notifications.workspace_id and .unit_id are NOT NULL.
-- The V1.28 function omitted both. This patch replaces the function to:
--   1. Accept p_unit_id as a required parameter.
--   2. Look up workspace_id from app.properties.
--   3. Include a p_body_override parameter for guest inviter notifications.
-- Also replaces security_validate_qr_scan to pass p_unit_id to the helper.
-- ============================================================================

create or replace function app.enqueue_access_scan_notification(
  p_resident_user_id  uuid,
  p_property_id       uuid,
  p_unit_id           uuid,
  p_scan_result       text,
  p_scan_action       text,
  p_property_name     text default null,
  p_unit_label        text default null,
  p_denial_reason     text default null,
  p_body_override     text default null
)
returns uuid
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_notification_id   uuid;
  v_notification_type text;
  v_title             text;
  v_body              text;
  v_location          text;
  v_workspace_id      uuid;
begin
  if p_resident_user_id is null or p_property_id is null or p_unit_id is null then
    return null;
  end if;

  if not exists (
    select 1 from app.tenant_push_tokens
    where tenant_user_id = p_resident_user_id and is_active = true
  ) then
    return null;
  end if;

  select workspace_id into v_workspace_id
  from app.properties
  where id = p_property_id
  limit 1;

  if v_workspace_id is null then
    return null;
  end if;

  v_location := coalesce(
    case
      when p_unit_label is not null and p_property_name is not null
        then p_unit_label || ' · ' || p_property_name
      when p_property_name is not null then p_property_name
      when p_unit_label   is not null then p_unit_label
      else 'your property'
    end,
    'your property'
  );

  if p_scan_result = 'approved' then
    v_notification_type := 'access_scan_approved';
    if p_scan_action = 'entry' then
      v_title := 'Entry recorded';
      v_body  := 'You have been checked in at ' || v_location || '.';
    else
      v_title := 'Exit recorded';
      v_body  := 'You have been checked out at ' || v_location || '.';
    end if;

  elsif p_scan_result = 'warning' then
    v_notification_type := 'access_scan_warning';
    v_title := 'Check-in attempt — was this you?';
    v_body  := 'Someone just tried to check in at ' || v_location ||
               ' using your QR code, but you are already marked as checked in. '
               'If this was not you, contact security immediately.';

  elsif p_scan_result = 'denied' then
    v_notification_type := 'access_scan_denied';
    v_title := 'Access denied';
    v_body  := coalesce(
      p_denial_reason,
      'Your QR code was not accepted at ' || v_location || '. Contact your property manager.'
    );

  else
    return null;
  end if;

  if p_body_override is not null then
    v_body := p_body_override;
  end if;

  insert into app.tenant_notifications (
    tenant_user_id,
    workspace_id,
    property_id,
    unit_id,
    type,
    event_key,
    title,
    body,
    payload,
    status
  )
  values (
    p_resident_user_id,
    v_workspace_id,
    p_property_id,
    p_unit_id,
    v_notification_type,
    'access_scan_' || p_scan_result || '_' || gen_random_uuid()::text,
    v_title,
    v_body,
    jsonb_build_object(
      'scan_result',   p_scan_result,
      'scan_action',   p_scan_action,
      'property_name', p_property_name,
      'unit_label',    p_unit_label
    ),
    'pending'
  )
  returning id into v_notification_id;

  return v_notification_id;
end;
$$;

-- ── Replace security_validate_qr_scan to pass unit_id to the notification helper

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
  v_res_token   record;
  v_res_profile record;
  v_last_res    record;
  v_gst_token   record;
  v_gst_invite  record;
  v_last_gst    record;
  v_person_type   text;
  v_person_name   text;
  v_unit_label    text;
  v_property_id   uuid;
  v_unit_id       uuid;
  v_profile_id    uuid;
  v_resident_uid  uuid;
  v_guest_inv_id  uuid;
  v_scan_result   app.security_scan_result_enum;
  v_denial_msg    text;
  v_result_data   jsonb;
  v_scan_id       uuid;
begin
  if p_token_value is null or length(trim(p_token_value)) = 0 then
    return jsonb_build_object('scan_result', 'denied', 'denial_reason', 'Token is empty');
  end if;

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

  select la.id, la.property_id, la.gate_zone_name, p.display_name as property_name
    into v_location
  from app.security_location_assignments la
  join app.properties p on p.id = la.property_id
  where la.staff_profile_id = v_staff.id
    and la.is_active = true
  order by la.assigned_at desc
  limit 1;

  -- ── Resident token ─────────────────────────────────────────────────────────
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

          if p_scan_action = 'entry' and
             v_last_res.event_type = 'check_in'::app.access_event_type_enum then
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

          v_person_type  := v_res_profile.occupant_type::text;
          v_person_name  := v_res_profile.resident_name;
          v_unit_label   := v_res_profile.unit_label;
          v_property_id  := v_res_profile.property_id;
          v_unit_id      := v_res_profile.unit_id;
          v_profile_id   := v_res_profile.id;
          v_resident_uid := v_res_profile.user_id;

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

    if v_resident_uid is not null and v_unit_id is not null then
      perform app.enqueue_access_scan_notification(
        v_resident_uid,
        coalesce(v_property_id, v_location.property_id),
        v_unit_id,
        v_scan_result::text,
        p_scan_action::text,
        v_location.property_name,
        v_unit_label,
        v_denial_msg
      );
    end if;

    return jsonb_build_object(
      'scan_id',       v_scan_id,
      'scan_result',   v_scan_result::text,
      'scan_action',   p_scan_action::text,
      'denial_reason', v_denial_msg,
      'token_type',    'resident',
      'scanned_at',    now()
    ) || coalesce(v_result_data, '{}'::jsonb);
  end if;

  -- ── Guest token ────────────────────────────────────────────────────────────
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

          if p_scan_action = 'entry' and
             v_last_gst.event_type = 'check_in'::app.access_event_type_enum then
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

    declare
      v_inviter_uid uuid;
    begin
      select ap2.user_id into v_inviter_uid
      from app.guest_invitations gi2
      join app.access_profiles   ap2 on ap2.id = gi2.inviter_access_profile_id
      where gi2.id = v_gst_invite.id
      limit 1;

      if v_inviter_uid is not null and v_unit_id is not null
         and v_scan_result in ('approved', 'warning') then
        perform app.enqueue_access_scan_notification(
          v_inviter_uid,
          coalesce(v_property_id, v_location.property_id),
          v_unit_id,
          v_scan_result::text,
          p_scan_action::text,
          v_location.property_name,
          v_unit_label,
          null,
          case when v_scan_result = 'approved'
               then 'Your guest ' || v_gst_invite.guest_name || ' has been '
                    || case when p_scan_action = 'entry' then 'checked in' else 'checked out' end
                    || ' at ' || coalesce(v_location.property_name, 'your property') || '.'
               else 'Someone tried to check in as your guest ' || v_gst_invite.guest_name
                    || ' but they were already marked as checked in.'
          end
        );
      end if;
    end;

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
