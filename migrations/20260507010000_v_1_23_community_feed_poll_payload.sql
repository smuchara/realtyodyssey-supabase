-- ============================================================================
-- V 1 23: Community feed poll payload
-- ============================================================================
-- Mobile needs poll posts and their options in one reliable tenant-safe payload
-- so owner-created polls render as voteable cards instead of generic posts.
-- ============================================================================

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
  poll_total_votes integer
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
    coalesce(sum(o.vote_count), 0)::integer as poll_total_votes
  from app.community_posts p
  left join app.community_poll_options o
    on o.post_id = p.id
   and p.post_type = 'poll'
  where p.community_zone_id = p_zone_id
    and p.deleted_at is null
    and app.is_zone_member(p.community_zone_id)
  group by p.id
  order by p.created_at desc
  limit 50;
$$;

revoke all on function app.get_community_feed_posts(uuid) from public;
grant execute on function app.get_community_feed_posts(uuid) to authenticated;
