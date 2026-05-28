-- ============================================================================
-- V1.32: Accept Workspace Invite RPCs
-- ============================================================================
-- Adds two RPCs to support the /accept-invite web flow:
--   get_user_invitation_public_details  — anon-callable, validates token
--   accept_user_invitation              — authenticated, creates memberships
-- ============================================================================

-- get_user_invitation_public_details -----------------------------------------
CREATE OR REPLACE FUNCTION app.get_user_invitation_public_details(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_token_hash text;
  v_row        app.user_invitations%ROWTYPE;
  v_role_key   text;
  v_role_name  text;
  v_role_color text;
  v_ws_name    text;
BEGIN
  IF p_token IS NULL OR char_length(trim(p_token)) < 10 THEN
    RAISE EXCEPTION 'Invalid invite token';
  END IF;

  v_token_hash := app.hash_token(p_token);

  SELECT * INTO v_row
  FROM app.user_invitations
  WHERE token_hash = v_token_hash
    AND deleted_at IS NULL
    AND status IN ('pending', 'sent')
    AND expires_at > now()
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Invite not found or expired';
  END IF;

  SELECT r.key, r.name, r.color
    INTO v_role_key, v_role_name, v_role_color
  FROM app.roles r
  WHERE r.id = v_row.role_id AND r.deleted_at IS NULL
  LIMIT 1;

  SELECT w.name INTO v_ws_name
  FROM app.workspaces w
  WHERE w.id = v_row.workspace_id
  LIMIT 1;

  RETURN jsonb_build_object(
    'invite_id',      v_row.id,
    'email',          v_row.email,
    'full_name',      v_row.full_name,
    'role_id',        v_row.role_id,
    'role_key',       v_role_key,
    'role_name',      v_role_name,
    'role_color',     v_role_color,
    'portal_type',    v_row.portal_type,
    'workspace_name', v_ws_name,
    'expires_at',     v_row.expires_at
  );
END;
$$;

-- accept_user_invitation -----------------------------------------------------
CREATE OR REPLACE FUNCTION app.accept_user_invitation(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_token_hash text;
  v_row        app.user_invitations%ROWTYPE;
  v_user_email text;
  v_role_key   text;
  v_scope_id   uuid;
  v_prop_id    uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_token IS NULL OR char_length(trim(p_token)) < 10 THEN
    RAISE EXCEPTION 'Invalid invite token';
  END IF;

  v_token_hash := app.hash_token(p_token);

  SELECT email INTO v_user_email
  FROM app.profiles
  WHERE id = auth.uid()
  LIMIT 1;

  IF v_user_email IS NULL THEN
    RAISE EXCEPTION 'User profile not found';
  END IF;

  SELECT * INTO v_row
  FROM app.user_invitations
  WHERE token_hash = v_token_hash
    AND deleted_at IS NULL
    AND status IN ('pending', 'sent')
    AND expires_at > now()
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Invite not found or expired';
  END IF;

  IF lower(v_user_email) <> lower(v_row.email) THEN
    RAISE EXCEPTION 'Invite email mismatch';
  END IF;

  UPDATE app.user_invitations
  SET status         = 'accepted',
      accepted_at    = now(),
      linked_user_id = auth.uid(),
      updated_at     = now()
  WHERE id = v_row.id;

  INSERT INTO app.workspace_memberships (workspace_id, user_id, role, status)
  VALUES (v_row.workspace_id, auth.uid(), 'workspace_member', 'active')
  ON CONFLICT (workspace_id, user_id) DO UPDATE
  SET status     = 'active',
      updated_at = now();

  SELECT id INTO v_scope_id
  FROM app.lookup_domain_scopes
  WHERE code = 'FULL_PROPERTY'
  LIMIT 1;

  IF v_scope_id IS NOT NULL THEN
    FOR v_prop_id IN
      SELECT id FROM app.properties
      WHERE workspace_id = v_row.workspace_id
        AND deleted_at IS NULL
    LOOP
      INSERT INTO app.property_memberships (
        property_id, user_id, role_id, domain_scope_id,
        status, starts_at, created_from_invite_id, granted_by
      )
      VALUES (
        v_prop_id, auth.uid(), v_row.role_id, v_scope_id,
        'active', now(), v_row.id, v_row.invited_by_user_id
      )
      ON CONFLICT (property_id, user_id, domain_scope_id)
        WHERE deleted_at IS NULL AND status = 'active'
      DO UPDATE SET
        role_id                = EXCLUDED.role_id,
        status                 = 'active',
        starts_at              = now(),
        created_from_invite_id = EXCLUDED.created_from_invite_id,
        granted_by             = EXCLUDED.granted_by,
        deleted_at             = NULL,
        deleted_by             = NULL,
        updated_at             = now();
    END LOOP;
  END IF;

  SELECT key INTO v_role_key
  FROM app.roles
  WHERE id = v_row.role_id AND deleted_at IS NULL
  LIMIT 1;

  RETURN jsonb_build_object(
    'role_key',    v_role_key,
    'portal_type', v_row.portal_type
  );
END;
$$;

-- Grants ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.get_user_invitation_public_details(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION app.get_user_invitation_public_details(text) TO anon, authenticated;

REVOKE ALL ON FUNCTION app.accept_user_invitation(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION app.accept_user_invitation(text) TO authenticated;
