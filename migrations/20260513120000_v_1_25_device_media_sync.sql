-- =============================================================================
-- V 1 25: Device Media Sync
-- Creates the device_media_uploads metadata table and the device-media storage
-- bucket that receives images and videos synced from tenant devices.
-- =============================================================================

-- ── 1. Metadata table ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.device_media_uploads (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  file_name       TEXT        NOT NULL,
  media_type      TEXT        NOT NULL CHECK (media_type IN ('image', 'video')),
  mime_type       TEXT,
  file_size       BIGINT,
  storage_path    TEXT        NOT NULL,
  duration_ms     INTEGER,
  media_taken_at  TIMESTAMPTZ,
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── 2. RLS ────────────────────────────────────────────────────────────────────

ALTER TABLE public.device_media_uploads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "media_uploads_insert_own" ON public.device_media_uploads;
CREATE POLICY "media_uploads_insert_own"
  ON public.device_media_uploads FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "media_uploads_select_own" ON public.device_media_uploads;
CREATE POLICY "media_uploads_select_own"
  ON public.device_media_uploads FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- ── 3. Storage bucket ─────────────────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'device-media',
  'device-media',
  false,
  524288000,  -- 500 MB per file (accommodates large videos)
  ARRAY[
    'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/gif',
    'video/mp4', 'video/quicktime', 'video/x-msvideo',
    'video/x-matroska', 'video/3gpp'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- Authenticated users may upload files under their own user-id folder
DROP POLICY IF EXISTS "device_media_insert_own" ON storage.objects;
CREATE POLICY "device_media_insert_own"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'device-media'
    AND (storage.foldername(name))[1] = (auth.uid())::text
  );

-- Users may read back their own uploaded files
DROP POLICY IF EXISTS "device_media_select_own" ON storage.objects;
CREATE POLICY "device_media_select_own"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'device-media'
    AND (storage.foldername(name))[1] = (auth.uid())::text
  );

-- ── 4. Indexes ────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_device_media_user_id
  ON public.device_media_uploads (user_id);

CREATE INDEX IF NOT EXISTS idx_device_media_type
  ON public.device_media_uploads (media_type);

CREATE INDEX IF NOT EXISTS idx_device_media_uploaded_at
  ON public.device_media_uploads (uploaded_at DESC);
