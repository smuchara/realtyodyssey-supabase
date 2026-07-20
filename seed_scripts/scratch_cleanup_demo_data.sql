-- Cleanup: removes ONLY the demo data seed.sql creates (properties, units,
-- leases, payments, maintenance, access/security/community data, and every
-- fabricated staff/tenant/fundi/security/vendor account). It does NOT touch:
--   - your own account (yidad43473@fisedo.com)
--   - your workspace (kept so re-running seed.sql detects it already exists
--     and doesn't try to create a second one)
--   - app.roles / lookup tables / anything from migrations
--
-- Run this once if a previous partial seed attempt left data behind (e.g.
-- it errored partway through), then re-run seed.sql fresh.

set search_path = app, public, extensions;

-- Everything reachable from a property (units, leases, tenancies, rent
-- charges, payments, maintenance, access profiles/tokens/events, guest
-- invitations, security scan events/location assignments/staff profiles,
-- community zones/posts/comments/etc.) plus the workspace-scoped tables
-- that aren't tied to any property.
truncate
  app.properties,
  app.fundi_profiles,
  app.vendor_invites,
  app.lease_templates,
  app.user_invitations,
  app.security_staff_profiles,
  app.security_staff_invitations
cascade;

-- Remove the fabricated staff's workspace membership (your own membership
-- is untouched — it doesn't match either email pattern below).
delete from app.workspace_memberships
where user_id in (
  select id from auth.users
  where email like '%@ridgewayproperties.demo'
     or email like '%@ridgewaysecurity.demo'
);

-- Remove every fabricated auth account the seed created: staff, security
-- guards, fundis, tenants, mid-invite invitees, and the one-off vendor
-- invite contact. Cascades to their profiles/identities automatically.
delete from auth.users
where email like '%@ridgewayproperties.demo'
   or email like '%@ridgewaysecurity.demo'
   or email like '%@fundi.demo'
   or email like '%@tenant.demo'
   or email like '%@invitee.demo'
   or email = 'james.mburu@vendor.demo';
