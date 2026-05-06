-- ============================================================================
-- V 1 21: Community publication editing RPCs
-- ============================================================================
-- Publication creators can edit announcements and polls after publishing.
-- Poll option edits intentionally reset poll votes because choices may change.
-- ============================================================================

create or replace function app.update_community_announcement(
  p_post_id uuid,
  p_content text,
  p_image_url text default null
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
      updated_at = now()
  where id = p_post_id;
end;
$$;

create or replace function app.update_community_poll(
  p_post_id uuid,
  p_question text,
  p_options text[]
) returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_post app.community_posts%rowtype;
  v_question text := trim(coalesce(p_question, ''));
  v_option text;
  v_order integer;
  v_clean_options text[] := '{}';
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if char_length(v_question) < 1 then
    raise exception 'Poll question is required';
  end if;

  if array_length(p_options, 1) is null then
    raise exception 'Add at least two poll options';
  end if;

  foreach v_option in array p_options loop
    v_option := trim(coalesce(v_option, ''));
    if char_length(v_option) > 0 then
      v_clean_options := array_append(v_clean_options, v_option);
    end if;
  end loop;

  if coalesce(array_length(v_clean_options, 1), 0) < 2 then
    raise exception 'Add at least two poll options';
  end if;

  if array_length(v_clean_options, 1) > 6 then
    raise exception 'Polls can have at most six options';
  end if;

  select *
  into v_post
  from app.community_posts
  where id = p_post_id
    and post_type = 'poll'
    and deleted_at is null;

  if v_post.id is null then
    raise exception 'Poll not found';
  end if;

  if v_post.author_user_id <> v_user_id then
    raise exception 'Only the creator can edit this poll';
  end if;

  if not app.is_workspace_owner_for_zone(v_post.community_zone_id) then
    raise exception 'You do not manage this community';
  end if;

  update app.community_posts
  set content = v_question,
      updated_at = now()
  where id = p_post_id;

  delete from app.community_poll_votes
  where post_id = p_post_id;

  delete from app.community_poll_options
  where post_id = p_post_id;

  for v_order in 1..array_length(v_clean_options, 1) loop
    insert into app.community_poll_options (post_id, label, sort_order)
    values (p_post_id, v_clean_options[v_order], v_order);
  end loop;
end;
$$;

revoke all on function app.update_community_announcement(uuid, text, text) from public;
grant execute on function app.update_community_announcement(uuid, text, text) to authenticated;

revoke all on function app.update_community_poll(uuid, text, text[]) from public;
grant execute on function app.update_community_poll(uuid, text, text[]) to authenticated;
