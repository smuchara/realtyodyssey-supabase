-- ============================================================================
-- V1.37 — Announcement composer fields
-- ============================================================================
-- The redesigned "Create Announcement" composer adds a dedicated title, rich
-- body, and delivery controls (urgent / pinned / notify / expiry / schedule)
-- plus a view counter. These columns are additive; existing announcements and
-- the mobile reader keep working (new columns are nullable or defaulted, and
-- `content` remains the plain-text body used by older clients).
-- ============================================================================

-- ── 1. New columns on community_posts ────────────────────────────────────────

alter table app.community_posts
  add column if not exists title        text,
  add column if not exists body_html    text,
  add column if not exists is_urgent    boolean     not null default false,
  add column if not exists is_pinned    boolean     not null default false,
  add column if not exists notify       boolean     not null default true,
  add column if not exists expires_at   timestamptz,
  add column if not exists scheduled_at timestamptz,
  add column if not exists view_count   integer     not null default 0;

-- Pinned announcements surface first; scheduled ones are time-gated in the feed.
create index if not exists idx_community_posts_zone_pinned_created
  on app.community_posts (community_zone_id, is_pinned desc, created_at desc)
  where deleted_at is null;

-- ── 2. create_community_announcement (extended) ──────────────────────────────

revoke all on function app.create_community_announcement(uuid[], text, text, text, boolean, boolean) from public;
drop function if exists app.create_community_announcement(uuid[], text, text, text, boolean, boolean);

create or replace function app.create_community_announcement(
  p_zone_ids uuid[],
  p_content text,
  p_author_display_name text,
  p_image_url text default null,
  p_allow_comments boolean default true,
  p_allow_reactions boolean default true,
  p_title text default null,
  p_body_html text default null,
  p_is_urgent boolean default false,
  p_is_pinned boolean default false,
  p_notify boolean default true,
  p_expires_at timestamptz default null,
  p_scheduled_at timestamptz default null
) returns uuid[]
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_zone_id uuid;
  v_post_ids uuid[] := '{}';
  v_post_id uuid;
  v_content text := trim(coalesce(p_content, ''));
  v_author_display_name text := trim(coalesce(p_author_display_name, 'Property manager'));
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if array_length(p_zone_ids, 1) is null then
    raise exception 'Select at least one community';
  end if;

  if char_length(v_content) < 1 then
    raise exception 'Announcement content is required';
  end if;

  foreach v_zone_id in array p_zone_ids loop
    if not app.is_workspace_owner_for_zone(v_zone_id) then
      raise exception 'You do not manage one of the selected communities';
    end if;

    insert into app.community_posts (
      community_zone_id,
      author_user_id,
      author_display_name,
      post_type,
      content,
      image_url,
      allow_comments,
      allow_reactions,
      title,
      body_html,
      is_urgent,
      is_pinned,
      notify,
      expires_at,
      scheduled_at
    ) values (
      v_zone_id,
      v_user_id,
      v_author_display_name,
      'announcement',
      v_content,
      nullif(trim(coalesce(p_image_url, '')), ''),
      coalesce(p_allow_comments, true),
      coalesce(p_allow_reactions, true),
      nullif(trim(coalesce(p_title, '')), ''),
      nullif(trim(coalesce(p_body_html, '')), ''),
      coalesce(p_is_urgent, false),
      coalesce(p_is_pinned, false),
      coalesce(p_notify, true),
      p_expires_at,
      p_scheduled_at
    )
    returning id into v_post_id;

    v_post_ids := array_append(v_post_ids, v_post_id);
  end loop;

  return v_post_ids;
end;
$$;

grant execute on function app.create_community_announcement(
  uuid[], text, text, text, boolean, boolean, text, text, boolean, boolean, boolean, timestamptz, timestamptz
) to authenticated;

-- ── 3. update_community_announcement (extended) ──────────────────────────────

revoke all on function app.update_community_announcement(uuid, text, text, boolean, boolean) from public;
drop function if exists app.update_community_announcement(uuid, text, text, boolean, boolean);

create or replace function app.update_community_announcement(
  p_post_id uuid,
  p_content text,
  p_image_url text default null,
  p_allow_comments boolean default true,
  p_allow_reactions boolean default true,
  p_title text default null,
  p_body_html text default null,
  p_is_urgent boolean default false,
  p_is_pinned boolean default false,
  p_notify boolean default true,
  p_expires_at timestamptz default null,
  p_scheduled_at timestamptz default null
) returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_post app.community_posts%rowtype;
  v_content text := trim(coalesce(p_content, ''));
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if char_length(v_content) < 1 then
    raise exception 'Announcement content is required';
  end if;

  select *
  into v_post
  from app.community_posts
  where id = p_post_id
    and post_type = 'announcement'
    and deleted_at is null;

  if v_post.id is null then
    raise exception 'Announcement not found';
  end if;

  if v_post.author_user_id <> v_user_id then
    raise exception 'Only the creator can edit this announcement';
  end if;

  if not app.is_workspace_owner_for_zone(v_post.community_zone_id) then
    raise exception 'You do not manage this community';
  end if;

  update app.community_posts
  set content = v_content,
      image_url = nullif(trim(coalesce(p_image_url, '')), ''),
      allow_comments = coalesce(p_allow_comments, true),
      allow_reactions = coalesce(p_allow_reactions, true),
      title = nullif(trim(coalesce(p_title, '')), ''),
      body_html = nullif(trim(coalesce(p_body_html, '')), ''),
      is_urgent = coalesce(p_is_urgent, false),
      is_pinned = coalesce(p_is_pinned, false),
      notify = coalesce(p_notify, true),
      expires_at = p_expires_at,
      scheduled_at = p_scheduled_at,
      updated_at = now()
  where id = p_post_id;
end;
$$;

grant execute on function app.update_community_announcement(
  uuid, text, text, boolean, boolean, text, text, boolean, boolean, boolean, timestamptz, timestamptz
) to authenticated;

-- ── 4. Mobile feed — expose new fields, gate scheduled/expired posts ─────────

drop function if exists app.get_community_feed_posts(uuid);

create or replace function app.get_community_feed_posts(p_zone_id uuid)
returns table (
  id uuid,
  community_zone_id uuid,
  author_user_id uuid,
  author_display_name text,
  post_type text,
  content text,
  image_url text,
  allow_comments boolean,
  allow_reactions boolean,
  like_count integer,
  comment_count integer,
  created_at timestamptz,
  updated_at timestamptz,
  is_liked_by_me boolean,
  poll_options jsonb,
  poll_selected_option_id uuid,
  poll_total_votes integer,
  title text,
  body_html text,
  is_urgent boolean,
  is_pinned boolean,
  view_count integer
)
language sql
stable
security definer
set search_path = app, public
as $$
  select
    p.id,
    p.community_zone_id,
    p.author_user_id,
    p.author_display_name,
    p.post_type,
    p.content,
    p.image_url,
    p.allow_comments,
    p.allow_reactions,
    p.like_count,
    p.comment_count,
    p.created_at,
    p.updated_at,
    exists (
      select 1
      from app.community_post_likes l
      where l.post_id = p.id
        and l.user_id = auth.uid()
    ) as is_liked_by_me,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'label', o.label,
          'vote_count', o.vote_count,
          'sort_order', o.sort_order
        )
        order by o.sort_order, o.created_at
      ) filter (where o.id is not null),
      '[]'::jsonb
    ) as poll_options,
    (
      select v.option_id
      from app.community_poll_votes v
      where v.post_id = p.id
        and v.user_id = auth.uid()
      limit 1
    ) as poll_selected_option_id,
    coalesce(sum(o.vote_count), 0)::integer as poll_total_votes,
    p.title,
    p.body_html,
    p.is_urgent,
    p.is_pinned,
    p.view_count
  from app.community_posts p
  left join app.community_poll_options o
    on o.post_id = p.id
   and p.post_type = 'poll'
  where p.community_zone_id = p_zone_id
    and p.deleted_at is null
    and (p.scheduled_at is null or p.scheduled_at <= now())
    and (p.expires_at is null or p.expires_at > now())
    and app.is_zone_member(p.community_zone_id)
  group by p.id
  order by p.is_pinned desc, p.created_at desc
  limit 50;
$$;

revoke all on function app.get_community_feed_posts(uuid) from public;
grant execute on function app.get_community_feed_posts(uuid) to authenticated;

-- ── 5. View counter ──────────────────────────────────────────────────────────
-- Zone members increment an announcement's view count when it renders in the
-- mobile feed. Safe for anonymous double-counts to be avoided at the caller.

create or replace function app.increment_community_post_view(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_zone_id uuid;
begin
  select community_zone_id into v_zone_id
  from app.community_posts
  where id = p_post_id and deleted_at is null;

  if v_zone_id is null then
    return;
  end if;

  if not app.is_zone_member(v_zone_id) then
    return;
  end if;

  update app.community_posts
  set view_count = view_count + 1
  where id = p_post_id;
end;
$$;

revoke all on function app.increment_community_post_view(uuid) from public;
grant execute on function app.increment_community_post_view(uuid) to authenticated;
