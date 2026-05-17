-- Enable pg_cron for scheduled cleanup
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- Create the private working-copies bucket (10 MB per file, image types only)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'working-copies',
  'working-copies',
  false,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
);

-- Storage policy: authenticated users upload into a folder named after their UID
CREATE POLICY "Owners can upload working copies"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'working-copies'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Storage policy: authenticated users read their own objects
CREATE POLICY "Owners can read working copies"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'working-copies'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Storage policy: authenticated users delete their own objects
CREATE POLICY "Owners can delete working copies"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'working-copies'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Cleanup function: removes objects + sessions past 72-hour retention window
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM storage.objects
  WHERE bucket_id = 'working-copies'
    AND created_at < NOW() - INTERVAL '72 hours';

  -- Cascades to photos and comparisons via ON DELETE CASCADE
  DELETE FROM public.sessions WHERE expires_at < NOW();
END;
$$;

-- Run cleanup every hour at minute 0
SELECT cron.schedule(
  'cleanup-expired-sessions',
  '0 * * * *',
  'SELECT public.cleanup_expired_sessions()'
);
