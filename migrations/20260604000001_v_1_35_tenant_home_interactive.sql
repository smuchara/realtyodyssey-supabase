-- ============================================================================
-- V1.35: Tenant Home Interactive — Alerts + Live Data RPCs
-- ============================================================================
-- Purpose
--   - Add tenant_alerts table for persistent in-app alerts (rent, guest,
--     community, system categories) that persist until read/dismissed.
--   - Add get_tenant_home_live_data() RPC returning maintenance requests,
--     active alerts, community feed, and guest visit summary in one round-trip.
--   - Add dismiss_tenant_alert() and read_tenant_alert() RPCs.
--   - Add get_tenant_community_feed() RPC scoped to tenant's community zone.
--   - Add get_tenant_guest_summary() RPC scoped to tenant's unit.
-- ============================================================================

create schema if not exists app;

-- ── 1. tenant_alerts: generic persistent in-app alert records ─────────────────

create table if not exists app.tenant_alerts (
  id                   uuid        primary key default gen_random_uuid(),
  tenant_user_id       uuid        not null references auth.users(id) on delete cascade,
  property_id          uuid        references app.properties(id) on delete cascade,
  unit_id              uuid        references app.units(id) on delete cascade,
  category             text        not null
                         check (category in ('rent', 'maintenance', 'guest', 'community', 'system')),
  priority             text        not null default 'medium'
                         check (priority in ('low', 'medium', 'high', 'urgent')),
  title                text        not null,
  message              text        not null,
  action_label         text,
  action_type          text,
  -- action_type values: rate_maintenance | pay_rent | view_guest |
  --                     view_request | view_community | dismiss
  related_entity_type  text,
  -- related_entity_type: maintenance_request | maintenance_ticket |
  --                      guest_invitation | rent_charge | community_post
  related_entity_id    uuid,
  is_read              boolean     not null default false,
  is_dismissed         boolean     not null default false,
  expires_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

drop trigger if exists trg_tenant_alerts_updated_at on app.tenant_alerts;
create trigger trg_tenant_alerts_updated_at
  before update on app.tenant_alerts
  for each row execute function app.set_updated_at();

create index if not exists idx_tenant_alerts_tenant_active
  on app.tenant_alerts (tenant_user_id, is_dismissed, created_at desc)
  where is_dismissed = false;

create index if not exists idx_tenant_alerts_unit
  on app.tenant_alerts (unit_id, created_at desc);

alter table app.tenant_alerts enable row level security;

create policy "tenant_alerts_select"
  on app.tenant_alerts for select to authenticated
  using (tenant_user_id = auth.uid());

create policy "tenant_alerts_update"
  on app.tenant_alerts for update to authenticated
  using (tenant_user_id = auth.uid())
  with check (tenant_user_id = auth.uid());

grant select, update on app.tenant_alerts to authenticated;

-- ── 2. dismiss_tenant_alert ───────────────────────────────────────────────────

create or replace function app.dismiss_tenant_alert(p_alert_id uuid)
returns boolean
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  update app.tenant_alerts
  set is_dismissed = true,
      is_read      = true
  where id               = p_alert_id
    and tenant_user_id   = v_uid
    and is_dismissed     = false;

  return found;
end;
$$;

grant execute on function app.dismiss_tenant_alert(uuid) to authenticated;

-- ── 3. read_tenant_alert ──────────────────────────────────────────────────────

create or replace function app.read_tenant_alert(p_alert_id uuid)
returns boolean
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  update app.tenant_alerts
  set is_read = true
  where id             = p_alert_id
    and tenant_user_id = v_uid
    and is_read        = false;

  return found;
end;
$$;

grant execute on function app.read_tenant_alert(uuid) to authenticated;

-- ── 4. get_tenant_community_feed ─────────────────────────────────────────────
-- Returns community posts visible to the calling tenant (scoped to their zone).
-- Falls back to all posts in the property's workspace when no zone membership.

create or replace function app.get_tenant_community_feed(p_limit int default 10)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_uid        uuid := auth.uid();
  v_unit_id    uuid;
  v_property_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Resolve tenant's active unit
  select ut.unit_id, ut.property_id
  into v_unit_id, v_property_id
  from app.unit_tenancies ut
  where ut.tenant_user_id = v_uid
    and ut.status = 'active'
  order by ut.activated_at desc nulls last, ut.created_at desc
  limit 1;

  if v_unit_id is null then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          cp.id,
          cp.post_type,
          cp.content,
          cp.author_display_name,
          cp.image_url,
          cp.like_count,
          cp.comment_count,
          cp.created_at,
          -- Check if current user has liked the post
          exists (
            select 1 from app.community_post_likes l
            where l.post_id = cp.id and l.user_id = v_uid
          ) as viewer_has_liked
        from app.community_posts cp
        where cp.deleted_at is null
          and (
            -- Posts in a zone the tenant is a member of
            cp.community_zone_id in (
              select czm.community_zone_id
              from app.community_zone_members czm
              where czm.user_id = v_uid
            )
            or
            -- Posts in a zone linked to tenant's property
            cp.community_zone_id in (
              select cz.id
              from app.community_zones cz
              where cz.property_id = v_property_id
            )
          )
        order by cp.created_at desc
        limit p_limit
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

grant execute on function app.get_tenant_community_feed(int) to authenticated;

-- ── 5. get_tenant_guest_summary ───────────────────────────────────────────────
-- Returns a summary of guest activity for the calling tenant's unit.
-- Returns null/empty when tenant has no PMC access profile.

create or replace function app.get_tenant_guest_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_uid             uuid := auth.uid();
  v_access_profile  record;
  v_visits_month    int  := 0;
  v_active_invites  int  := 0;
  v_latest_guest    jsonb := null;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Resolve access profile (PMC occupant)
  select ap.id, ap.unit_id, ap.property_id
  into v_access_profile
  from app.access_profiles ap
  where ap.user_id = v_uid
    and ap.status  = 'active'
  order by ap.activated_at desc nulls last
  limit 1;

  if v_access_profile.id is null then
    -- No PMC access profile — return empty summary (not an error)
    return jsonb_build_object(
      'has_access_profile', false,
      'visits_this_month',  0,
      'active_invites',     0,
      'latest_guest',       null
    );
  end if;

  -- Visits this month = invitations created this calendar month
  select count(*)::int
  into v_visits_month
  from app.guest_invitations gi
  where gi.inviter_access_profile_id = v_access_profile.id
    and date_trunc('month', gi.invited_at) = date_trunc('month', now());

  -- Active (non-expired, non-revoked) invitations
  select count(*)::int
  into v_active_invites
  from app.guest_invitations gi
  where gi.inviter_access_profile_id = v_access_profile.id
    and gi.status = 'active';

  -- Most recent guest invitation
  select jsonb_build_object(
    'id',           gi.id,
    'guest_name',   gi.guest_name,
    'invited_at',   gi.invited_at,
    'status',       gi.status
  )
  into v_latest_guest
  from app.guest_invitations gi
  where gi.inviter_access_profile_id = v_access_profile.id
  order by gi.invited_at desc
  limit 1;

  return jsonb_build_object(
    'has_access_profile', true,
    'visits_this_month',  v_visits_month,
    'active_invites',     v_active_invites,
    'latest_guest',       v_latest_guest
  );
end;
$$;

grant execute on function app.get_tenant_guest_summary() to authenticated;

-- ── 6. get_tenant_home_live_data ─────────────────────────────────────────────
-- Single-call RPC that returns all dynamic homepage sections in one round-trip:
--   maintenance_requests  — latest 5 requests for this tenant
--   notifications         — active maintenance notifications (pending/opened)
--   alerts                — active tenant_alerts (not dismissed, not expired)
--   community_feed        — latest 3 community posts for tenant's zone
--   guest_summary         — monthly guest stats

create or replace function app.get_tenant_home_live_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_uid             uuid := auth.uid();
  v_maintenance     jsonb;
  v_notifications   jsonb;
  v_alerts          jsonb;
  v_community       jsonb;
  v_guest_summary   jsonb;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'P0401';
  end if;

  -- Ensure satisfaction notifications are seeded for completed tickets
  perform app.ensure_maintenance_satisfaction_notifications();

  -- Maintenance requests (latest 5)
  select coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          r.id,
          r.reference,
          r.title,
          r.description,
          c.code    as category_code,
          c.label   as category,
          a.code    as area_code,
          a.label   as area,
          r.urgency,
          r.priority,
          r.status,
          s.label   as status_label,
          r.property_id,
          r.unit_id,
          t.id      as ticket_id,
          t.status  as ticket_status,
          t.assigned_fundi_id,
          case
            when f.id is null then null
            else jsonb_build_object(
              'id',        f.id,
              'name',      f.name,
              'specialty', coalesce(nullif(trim(f.specialty), ''), 'Maintenance Fundi'),
              'phone',     f.phone,
              'rating',    f.rating
            )
          end       as fundi,
          -- Needs rating: ticket completed/verified and no feedback yet
          (
            t.status in ('completed', 'verified')
            and not exists (
              select 1 from app.maintenance_ticket_feedback fb
              where fb.ticket_id      = t.id
                and fb.tenant_user_id = v_uid
                and fb.feedback_type  = 'completion_review'
            )
          )         as needs_rating,
          -- Pending notification id for rating (if exists)
          (
            select n.id
            from app.tenant_notifications n
            where n.ticket_id      = t.id
              and n.tenant_user_id = v_uid
              and n.type           = 'maintenance_completion_review'
              and n.status         in ('pending', 'opened')
            limit 1
          )         as rating_notification_id,
          r.created_at,
          r.updated_at,
          r.resolved_at
        from app.maintenance_requests r
        join app.maintenance_categories         c on c.id = r.category_id
        join app.maintenance_areas              a on a.id = r.area_id
        join app.maintenance_request_statuses   s on s.code = r.status
        left join app.maintenance_tickets       t on t.request_id = r.id
        left join app.fundi_profiles            f on f.id = t.assigned_fundi_id
        where r.tenant_user_id = v_uid
        order by r.created_at desc
        limit 5
      ) row
    ),
    '[]'::jsonb
  ) into v_maintenance;

  -- Active maintenance notifications
  select coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          n.id,
          n.type,
          n.title,
          n.body,
          n.status,
          n.deep_link,
          n.payload,
          n.request_id,
          n.ticket_id,
          n.created_at
        from app.tenant_notifications n
        where n.tenant_user_id = v_uid
          and n.status in ('pending', 'opened')
        order by n.created_at desc
        limit 10
      ) row
    ),
    '[]'::jsonb
  ) into v_notifications;

  -- Active tenant alerts (not dismissed, not expired)
  select coalesce(
    (
      select jsonb_agg(row order by row.created_at desc)
      from (
        select
          a.id,
          a.category,
          a.priority,
          a.title,
          a.message,
          a.action_label,
          a.action_type,
          a.related_entity_type,
          a.related_entity_id,
          a.is_read,
          a.created_at
        from app.tenant_alerts a
        where a.tenant_user_id = v_uid
          and a.is_dismissed   = false
          and (a.expires_at is null or a.expires_at > now())
        order by
          case a.priority
            when 'urgent' then 0
            when 'high'   then 1
            when 'medium' then 2
            else 3
          end,
          a.created_at desc
        limit 5
      ) row
    ),
    '[]'::jsonb
  ) into v_alerts;

  -- Community feed (latest 3 posts)
  select app.get_tenant_community_feed(3) into v_community;

  -- Guest summary
  select app.get_tenant_guest_summary() into v_guest_summary;

  return jsonb_build_object(
    'maintenance_requests', v_maintenance,
    'notifications',        v_notifications,
    'alerts',               v_alerts,
    'community_feed',       v_community,
    'guest_summary',        v_guest_summary
  );
end;
$$;

grant execute on function app.get_tenant_home_live_data() to authenticated;
