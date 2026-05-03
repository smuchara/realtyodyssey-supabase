-- V1.36 - realtime publication for tenant maintenance requests.
-- Mobile "My Requests" refetches the tenant RPC when request or media rows change.

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'app'
        and tablename = 'maintenance_requests'
    ) then
      alter publication supabase_realtime add table app.maintenance_requests;
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'app'
        and tablename = 'maintenance_media'
    ) then
      alter publication supabase_realtime add table app.maintenance_media;
    end if;
  end if;
end $$;
