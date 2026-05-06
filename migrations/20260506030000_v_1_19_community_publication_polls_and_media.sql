-- ============================================================================
-- V 1 19: Community owner publications, poll voting, and media announcements
-- ============================================================================
-- Owners publish announcements and polls into one or many communities.
-- Tenant discussions remain visible only to members of the community zone.
-- ============================================================================

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
