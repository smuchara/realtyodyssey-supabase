-- Allow authenticated users to overwrite their own files in device-media
-- (required for upsert: true to work when the same file is synced again).
DROP POLICY IF EXISTS "device_media_update_own" ON storage.objects;
CREATE POLICY "device_media_update_own"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'device-media'
    AND (storage.foldername(name))[1] = (auth.uid())::text
  );
