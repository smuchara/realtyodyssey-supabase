-- ============================================================================
-- V 1 22: Community announcement interaction controls
-- ============================================================================
-- Owners can publish announcements as interactive posts or heads-up-only posts.
-- The flags are enforced by RLS so older clients cannot bypass them.
-- ============================================================================

alter table app.community_posts
  add column if not exists allow_comments boolean not null default true,
  add column if not exists allow_reactions boolean not null default true;

create or replace function app.create_community_announcement(
  p_zone_ids uuid[],
  p_content text,
  p_author_display_name text,
  p_image_url text default null,
  p_allow_comments boolean default true,
  p_allow_reactions boolean default true
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
      allow_reactions
    ) values (
      v_zone_id,
      v_user_id,
      v_author_display_name,
      'announcement',
      v_content,
      nullif(trim(coalesce(p_image_url, '')), ''),
      coalesce(p_allow_comments, true),
      coalesce(p_allow_reactions, true)
    )
    returning id into v_post_id;

    v_post_ids := array_append(v_post_ids, v_post_id);
  end loop;

  return v_post_ids;
end;
$$;

create or replace function app.update_community_announcement(
  p_post_id uuid,
  p_content text,
  p_image_url text default null,
  p_allow_comments boolean default true,
  p_allow_reactions boolean default true
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
      updated_at = now()
  where id = p_post_id;
end;
$$;

drop policy if exists "authenticated_insert_own_likes"
  on app.community_post_likes;

create policy "authenticated_insert_own_likes"
  on app.community_post_likes for insert to authenticated
  with check (
    user_id = auth.uid() and
    exists (
      select 1
      from app.community_posts p
      where p.id = post_id
        and p.deleted_at is null
        and p.allow_reactions is true
        and app.is_zone_member(p.community_zone_id)
    )
  );

drop policy if exists "zone_members_insert_comments"
  on app.community_comments;

create policy "zone_members_insert_comments"
  on app.community_comments for insert to authenticated
  with check (
    author_user_id = auth.uid() and
    exists (
      select 1
      from app.community_posts p
      where p.id = post_id
        and p.deleted_at is null
        and p.allow_comments is true
        and app.is_zone_member(p.community_zone_id)
    )
  );

drop policy if exists "authenticated_manage_own_reactions"
  on app.community_comment_reactions;

create policy "authenticated_insert_own_comment_reactions"
  on app.community_comment_reactions for insert to authenticated
  with check (
    user_id = auth.uid() and
    exists (
      select 1
      from app.community_comments cc
      join app.community_posts p on p.id = cc.post_id
      where cc.id = comment_id
        and cc.deleted_at is null
        and p.deleted_at is null
        and p.allow_comments is true
        and app.is_zone_member(p.community_zone_id)
    )
  );

create policy "authenticated_delete_own_comment_reactions"
  on app.community_comment_reactions for delete to authenticated
  using (user_id = auth.uid());

revoke all on function app.create_community_announcement(uuid[], text, text, text) from public;
revoke all on function app.create_community_announcement(uuid[], text, text, text, boolean, boolean) from public;
drop function if exists app.create_community_announcement(uuid[], text, text, text);
grant execute on function app.create_community_announcement(uuid[], text, text, text, boolean, boolean) to authenticated;

revoke all on function app.update_community_announcement(uuid, text, text) from public;
revoke all on function app.update_community_announcement(uuid, text, text, boolean, boolean) from public;
drop function if exists app.update_community_announcement(uuid, text, text);
grant execute on function app.update_community_announcement(uuid, text, text, boolean, boolean) to authenticated;
