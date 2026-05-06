-- ============================================================================
-- V 1 16: Community Hub Chat and Announcement Fixes
-- ============================================================================
-- Forward-only repair for v1.15 so existing local databases do not need a reset.
-- - Restore authenticated execution of the zone membership helper used by RLS.
-- - Allow workspace owners to publish announcement posts into their zones.
-- ============================================================================

grant execute on function app.is_zone_member(uuid) to authenticated;

create policy "workspace_owners_read_community_posts"
  on app.community_posts for select to authenticated
  using (
    exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  );

create policy "workspace_owners_insert_announcements"
  on app.community_posts for insert to authenticated
  with check (
    author_user_id = auth.uid()
    and post_type = 'announcement'
    and exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  );

create policy "workspace_owners_update_community_posts"
  on app.community_posts for update to authenticated
  using (
    exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  );
