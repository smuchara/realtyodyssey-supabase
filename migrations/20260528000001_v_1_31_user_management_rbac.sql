-- ============================================================================
-- REBUILD 31: User Management & RBAC
-- ============================================================================
-- Purpose
--   - Extend app.roles for workspace-scoped custom roles (workspace_id,
--     created_by, color, icon columns)
--   - Seed additional system roles: SUPER_ADMIN, ANALYST, TENANT_LIAISON
--   - Seed full permission catalog (22 keys across 10 groups)
--   - Seed role → permission mappings for all system roles
--   - Create app.user_invitations for workspace-level user invites
--   - RLS policies for user_invitations and updated roles policies
--   - RPCs: get_workspace_users, invite_workspace_user,
--            resend_user_invitation, revoke_user_invitation,
--            get_roles_with_permissions, create_custom_role,
--            delete_custom_role, update_workspace_user_role,
--            remove_workspace_user
-- ============================================================================

-- 1. Extend app.roles --------------------------------------------------------

ALTER TABLE app.roles
  ADD COLUMN IF NOT EXISTS workspace_id uuid REFERENCES app.workspaces(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS created_by   uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS color        text,
  ADD COLUMN IF NOT EXISTS icon         text;

UPDATE app.roles SET color = '#6366f1' WHERE key = 'OWNER'            AND color IS NULL;
UPDATE app.roles SET color = '#f59e0b' WHERE key = 'PROPERTY_MANAGER' AND color IS NULL;
UPDATE app.roles SET color = '#14b8a6' WHERE key = 'CARETAKER'        AND color IS NULL;
UPDATE app.roles SET color = '#8b5cf6' WHERE key = 'LEGAL'            AND color IS NULL;
UPDATE app.roles SET color = '#64748b' WHERE key = 'TENANT'           AND color IS NULL;

-- 2. Seed additional system roles --------------------------------------------

INSERT INTO app.roles (key, name, description, is_system, is_active, color)
VALUES
  ('SUPER_ADMIN',    'Super Admin',    'Full access to all platform features and settings',         true, true, '#ef4444'),
  ('ANALYST',        'Analyst',        'Read-only access to analytics, finance, and property data', true, true, '#10b981'),
  ('TENANT_LIAISON', 'Tenant Liaison', 'Manages tenant relations, leases, and communications',      true, true, '#3b82f6')
ON CONFLICT (key) DO NOTHING;

-- 3. Seed permission catalog -------------------------------------------------

INSERT INTO app.permissions (key, description) VALUES
  ('properties.view',    'View properties and unit listings'),
  ('properties.manage',  'Create, edit, and archive properties and units'),
  ('tenants.view',       'View tenant profiles and tenancy history'),
  ('tenants.manage',     'Invite, edit, and manage tenants'),
  ('leases.view',        'View lease agreements'),
  ('leases.manage',      'Create, edit, and approve leases'),
  ('documents.view',     'View uploaded property documents'),
  ('documents.manage',   'Upload and manage property documents'),
  ('maintenance.view',   'View maintenance requests and tickets'),
  ('maintenance.manage', 'Create and resolve maintenance requests'),
  ('finance.view',       'View rent payments and financial summaries'),
  ('finance.manage',     'Record payments and manage financial data'),
  ('analytics.view',     'View analytics dashboards and performance reports'),
  ('community.view',     'View community hub, posts, and announcements'),
  ('community.manage',   'Post announcements and manage community zones'),
  ('users.view',         'View team members and pending invitations'),
  ('users.manage',       'Invite, remove, and reassign user roles'),
  ('roles.view',         'View role definitions and permission sets'),
  ('roles.manage',       'Create, edit, and delete custom roles'),
  ('integrations.view',  'View integration and notification settings'),
  ('integrations.manage','Configure payment and notification integrations'),
  ('system.manage',      'Access system health monitoring and global config')
ON CONFLICT (key) DO NOTHING;

-- 4. Role → permission mappings ----------------------------------------------

DO $$
DECLARE
  v_role_id uuid;
  v_perm_id uuid;
  v_keys    text[];
  v_key     text;
BEGIN

  -- SUPER_ADMIN: every permission
  SELECT id INTO v_role_id FROM app.roles WHERE key = 'SUPER_ADMIN';
  FOR v_key IN SELECT key FROM app.permissions WHERE deleted_at IS NULL LOOP
    SELECT id INTO v_perm_id FROM app.permissions WHERE key = v_key AND deleted_at IS NULL;
    INSERT INTO app.role_permissions (role_id, permission_id)
    VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
  END LOOP;

  -- PROPERTY_MANAGER
  SELECT id INTO v_role_id FROM app.roles WHERE key = 'PROPERTY_MANAGER';
  v_keys := ARRAY[
    'properties.view','properties.manage',
    'tenants.view','tenants.manage',
    'leases.view','leases.manage',
    'documents.view','documents.manage',
    'maintenance.view','maintenance.manage',
    'finance.view',
    'analytics.view',
    'community.view','community.manage',
    'users.view','roles.view'
  ];
  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT id INTO v_perm_id FROM app.permissions WHERE key = v_key AND deleted_at IS NULL;
    IF v_perm_id IS NOT NULL THEN
      INSERT INTO app.role_permissions (role_id, permission_id)
      VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- ANALYST
  SELECT id INTO v_role_id FROM app.roles WHERE key = 'ANALYST';
  v_keys := ARRAY['analytics.view','finance.view','properties.view','tenants.view','maintenance.view'];
  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT id INTO v_perm_id FROM app.permissions WHERE key = v_key AND deleted_at IS NULL;
    IF v_perm_id IS NOT NULL THEN
      INSERT INTO app.role_permissions (role_id, permission_id)
      VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- TENANT_LIAISON
  SELECT id INTO v_role_id FROM app.roles WHERE key = 'TENANT_LIAISON';
  v_keys := ARRAY[
    'tenants.view','tenants.manage',
    'leases.view','leases.manage',
    'documents.view','documents.manage',
    'community.view','community.manage',
    'maintenance.view'
  ];
  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT id INTO v_perm_id FROM app.permissions WHERE key = v_key AND deleted_at IS NULL;
    IF v_perm_id IS NOT NULL THEN
      INSERT INTO app.role_permissions (role_id, permission_id)
      VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- LEGAL
  SELECT id INTO v_role_id FROM app.roles WHERE key = 'LEGAL';
  v_keys := ARRAY['leases.view','leases.manage','documents.view','documents.manage'];
  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT id INTO v_perm_id FROM app.permissions WHERE key = v_key AND deleted_at IS NULL;
    IF v_perm_id IS NOT NULL THEN
      INSERT INTO app.role_permissions (role_id, permission_id)
      VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- CARETAKER
  SELECT id INTO v_role_id FROM app.roles WHERE key = 'CARETAKER';
  v_keys := ARRAY['maintenance.view','maintenance.manage'];
  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT id INTO v_perm_id FROM app.permissions WHERE key = v_key AND deleted_at IS NULL;
    IF v_perm_id IS NOT NULL THEN
      INSERT INTO app.role_permissions (role_id, permission_id)
      VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

END $$;

-- 5. user_invitations table --------------------------------------------------

CREATE TABLE IF NOT EXISTS app.user_invitations (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id       uuid        NOT NULL REFERENCES app.workspaces(id) ON DELETE CASCADE,
  invited_by_user_id uuid        NOT NULL REFERENCES auth.users(id),
  email              text        NOT NULL,
  full_name          text,
  role_id            uuid        REFERENCES app.roles(id),
  portal_type        text        NOT NULL DEFAULT 'owner'
                                   CHECK (portal_type IN ('owner', 'caretaker')),
  token_hash         text        NOT NULL UNIQUE,
  status             text        NOT NULL DEFAULT 'pending'
                                   CHECK (status IN ('pending','sent','accepted','expired','cancelled','revoked')),
  sent_at            timestamptz,
  accepted_at        timestamptz,
  linked_user_id     uuid        REFERENCES auth.users(id),
  expires_at         timestamptz NOT NULL DEFAULT now() + interval '7 days',
  resent_count       integer     NOT NULL DEFAULT 0,
  metadata           jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  deleted_by         uuid        REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_user_invitations_workspace
  ON app.user_invitations (workspace_id);
CREATE INDEX IF NOT EXISTS idx_user_invitations_email
  ON app.user_invitations (lower(email));
CREATE INDEX IF NOT EXISTS idx_user_invitations_status
  ON app.user_invitations (status)
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_user_invitations_updated_at ON app.user_invitations;
CREATE TRIGGER trg_user_invitations_updated_at
  BEFORE UPDATE ON app.user_invitations
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

-- 6. RLS ---------------------------------------------------------------------

-- user_invitations
ALTER TABLE app.user_invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_invitations_select_owner ON app.user_invitations;
CREATE POLICY user_invitations_select_owner
ON app.user_invitations FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    app.is_workspace_owner(workspace_id)
    OR app.is_workspace_admin(workspace_id)
  )
);

DROP POLICY IF EXISTS user_invitations_insert_owner ON app.user_invitations;
CREATE POLICY user_invitations_insert_owner
ON app.user_invitations FOR INSERT TO authenticated
WITH CHECK (
  app.is_workspace_owner(workspace_id)
  OR app.is_workspace_admin(workspace_id)
);

DROP POLICY IF EXISTS user_invitations_update_owner ON app.user_invitations;
CREATE POLICY user_invitations_update_owner
ON app.user_invitations FOR UPDATE TO authenticated
USING (
  app.is_workspace_owner(workspace_id)
  OR app.is_workspace_admin(workspace_id)
);

-- app.roles: enable RLS and replace reference-only policies with role-aware ones
ALTER TABLE app.roles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_reference_select ON app.roles;
DROP POLICY IF EXISTS roles_select_all     ON app.roles;
DROP POLICY IF EXISTS roles_insert_custom  ON app.roles;
DROP POLICY IF EXISTS roles_update_custom  ON app.roles;

CREATE POLICY roles_select_all
ON app.roles FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND is_active = true
  AND (
    workspace_id IS NULL
    OR app.is_workspace_owner(workspace_id)
    OR app.is_workspace_admin(workspace_id)
  )
);

CREATE POLICY roles_insert_custom
ON app.roles FOR INSERT TO authenticated
WITH CHECK (
  workspace_id IS NOT NULL
  AND is_system = false
  AND (
    app.is_workspace_owner(workspace_id)
    OR app.is_workspace_admin(workspace_id)
  )
);

CREATE POLICY roles_update_custom
ON app.roles FOR UPDATE TO authenticated
USING (
  workspace_id IS NOT NULL
  AND is_system = false
  AND (
    app.is_workspace_owner(workspace_id)
    OR app.is_workspace_admin(workspace_id)
  )
);

-- 7. RPCs --------------------------------------------------------------------

-- get_workspace_users --------------------------------------------------------
CREATE OR REPLACE FUNCTION app.get_workspace_users()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    SELECT wm.workspace_id INTO v_workspace_id
    FROM app.workspace_memberships wm
    WHERE wm.user_id = auth.uid()
      AND wm.role = 'workspace_admin'
      AND wm.status = 'active'
    LIMIT 1;
  END IF;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'No workspace found for current user';
  END IF;

  RETURN jsonb_build_object(
    'users', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',             wm.user_id,
          'email',          p.email,
          'first_name',     p.first_name,
          'last_name',      p.last_name,
          'workspace_role', wm.role,
          'status',         wm.status,
          'joined_at',      wm.created_at,
          'role_id',        r.id,
          'role_key',       r.key,
          'role_name',      r.name,
          'role_color',     r.color
        )
        ORDER BY wm.created_at
      )
      FROM app.workspace_memberships wm
      JOIN app.profiles p ON p.id = wm.user_id
      LEFT JOIN app.user_invitations ui
        ON lower(ui.email) = lower(p.email)
       AND ui.workspace_id = v_workspace_id
       AND ui.status = 'accepted'
      LEFT JOIN app.roles r ON r.id = ui.role_id AND r.deleted_at IS NULL
      WHERE wm.workspace_id = v_workspace_id
        AND wm.status = 'active'
        AND wm.user_id != auth.uid()
    ), '[]'::jsonb),
    'pending_invites', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',          ui.id,
          'email',       ui.email,
          'full_name',   ui.full_name,
          'role_id',     ui.role_id,
          'role_name',   r.name,
          'role_color',  r.color,
          'portal_type', ui.portal_type,
          'status',      ui.status,
          'sent_at',     ui.sent_at,
          'expires_at',  ui.expires_at
        )
        ORDER BY ui.created_at DESC
      )
      FROM app.user_invitations ui
      LEFT JOIN app.roles r ON r.id = ui.role_id AND r.deleted_at IS NULL
      WHERE ui.workspace_id = v_workspace_id
        AND ui.status IN ('pending', 'sent')
        AND ui.deleted_at IS NULL
        AND ui.expires_at > now()
    ), '[]'::jsonb)
  );
END;
$$;

-- invite_workspace_user ------------------------------------------------------
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

  v_token      := encode(gen_random_bytes(32), 'hex');
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

-- resend_user_invitation -----------------------------------------------------
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

  v_token      := encode(gen_random_bytes(32), 'hex');
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

-- revoke_user_invitation -----------------------------------------------------
CREATE OR REPLACE FUNCTION app.revoke_user_invitation(p_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE app.user_invitations
  SET status = 'revoked', updated_at = now()
  WHERE id = p_invitation_id
    AND workspace_id = v_workspace_id
    AND status IN ('pending', 'sent');
END;
$$;

-- get_roles_with_permissions -------------------------------------------------
CREATE OR REPLACE FUNCTION app.get_roles_with_permissions()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  RETURN COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',           r.id,
        'key',          r.key,
        'name',         r.name,
        'description',  r.description,
        'is_system',    r.is_system,
        'color',        r.color,
        'icon',         r.icon,
        'workspace_id', r.workspace_id,
        'permissions', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'key',         p.key,
            'description', p.description
          ) ORDER BY p.key)
          FROM app.role_permissions rp
          JOIN app.permissions p ON p.id = rp.permission_id AND p.deleted_at IS NULL
          WHERE rp.role_id = r.id AND rp.deleted_at IS NULL
        ), '[]'::jsonb),
        'user_count', (
          SELECT count(DISTINCT pm.user_id)::int
          FROM app.property_memberships pm
          WHERE pm.role_id = r.id
            AND pm.status = 'active'
            AND pm.deleted_at IS NULL
        )
      )
      ORDER BY r.is_system DESC, r.name
    )
    FROM app.roles r
    WHERE r.deleted_at IS NULL
      AND r.is_active = true
      AND (r.workspace_id IS NULL OR r.workspace_id = v_workspace_id)
  ), '[]'::jsonb);
END;
$$;

-- create_custom_role ---------------------------------------------------------
CREATE OR REPLACE FUNCTION app.create_custom_role(
  p_name            text,
  p_description     text,
  p_permission_keys text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
  v_role_id      uuid;
  v_role_key     text;
  v_perm_id      uuid;
  v_perm_key     text;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'No workspace found or insufficient permissions';
  END IF;

  v_role_key := upper(regexp_replace(trim(p_name), '[^a-zA-Z0-9]+', '_', 'g'));

  IF EXISTS (
    SELECT 1 FROM app.roles WHERE key = v_role_key AND deleted_at IS NULL
  ) THEN
    v_role_key := v_role_key || '_' || floor(random() * 9000 + 1000)::text;
  END IF;

  INSERT INTO app.roles (key, name, description, is_system, is_active, workspace_id, created_by, color)
  VALUES (
    v_role_key, trim(p_name), trim(p_description),
    false, true, v_workspace_id, auth.uid(), '#6366f1'
  )
  RETURNING id INTO v_role_id;

  FOREACH v_perm_key IN ARRAY p_permission_keys LOOP
    SELECT id INTO v_perm_id
    FROM app.permissions
    WHERE key = v_perm_key AND deleted_at IS NULL;
    IF v_perm_id IS NOT NULL THEN
      INSERT INTO app.role_permissions (role_id, permission_id)
      VALUES (v_role_id, v_perm_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('role_id', v_role_id, 'role_key', v_role_key);
END;
$$;

-- delete_custom_role ---------------------------------------------------------
CREATE OR REPLACE FUNCTION app.delete_custom_role(p_role_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE app.roles
  SET deleted_at = now(), deleted_by = auth.uid(), is_active = false
  WHERE id = p_role_id
    AND workspace_id = v_workspace_id
    AND is_system = false
    AND deleted_at IS NULL;
END;
$$;

-- update_workspace_user_role -------------------------------------------------
CREATE OR REPLACE FUNCTION app.update_workspace_user_role(
  p_user_id uuid,
  p_role_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE app.property_memberships
  SET role_id = p_role_id, updated_at = now()
  WHERE user_id = p_user_id
    AND status = 'active'
    AND deleted_at IS NULL
    AND property_id IN (
      SELECT id FROM app.properties
      WHERE workspace_id = v_workspace_id AND deleted_at IS NULL
    );
END;
$$;

-- remove_workspace_user ------------------------------------------------------
CREATE OR REPLACE FUNCTION app.remove_workspace_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  v_workspace_id uuid;
BEGIN
  SELECT w.id INTO v_workspace_id
  FROM app.workspaces w
  WHERE w.owner_user_id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NULL THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE app.workspace_memberships
  SET status = 'suspended', updated_at = now()
  WHERE user_id = p_user_id AND workspace_id = v_workspace_id;

  UPDATE app.property_memberships
  SET status    = 'revoked',
      deleted_at  = now(),
      deleted_by  = auth.uid()
  WHERE user_id = p_user_id
    AND status = 'active'
    AND deleted_at IS NULL
    AND property_id IN (
      SELECT id FROM app.properties
      WHERE workspace_id = v_workspace_id AND deleted_at IS NULL
    );
END;
$$;
