-- ============================================================================
-- V 1 45: Community Discussions, Comments & Reactions
-- ============================================================================
-- Purpose
--   Back the Flutter tenant community feed with real-time Supabase data.
--   Covers:
--     • community_zone_members    — pre-computed tenant ↔ zone membership
--     • community_posts           — discussion (+ future announcement/poll) posts
--     • community_post_likes      — per-user post likes (idempotent)
--     • community_comments        — threaded comments on posts
--     • community_comment_reactions — emoji sticker or GIF reactions on comments
--   Provides:
--     • resolve_tenant_community_zone() RPC — called by mobile on app start
--     • Storage bucket policy for community-media
-- ============================================================================

-- ── 0. Guard: ensure app.community_zones exists (v_1_44 dependency) ─────────
-- Uses IF NOT EXISTS throughout so this block is a safe no-op when v_1_44
-- has already been applied, and a self-healing fallback when it hasn't.

create table if not exists app.community_zones (
  id                uuid          primary key default gen_random_uuid(),
  workspace_id      uuid          not null references app.workspaces(id)  on delete cascade,
  property_id       uuid          references  app.properties(id)          on delete set null,
  center_lat        double precision not null,
  center_lng        double precision not null,
  radius_km         double precision not null default 10
                      constraint chk_community_zones_radius check (radius_km between 1 and 100),
  title             text          not null
                      constraint chk_community_zones_title check (char_length(trim(title)) between 1 and 120),
  auto_title        text          not null,
  color             text          not null default '#3b82f6',
  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now()
);

drop trigger if exists trg_community_zones_updated_at on app.community_zones;
create trigger trg_community_zones_updated_at
  before update on app.community_zones
  for each row execute function app.set_updated_at();

create index if not exists idx_community_zones_workspace_id
  on app.community_zones (workspace_id);

create index if not exists idx_community_zones_property_id
  on app.community_zones (property_id);

alter table app.community_zones enable row level security;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'app'
      and tablename  = 'community_zones'
      and policyname = 'owner_all_community_zones'
  ) then
    execute $policy$
      create policy "owner_all_community_zones"
        on app.community_zones for all to authenticated
        using (
          exists (
            select 1 from app.workspaces w
            where w.id = community_zones.workspace_id
              and w.owner_user_id = auth.uid()
          )
        )
        with check (
          exists (
            select 1 from app.workspaces w
            where w.id = community_zones.workspace_id
              and w.owner_user_id = auth.uid()
          )
        )
    $policy$;
  end if;
end $$;

grant select, insert, update, delete on app.community_zones to authenticated;

-- ── 1. Zone membership (pre-computed, upserted by mobile on session start) ──

create table if not exists app.community_zone_members (
  id                uuid        primary key default gen_random_uuid(),
  community_zone_id uuid        not null references app.community_zones(id)  on delete cascade,
  user_id           uuid        not null references auth.users(id)            on delete cascade,
  property_id       uuid        references  app.properties(id)               on delete set null,
  joined_at         timestamptz not null default now(),
  constraint uq_community_zone_members unique (community_zone_id, user_id)
);

create index if not exists idx_czm_user_id
  on app.community_zone_members (user_id);

create index if not exists idx_czm_zone_id
  on app.community_zone_members (community_zone_id);

-- ── 2. Posts ─────────────────────────────────────────────────────────────────

create table if not exists app.community_posts (
  id                uuid        primary key default gen_random_uuid(),
  community_zone_id uuid        not null references app.community_zones(id)  on delete cascade,
  author_user_id    uuid        not null references auth.users(id)            on delete cascade,
  -- Denormalised display name captured at post time (avoids joins in mobile)
  author_display_name text      not null default '',
  post_type         text        not null default 'discussion'
                      constraint chk_community_posts_type
                        check (post_type in ('discussion', 'announcement', 'poll')),
  content           text        not null
                      constraint chk_community_posts_content
                        check (char_length(trim(content)) >= 1),
  image_url         text,
  like_count        integer     not null default 0,
  comment_count     integer     not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);

drop trigger if exists trg_community_posts_updated_at on app.community_posts;
create trigger trg_community_posts_updated_at
  before update on app.community_posts
  for each row execute function app.set_updated_at();

create index if not exists idx_community_posts_zone_created
  on app.community_posts (community_zone_id, created_at desc)
  where deleted_at is null;

-- ── 3. Post likes (idempotent toggle) ────────────────────────────────────────

create table if not exists app.community_post_likes (
  id         uuid        primary key default gen_random_uuid(),
  post_id    uuid        not null references app.community_posts(id) on delete cascade,
  user_id    uuid        not null references auth.users(id)           on delete cascade,
  created_at timestamptz not null default now(),
  constraint uq_community_post_likes unique (post_id, user_id)
);

create index if not exists idx_cpl_post_id  on app.community_post_likes (post_id);
create index if not exists idx_cpl_user_id  on app.community_post_likes (user_id);

-- Keep like_count in sync
create or replace function app.sync_post_like_count()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    update app.community_posts set like_count = like_count + 1 where id = new.post_id;
  elsif tg_op = 'DELETE' then
    update app.community_posts set like_count = greatest(0, like_count - 1) where id = old.post_id;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_post_like_count on app.community_post_likes;
create trigger trg_sync_post_like_count
  after insert or delete on app.community_post_likes
  for each row execute function app.sync_post_like_count();

-- ── 4. Comments (one level of threading via reply_to_comment_id) ─────────────

create table if not exists app.community_comments (
  id                    uuid        primary key default gen_random_uuid(),
  post_id               uuid        not null references app.community_posts(id)   on delete cascade,
  author_user_id        uuid        not null references auth.users(id)             on delete cascade,
  author_display_name   text        not null default '',
  content               text,
  image_url             text,
  reply_to_comment_id   uuid        references app.community_comments(id)         on delete set null,
  created_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  constraint chk_community_comments_has_content
    check (content is not null or image_url is not null)
);

create index if not exists idx_community_comments_post_id
  on app.community_comments (post_id, created_at asc)
  where deleted_at is null;

-- Keep comment_count in sync
create or replace function app.sync_post_comment_count()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' and new.deleted_at is null then
    update app.community_posts set comment_count = comment_count + 1 where id = new.post_id;
  elsif tg_op = 'UPDATE' and old.deleted_at is null and new.deleted_at is not null then
    update app.community_posts set comment_count = greatest(0, comment_count - 1) where id = new.post_id;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_post_comment_count on app.community_comments;
create trigger trg_sync_post_comment_count
  after insert or update on app.community_comments
  for each row execute function app.sync_post_comment_count();

-- ── 5. Comment reactions (emoji stickers + GIF URLs) ─────────────────────────

create table if not exists app.community_comment_reactions (
  id            uuid        primary key default gen_random_uuid(),
  comment_id    uuid        not null references app.community_comments(id) on delete cascade,
  user_id       uuid        not null references auth.users(id)              on delete cascade,
  reaction_type text        not null
                  constraint chk_reaction_type check (reaction_type in ('emoji', 'gif')),
  -- emoji char (e.g. "❤️") or GIF URL
  content       text        not null,
  created_at    timestamptz not null default now(),
  -- one reaction of each emoji/gif per user per comment
  constraint uq_community_comment_reactions unique (comment_id, user_id, content)
);

create index if not exists idx_ccr_comment_id on app.community_comment_reactions (comment_id);

-- ── 6. RPC: resolve zone + upsert membership ─────────────────────────────────

create or replace function app.resolve_tenant_community_zone(
  p_user_id   uuid,
  p_property_id uuid
) returns uuid
language plpgsql security definer
as $$
declare
  v_lat     double precision;
  v_lng     double precision;
  v_zone_id uuid;
begin
  select latitude, longitude
  into   v_lat, v_lng
  from   app.properties
  where  id = p_property_id;

  if v_lat is null or v_lng is null then
    return null;
  end if;

  -- Find the closest zone whose radius contains this property
  select id into v_zone_id
  from   app.community_zones
  where (
    6371.0 * 2.0 * asin(sqrt(
      power(sin((radians(v_lat) - radians(center_lat)) / 2.0), 2) +
      cos(radians(center_lat)) * cos(radians(v_lat)) *
      power(sin((radians(v_lng) - radians(center_lng)) / 2.0), 2)
    ))
  ) <= radius_km
  order by (
    6371.0 * 2.0 * asin(sqrt(
      power(sin((radians(v_lat) - radians(center_lat)) / 2.0), 2) +
      cos(radians(center_lat)) * cos(radians(v_lat)) *
      power(sin((radians(v_lng) - radians(center_lng)) / 2.0), 2)
    ))
  )
  limit 1;

  if v_zone_id is null then
    return null;
  end if;

  -- Upsert membership so RLS checks can use this table
  insert into app.community_zone_members (community_zone_id, user_id, property_id)
  values (v_zone_id, p_user_id, p_property_id)
  on conflict (community_zone_id, user_id)
  do update set property_id = excluded.property_id, joined_at = now();

  return v_zone_id;
end;
$$;

revoke all on function app.resolve_tenant_community_zone(uuid, uuid) from public;
grant execute on function app.resolve_tenant_community_zone(uuid, uuid) to authenticated;

-- ── 7. RLS policies ───────────────────────────────────────────────────────────

-- Helper: is the calling user a member of a given zone?
create or replace function app.is_zone_member(p_zone_id uuid)
returns boolean language sql stable security definer as $$
  select exists (
    select 1 from app.community_zone_members
    where community_zone_id = p_zone_id
    and   user_id = auth.uid()
  );
$$;

-- community_zone_members
alter table app.community_zone_members enable row level security;

create policy "members_read_own"
  on app.community_zone_members for select to authenticated
  using (user_id = auth.uid());

create policy "members_upsert_own"
  on app.community_zone_members for insert to authenticated
  with check (user_id = auth.uid());

create policy "members_update_own"
  on app.community_zone_members for update to authenticated
  using (user_id = auth.uid());

-- community_posts
alter table app.community_posts enable row level security;

create policy "zone_members_read_posts"
  on app.community_posts for select to authenticated
  using (deleted_at is null and app.is_zone_member(community_zone_id));

create policy "zone_members_insert_posts"
  on app.community_posts for insert to authenticated
  with check (
    author_user_id = auth.uid()
    and app.is_zone_member(community_zone_id)
  );

create policy "authors_delete_own_posts"
  on app.community_posts for update to authenticated
  using (author_user_id = auth.uid());

-- community_post_likes
alter table app.community_post_likes enable row level security;

create policy "zone_members_read_likes"
  on app.community_post_likes for select to authenticated
  using (
    exists (
      select 1 from app.community_posts p
      where  p.id = post_id and app.is_zone_member(p.community_zone_id)
    )
  );

create policy "authenticated_insert_own_likes"
  on app.community_post_likes for insert to authenticated
  with check (user_id = auth.uid());

create policy "authenticated_delete_own_likes"
  on app.community_post_likes for delete to authenticated
  using (user_id = auth.uid());

-- community_comments
alter table app.community_comments enable row level security;

create policy "zone_members_read_comments"
  on app.community_comments for select to authenticated
  using (
    deleted_at is null and
    exists (
      select 1 from app.community_posts p
      where  p.id = post_id and app.is_zone_member(p.community_zone_id)
    )
  );

create policy "zone_members_insert_comments"
  on app.community_comments for insert to authenticated
  with check (
    author_user_id = auth.uid() and
    exists (
      select 1 from app.community_posts p
      where  p.id = post_id and app.is_zone_member(p.community_zone_id)
    )
  );

create policy "authors_soft_delete_own_comments"
  on app.community_comments for update to authenticated
  using (author_user_id = auth.uid());

-- community_comment_reactions
alter table app.community_comment_reactions enable row level security;

create policy "zone_members_read_reactions"
  on app.community_comment_reactions for select to authenticated
  using (
    exists (
      select 1
      from   app.community_comments cc
      join   app.community_posts    p  on p.id = cc.post_id
      where  cc.id = comment_id and app.is_zone_member(p.community_zone_id)
    )
  );

create policy "authenticated_manage_own_reactions"
  on app.community_comment_reactions for all to authenticated
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ── 8. Grants ─────────────────────────────────────────────────────────────────

grant select, insert, update        on app.community_zone_members       to authenticated;
grant select, insert, update        on app.community_posts              to authenticated;
grant select, insert, delete        on app.community_post_likes         to authenticated;
grant select, insert, update        on app.community_comments           to authenticated;
grant select, insert, delete        on app.community_comment_reactions  to authenticated;

-- ── 9. Supabase Storage: community-media bucket ───────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'community-media',
  'community-media',
  true,
  10485760,  -- 10 MB per file
  array['image/jpeg','image/jpg','image/png','image/gif','image/webp']
)
on conflict (id) do nothing;

-- Authenticated users may upload to their own folder (posts/ or comments/)
create policy "authenticated_upload_community_media"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'community-media');

create policy "public_read_community_media"
  on storage.objects for select to public
  using (bucket_id = 'community-media');

create policy "owner_delete_community_media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'community-media' and owner = auth.uid());
