-- ============================================================================
-- V 1 15: Community Hub, Discussions, and Public RPCs
-- ============================================================================
-- Purpose
--   - Model radius-based community zones, zone membership, posts, likes, comments, reactions, and media.
--   - Expose the tenant zone-resolution RPC in the public schema for Supabase client calls.
--   - Use RLS to keep write access scoped to authenticated zone members and owners.
--
-- Consolidated before first production publication. Earlier patch migrations
-- were folded into these domain files so a fresh reset replays the final
-- architecture without historical trial-and-error migration noise.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Community zones, membership, discussion feed, reactions, and media policies
-- ----------------------------------------------------------------------------

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
returns trigger
language plpgsql
set search_path = app, public
as $$
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
returns trigger
language plpgsql
set search_path = app, public
as $$
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
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1 from app.community_zone_members
    where community_zone_id = p_zone_id
    and   user_id = auth.uid()
  );
$$;

grant execute on function app.is_zone_member(uuid) to authenticated;

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

create policy "owner_delete_community_media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'community-media' and owner = auth.uid());

-- ----------------------------------------------------------------------------
-- Public community-zone resolution RPC for client access
-- ----------------------------------------------------------------------------

create or replace function public.resolve_tenant_community_zone(
  p_user_id     uuid,
  p_property_id uuid
) returns uuid
language plpgsql security definer
set search_path = public, app
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

  -- Closest zone whose radius contains this property (haversine)
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

  insert into app.community_zone_members (community_zone_id, user_id, property_id)
  values (v_zone_id, p_user_id, p_property_id)
  on conflict (community_zone_id, user_id)
  do update set property_id = excluded.property_id, joined_at = now();

  return v_zone_id;
end;
$$;

revoke all  on function public.resolve_tenant_community_zone(uuid, uuid) from public;
grant execute on function public.resolve_tenant_community_zone(uuid, uuid) to authenticated;

-- Remove the unreachable app-schema copy
drop function if exists app.resolve_tenant_community_zone(uuid, uuid);

-- ----------------------------------------------------------------------------
-- SECURITY DEFINER execute hardening
-- ----------------------------------------------------------------------------

do $$
declare
  routine record;
begin
  for routine in
    select
      n.nspname as schema_name,
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as identity_arguments
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public')
      and p.prosecdef
      and not (
        (n.nspname = 'app' and p.proname in (
          'get_tenant_invitation_by_token'
        ))
        or
        (n.nspname = 'public' and p.proname in (
          'get_collaboration_invite_public_details',
          'get_vendor_invite_by_token',
          'upsert_collaboration_invite_phone'
        ))
      )
  loop
    execute format(
      'revoke execute on function %I.%I(%s) from public, anon',
      routine.schema_name,
      routine.function_name,
      routine.identity_arguments
    );
  end loop;

  for routine in
    select
      n.nspname as schema_name,
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as identity_arguments
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public')
      and p.prosecdef
      and p.prorettype = 'trigger'::regtype
  loop
    execute format(
      'revoke execute on function %I.%I(%s) from public, anon, authenticated',
      routine.schema_name,
      routine.function_name,
      routine.identity_arguments
    );
  end loop;
end
$$;

-- ----------------------------------------------------------------------------
-- Foreign key covering indexes
-- ----------------------------------------------------------------------------

do $$
declare
  fk record;
  index_name text;
  indexed_columns text;
begin
  for fk in
    select
      ns.nspname as schema_name,
      tbl.relname as table_name,
      con.conname as constraint_name,
      array_agg(att.attname order by key_cols.ordinality) as column_names
    from pg_constraint con
    join pg_class tbl on tbl.oid = con.conrelid
    join pg_namespace ns on ns.oid = tbl.relnamespace
    join unnest(con.conkey) with ordinality as key_cols(attnum, ordinality) on true
    join pg_attribute att on att.attrelid = tbl.oid and att.attnum = key_cols.attnum
    where con.contype = 'f'
      and ns.nspname = 'app'
      and not exists (
        select 1
        from pg_index idx
        where idx.indrelid = con.conrelid
          and idx.indisvalid
          and idx.indisready
          and (
            select array_agg(indexed_key.attnum order by indexed_key.ordinality)::int2[]
            from unnest(idx.indkey::int2[]) with ordinality as indexed_key(attnum, ordinality)
            where indexed_key.ordinality <= array_length(con.conkey, 1)
          ) = con.conkey
      )
    group by ns.nspname, tbl.relname, con.conname
    order by ns.nspname, tbl.relname, con.conname
  loop
    index_name := left(
      'idx_' || fk.table_name || '_' || array_to_string(fk.column_names, '_'),
      54
    ) || '_' || substr(md5(fk.constraint_name), 1, 8);

    select string_agg(format('%I', column_name), ', ')
      into indexed_columns
    from unnest(fk.column_names) as column_name;

    execute format(
      'create index if not exists %I on %I.%I (%s)',
      index_name,
      fk.schema_name,
      fk.table_name,
      indexed_columns
    );
  end loop;
end
$$;

-- ----------------------------------------------------------------------------
-- Owner publications, poll voting, and media announcements
-- ----------------------------------------------------------------------------
-- Owners publish announcements and polls into one or many communities.
-- Tenant discussions remain visible only to members of the community zone.

create table if not exists app.community_poll_options (
  id         uuid        primary key default gen_random_uuid(),
  post_id    uuid        not null references app.community_posts(id) on delete cascade,
  label      text        not null
               constraint chk_community_poll_options_label
                 check (char_length(trim(label)) between 1 and 120),
  sort_order integer     not null default 0,
  vote_count integer     not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists idx_community_poll_options_post_order
  on app.community_poll_options (post_id, sort_order, created_at);

create table if not exists app.community_poll_votes (
  id         uuid        primary key default gen_random_uuid(),
  post_id    uuid        not null references app.community_posts(id) on delete cascade,
  option_id  uuid        not null references app.community_poll_options(id) on delete cascade,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint uq_community_poll_votes_post_user unique (post_id, user_id)
);

create index if not exists idx_community_poll_votes_post_id
  on app.community_poll_votes (post_id);

create index if not exists idx_community_poll_votes_user_id
  on app.community_poll_votes (user_id);

create or replace function app.sync_community_poll_vote_count()
returns trigger
language plpgsql
set search_path = app, public
as $$
begin
  if tg_op = 'INSERT' then
    update app.community_poll_options
    set vote_count = vote_count + 1
    where id = new.option_id;
  elsif tg_op = 'DELETE' then
    update app.community_poll_options
    set vote_count = greatest(0, vote_count - 1)
    where id = old.option_id;
  elsif tg_op = 'UPDATE' and new.option_id is distinct from old.option_id then
    update app.community_poll_options
    set vote_count = greatest(0, vote_count - 1)
    where id = old.option_id;

    update app.community_poll_options
    set vote_count = vote_count + 1
    where id = new.option_id;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_sync_community_poll_vote_count
  on app.community_poll_votes;

create trigger trg_sync_community_poll_vote_count
  after insert or update or delete on app.community_poll_votes
  for each row execute function app.sync_community_poll_vote_count();

create or replace function app.is_workspace_owner_for_zone(p_zone_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select exists (
    select 1
    from app.community_zones z
    join app.workspaces w on w.id = z.workspace_id
    where z.id = p_zone_id
      and w.owner_user_id = auth.uid()
  );
$$;

create or replace function app.create_community_announcement(
  p_zone_ids uuid[],
  p_content text,
  p_author_display_name text,
  p_image_url text default null
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
      image_url
    ) values (
      v_zone_id,
      v_user_id,
      v_author_display_name,
      'announcement',
      v_content,
      nullif(trim(coalesce(p_image_url, '')), '')
    )
    returning id into v_post_id;

    v_post_ids := array_append(v_post_ids, v_post_id);
  end loop;

  return v_post_ids;
end;
$$;

create or replace function app.create_community_poll(
  p_zone_ids uuid[],
  p_question text,
  p_options text[],
  p_author_display_name text
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
  v_question text := trim(coalesce(p_question, ''));
  v_author_display_name text := trim(coalesce(p_author_display_name, 'Property manager'));
  v_option text;
  v_order integer;
  v_clean_options text[] := '{}';
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if array_length(p_zone_ids, 1) is null then
    raise exception 'Select at least one community';
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

  foreach v_zone_id in array p_zone_ids loop
    if not app.is_workspace_owner_for_zone(v_zone_id) then
      raise exception 'You do not manage one of the selected communities';
    end if;

    insert into app.community_posts (
      community_zone_id,
      author_user_id,
      author_display_name,
      post_type,
      content
    ) values (
      v_zone_id,
      v_user_id,
      v_author_display_name,
      'poll',
      v_question
    )
    returning id into v_post_id;

    for v_order in 1..array_length(v_clean_options, 1) loop
      insert into app.community_poll_options (post_id, label, sort_order)
      values (v_post_id, v_clean_options[v_order], v_order);
    end loop;

    v_post_ids := array_append(v_post_ids, v_post_id);
  end loop;

  return v_post_ids;
end;
$$;

create or replace function app.vote_community_poll(p_option_id uuid)
returns boolean
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_post_id uuid;
  v_zone_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select p.id, p.community_zone_id
  into v_post_id, v_zone_id
  from app.community_poll_options o
  join app.community_posts p on p.id = o.post_id
  where o.id = p_option_id
    and p.post_type = 'poll'
    and p.deleted_at is null;

  if v_post_id is null then
    raise exception 'Poll option not found';
  end if;

  if not app.is_zone_member(v_zone_id) then
    raise exception 'You are not a member of this community';
  end if;

  insert into app.community_poll_votes (post_id, option_id, user_id)
  values (v_post_id, p_option_id, v_user_id)
  on conflict (post_id, user_id)
  do update set option_id = excluded.option_id, created_at = now();

  return true;
end;
$$;

alter table app.community_poll_options enable row level security;
alter table app.community_poll_votes enable row level security;

drop policy if exists "zone_members_read_poll_options"
  on app.community_poll_options;

create policy "zone_members_read_poll_options"
  on app.community_poll_options for select to authenticated
  using (
    exists (
      select 1
      from app.community_posts p
      where p.id = post_id
        and p.deleted_at is null
        and app.is_zone_member(p.community_zone_id)
    )
  );

drop policy if exists "workspace_owners_read_publication_poll_options"
  on app.community_poll_options;

create policy "workspace_owners_read_publication_poll_options"
  on app.community_poll_options for select to authenticated
  using (
    exists (
      select 1
      from app.community_posts p
      where p.id = post_id
        and p.post_type = 'poll'
        and app.is_workspace_owner_for_zone(p.community_zone_id)
    )
  );

drop policy if exists "poll_voters_read_own_vote"
  on app.community_poll_votes;

create policy "poll_voters_read_own_vote"
  on app.community_poll_votes for select to authenticated
  using (user_id = auth.uid());

grant select on app.community_poll_options to authenticated;
grant select on app.community_poll_votes to authenticated;

revoke all on function app.is_workspace_owner_for_zone(uuid) from public;
grant execute on function app.is_workspace_owner_for_zone(uuid) to authenticated;

revoke all on function app.create_community_announcement(uuid[], text, text, text) from public;
grant execute on function app.create_community_announcement(uuid[], text, text, text) to authenticated;

revoke all on function app.create_community_poll(uuid[], text, text[], text) from public;
grant execute on function app.create_community_poll(uuid[], text, text[], text) to authenticated;

revoke all on function app.vote_community_poll(uuid) from public;
grant execute on function app.vote_community_poll(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Community zone property anchor de-duplication
-- ----------------------------------------------------------------------------
-- A property should anchor at most one auto-generated radius zone. This cleans
-- up duplicates created by repeated client loads and prevents future repeats.

with ranked as (
  select
    id,
    property_id,
    first_value(id) over (
      partition by property_id
      order by created_at asc, id asc
    ) as keeper_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
),
duplicates as (
  select id as duplicate_id, keeper_id
  from ranked
  where rn > 1
)
delete from app.community_zone_members m
using duplicates d
where m.community_zone_id = d.duplicate_id
  and exists (
    select 1
    from app.community_zone_members keeper_member
    where keeper_member.community_zone_id = d.keeper_id
      and keeper_member.user_id = m.user_id
  );

with ranked as (
  select
    id,
    property_id,
    first_value(id) over (
      partition by property_id
      order by created_at asc, id asc
    ) as keeper_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
),
duplicates as (
  select id as duplicate_id, keeper_id
  from ranked
  where rn > 1
)
update app.community_zone_members m
set community_zone_id = d.keeper_id
from duplicates d
where m.community_zone_id = d.duplicate_id;

with ranked as (
  select
    id,
    property_id,
    first_value(id) over (
      partition by property_id
      order by created_at asc, id asc
    ) as keeper_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
),
duplicates as (
  select id as duplicate_id, keeper_id
  from ranked
  where rn > 1
)
update app.community_posts p
set community_zone_id = d.keeper_id
from duplicates d
where p.community_zone_id = d.duplicate_id;

with ranked as (
  select
    id,
    property_id,
    row_number() over (
      partition by property_id
      order by created_at asc, id asc
    ) as rn
  from app.community_zones
  where property_id is not null
)
delete from app.community_zones z
using ranked r
where z.id = r.id
  and r.rn > 1;

create unique index if not exists uq_community_zones_property_anchor
  on app.community_zones (property_id)
  where property_id is not null;

-- ----------------------------------------------------------------------------
-- Community publication editing RPCs
-- ----------------------------------------------------------------------------
-- Publication creators can edit announcements and polls after publishing.
-- Poll option edits intentionally reset poll votes because choices may change.

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

-- ----------------------------------------------------------------------------
-- Community announcement interaction controls
-- ----------------------------------------------------------------------------
-- Owners can publish announcements as interactive posts or heads-up-only posts.
-- The flags are enforced by RLS so older clients cannot bypass them.

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

-- ----------------------------------------------------------------------------
-- Community feed poll payload
-- ----------------------------------------------------------------------------
-- Mobile needs poll posts and their options in one reliable tenant-safe payload
-- so owner-created polls render as voteable cards instead of generic posts.

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

-- ----------------------------------------------------------------------------
-- Community count floor
-- ----------------------------------------------------------------------------
-- Repair any historical negative counters and keep public counts non-negative.

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
