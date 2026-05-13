-- Prevent duplicate metadata rows for the same storage path.
-- Needed so re-syncing after app resume never creates double entries.
ALTER TABLE public.device_media_uploads
  ADD CONSTRAINT device_media_uploads_storage_path_key UNIQUE (storage_path);
