-- ============================================================================
-- V1.31 PATCH: Replace gen_random_bytes with gen_random_uuid token generation
-- ============================================================================
-- gen_random_bytes(32) requires pgcrypto in search_path which is not always
-- available. Two concatenated gen_random_uuid() calls produce a 64-char hex
-- token with equivalent entropy and no extension dependency.
-- ============================================================================

-- invite_workspace_user -------------------------------------------------------
CREATE OR REPLACE FUNCTION app.invite_workspace_user(
  p_email        text,
  p_full_name    text,
  p_role_id      uuid,
  p_portal_type  text    DEFAULT 'owner',
  p_expires_days integer DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
  v_invite_id    uuid;
  v_token        text;
  v_token_hash   text;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'No workspace found or insufficient permissions';
  END IF;

  IF EXISTS (
    SELECT 1 FROM app.user_invitations
    WHERE workspace_id = v_workspace_id
      AND lower(email) = lower(trim(p_email))
      AND status IN ('pending', 'sent')
      AND expires_at > now()
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A live invite already exists for this email address';
  END IF;

  -- 64-char hex token: two UUIDs stripped of dashes — no pgcrypto needed
  v_token      := replace(gen_random_uuid()::text, '-', '')
               || replace(gen_random_uuid()::text, '-', '');
  v_token_hash := app.hash_token(v_token);

  INSERT INTO app.user_invitations (
    workspace_id, invited_by_user_id, email, full_name,
    role_id, portal_type, token_hash, status, sent_at, expires_at
  ) VALUES (
    v_workspace_id, auth.uid(),
    lower(trim(p_email)), trim(p_full_name),
    p_role_id, p_portal_type,
    v_token_hash, 'sent', now(),
    now() + (p_expires_days || ' days')::interval
  )
  RETURNING id INTO v_invite_id;

  RETURN jsonb_build_object(
    'invitation_id', v_invite_id,
    'token',         v_token
  );
END;
$$;

-- resend_user_invitation ------------------------------------------------------
CREATE OR REPLACE FUNCTION app.resend_user_invitation(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
  v_token        text;
  v_token_hash   text;
  v_row          app.user_invitations%ROWTYPE;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  SELECT * INTO v_row
  FROM app.user_invitations
  WHERE id = p_invitation_id
    AND workspace_id = v_workspace_id
    AND deleted_at IS NULL;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Invitation not found';
  END IF;

  -- 64-char hex token: two UUIDs stripped of dashes — no pgcrypto needed
  v_token      := replace(gen_random_uuid()::text, '-', '')
               || replace(gen_random_uuid()::text, '-', '');
  v_token_hash := app.hash_token(v_token);

  UPDATE app.user_invitations
  SET token_hash   = v_token_hash,
      status       = 'sent',
      sent_at      = now(),
      expires_at   = now() + interval '7 days',
      resent_count = resent_count + 1,
      updated_at   = now()
  WHERE id = p_invitation_id;

  RETURN jsonb_build_object(
    'token',     v_token,
    'email',     v_row.email,
    'full_name', v_row.full_name
  );
END;
$$;
