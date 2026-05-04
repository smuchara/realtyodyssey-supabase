-- ─────────────────────────────────────────────────────────────────────────────
-- V1.38 — Enforce one invite per email per workspace
-- Deduplicates existing rows (keep latest), then adds unique constraint.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Remove duplicates: keep the most-recent invite per (workspace_id, email)
delete from app.vendor_invites
where id not in (
  select distinct on (workspace_id, email) id
  from app.vendor_invites
  order by workspace_id, email, invited_at desc
);

-- 2. Unique constraint
alter table app.vendor_invites
  add constraint uq_vendor_invites_workspace_email
  unique (workspace_id, email);

-- 3. Update RPC to upsert (do nothing on conflict) so callers get a clean error
--    The application layer handles the conflict and returns a friendly message.

-- 4. RPC: resend_vendor_invite — refresh invited_at and return fresh token
create or replace function app.resend_vendor_invite(p_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite app.vendor_invites;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  select * into v_invite
  from app.vendor_invites
  where id = p_invite_id;

  if not found then
    raise exception 'Invite not found' using errcode = 'P0404';
  end if;

  if not app.is_active_member(v_invite.workspace_id) then
    raise exception 'Access denied' using errcode = 'P0403';
  end if;

  -- Refresh timestamp so recipients know it is a new send
  update app.vendor_invites
  set invited_at = now()
  where id = p_invite_id;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'token',     v_invite.token,
    'email',     v_invite.email
  );
end;
$$;

grant execute on function app.resend_vendor_invite(uuid) to authenticated;
