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
)
ON CONFLICT (id) DO NOTHING;

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

-- Cleanup function: removes objects + sessions past 72-hour retention window.
-- No SECURITY DEFINER needed: pg_cron runs as postgres which bypasses RLS.
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void LANGUAGE plpgsql
SET search_path = public, storage, extensions
AS $$
BEGIN
  -- Delete storage objects whose session has expired (keeps DB and storage in sync)
  DELETE FROM storage.objects so
  WHERE so.bucket_id = 'working-copies'
    AND EXISTS (
      SELECT 1 FROM public.photos p
      JOIN public.sessions s ON s.id = p.session_id
      WHERE p.storage_path = so.name
        AND s.expires_at < NOW()
    );

  -- Cascades to photos and comparisons via ON DELETE CASCADE
  DELETE FROM public.sessions WHERE expires_at < NOW();
END;
$$;

-- Prevent any role other than postgres from calling this function directly
REVOKE ALL ON FUNCTION public.cleanup_expired_sessions() FROM PUBLIC;

-- Remove any existing schedule by this name, then re-create (idempotent on re-run)
DO $$
BEGIN
  PERFORM cron.unschedule('cleanup-expired-sessions');
EXCEPTION WHEN others THEN NULL;
END;
$$;

SELECT cron.schedule(
  'cleanup-expired-sessions',
  '0 * * * *',
  'SELECT public.cleanup_expired_sessions()'
);
