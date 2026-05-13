-- Increase device-media bucket file size limit to 10 GB.
UPDATE storage.buckets
SET file_size_limit = 10737418240
WHERE id = 'device-media';
