-- ============================================================================
-- V 1 17: Community Discussion Privacy Boundary
-- ============================================================================
-- Tenant discussions are private to community-zone members. Workspace owners can
-- publish and manage owner-led community posts such as announcements and polls,
-- but they must not be able to read tenant discussion/chat posts.
-- ============================================================================

drop policy if exists "workspace_owners_read_community_posts"
  on app.community_posts;

drop policy if exists "workspace_owners_insert_announcements"
  on app.community_posts;

drop policy if exists "workspace_owners_update_community_posts"
  on app.community_posts;

create policy "workspace_owners_read_publication_posts"
  on app.community_posts for select to authenticated
  using (
    post_type in ('announcement', 'poll')
    and exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  );

create policy "workspace_owners_insert_publication_posts"
  on app.community_posts for insert to authenticated
  with check (
    author_user_id = auth.uid()
    and post_type in ('announcement', 'poll')
    and exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  );

create policy "workspace_owners_update_publication_posts"
  on app.community_posts for update to authenticated
  using (
    post_type in ('announcement', 'poll')
    and exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  )
  with check (
    post_type in ('announcement', 'poll')
    and exists (
      select 1
      from app.community_zones z
      join app.workspaces w on w.id = z.workspace_id
      where z.id = community_posts.community_zone_id
        and w.owner_user_id = auth.uid()
    )
  );
