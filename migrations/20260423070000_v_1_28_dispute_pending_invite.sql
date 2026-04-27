-- ============================================================================
-- V 1 28: Dispute Pending Invite (Tokenless Path)
-- ============================================================================
-- Purpose
--   Adds dispute_pending_tenant_invite(p_reason) so tenants who arrived via
--   the authenticated-user lookup path (no deep-link token) can raise a
--   concern against their pending invite using auth.uid() + email matching
--   instead of a plaintext token.
--
-- Mirrors dispute_tenant_invitation(p_token, p_reason) exactly, except the
-- invite is located by comparing the caller's account email to invited_email.
-- ============================================================================

create schema if not exists app;

create or replace function app.dispute_pending_tenant_invite(p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id    uuid := auth.uid();
  v_user_email text;
  v_invite     record;
  v_effective_status app.tenant_invitation_status_enum;
  v_action_id  uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A dispute reason is required';
  end if;

  select lower(trim(u.email))
    into v_user_email
  from auth.users u
  where u.id = v_user_id
  limit 1;

  if v_user_email is null or v_user_email = '' then
    raise exception 'Could not determine account email';
  end if;

  select i.*
    into v_invite
  from app.tenant_invitations i
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

  if v_effective_status = 'expired'   then raise exception 'This invitation has expired.';             end if;
  if v_effective_status = 'cancelled' then raise exception 'This invitation has been cancelled.';      end if;
  if v_effective_status = 'accepted'  then raise exception 'This invitation has already been accepted.'; end if;

  update app.tenant_invitations
     set linked_user_id     = v_user_id,
         status             = 'signup_started'::app.tenant_invitation_status_enum,
         signup_started_at  = coalesce(signup_started_at, now()),
         updated_at         = now()
   where id = v_invite.id;

  update app.lease_agreements
     set tenant_user_id         = v_user_id,
         confirmation_status    = 'disputed'::app.lease_confirmation_status_enum,
         tenant_disputed_at     = now(),
         tenant_response_notes  = trim(p_reason),
         status                 = 'disputed'::app.lease_agreement_status_enum,
         updated_at             = now()
   where id = v_invite.lease_agreement_id;

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
        'confirmation_status',  'disputed',
        'reason',               trim(p_reason),
        'dispute_method',       'authenticated_user_lookup'
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id',   v_invite.lease_agreement_id,
    'status',               'disputed'
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on function app.dispute_pending_tenant_invite(text)
  from public, anon, authenticated;

grant execute on function app.dispute_pending_tenant_invite(text)
  to authenticated;
