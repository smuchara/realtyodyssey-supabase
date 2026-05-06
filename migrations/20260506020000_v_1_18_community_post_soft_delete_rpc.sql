-- ============================================================================
-- V 1 18: Community Post Soft Delete RPC
-- ============================================================================
-- Keep tenant/community post records in the database for audit and legal
-- reference, while removing deleted posts from all public tenant-facing feeds.
-- ============================================================================

create or replace function app.delete_my_community_post(
  p_post_id uuid
) returns boolean
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_author_user_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required'
      using errcode = '28000';
  end if;

  select author_user_id
  into v_author_user_id
  from app.community_posts
  where id = p_post_id
    and deleted_at is null
  for update;

  if v_author_user_id is null then
    return false;
  end if;

  if v_author_user_id <> auth.uid() then
    raise exception 'Only the author can delete this community post'
      using errcode = '42501';
  end if;

  update app.community_posts
  set deleted_at = now(),
      updated_at = now()
  where id = p_post_id
    and deleted_at is null;

  return found;
end;
$$;

revoke all on function app.delete_my_community_post(uuid) from public, anon;
grant execute on function app.delete_my_community_post(uuid) to authenticated;
