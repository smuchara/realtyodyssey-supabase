-- ─────────────────────────────────────────────────────────────────────────────
-- V1.35 — maintenance-media Supabase Storage bucket
-- Photos uploaded by tenants and owners for maintenance requests.
-- Public bucket: URLs don't expire (suitable for property maintenance evidence).
-- ─────────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'maintenance-media',
  'maintenance-media',
  true,
  10485760,  -- 10 MB per file
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'video/mp4']
)
on conflict (id) do update
  set public             = true,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Any authenticated user can upload (RLS on maintenance_media table enforces tenancy)
create policy "maintenance_media_storage_insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'maintenance-media');

-- Public read — bucket is public so this is a formality but good for RLS completeness
create policy "maintenance_media_storage_select"
  on storage.objects for select to authenticated
  using (bucket_id = 'maintenance-media');

-- Uploader can delete their own files
create policy "maintenance_media_storage_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'maintenance-media'
    and owner = auth.uid()
  );
