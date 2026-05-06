-- ============================================================================
-- V 1 24: Community count floor
-- ============================================================================
-- Repair any historical negative counters and keep public counts non-negative.
-- ============================================================================

update app.community_posts
set like_count = 0
where like_count < 0;

update app.community_posts
set comment_count = 0
where comment_count < 0;

create or replace function app.sync_post_like_count()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if tg_op = 'INSERT' then
    update app.community_posts
    set like_count = greatest(0, like_count + 1)
    where id = new.post_id;
    return new;
  elsif tg_op = 'DELETE' then
    update app.community_posts
    set like_count = greatest(0, like_count - 1)
    where id = old.post_id;
    return old;
  end if;

  return null;
end;
$$;

create or replace function app.sync_post_comment_count()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if tg_op = 'INSERT' then
    update app.community_posts
    set comment_count = greatest(0, comment_count + 1)
    where id = new.post_id;
    return new;
  elsif tg_op = 'UPDATE' then
    if old.deleted_at is null and new.deleted_at is not null then
      update app.community_posts
      set comment_count = greatest(0, comment_count - 1)
      where id = new.post_id;
    end if;
    return new;
  end if;

  return null;
end;
$$;
