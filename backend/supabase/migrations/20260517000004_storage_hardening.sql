-- Update cleanup function to also purge orphaned pending comparisons.
-- These are created by next-pair but never submitted (abandoned sessions).
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, storage, extensions
AS $$
BEGIN
  -- Delete pending comparisons abandoned for more than 24 hours
  DELETE FROM public.comparisons
  WHERE completed_at IS NULL
    AND created_at < NOW() - INTERVAL '24 hours';

  -- Delete storage objects whose session has expired
  DELETE FROM storage.objects so
  WHERE so.bucket_id = 'working-copies'
    AND EXISTS (
      SELECT 1 FROM public.photos p
      JOIN public.sessions s ON s.id = p.session_id
      WHERE p.storage_path = so.name
        AND s.expires_at < NOW()
    );

  -- Cascades to photos (and their comparisons) via ON DELETE CASCADE.
  -- Note: orphaned comparisons in still-active sessions were already
  -- purged above; this only handles sessions expiring now.
  DELETE FROM public.sessions WHERE expires_at < NOW();
END;
$$;

-- Recreate storage policies with NULL guard on foldername.
-- Without the array_length check, root-path uploads (no '/') return NULL
-- for foldername[1], causing the UID comparison to silently fail rather
-- than explicitly reject.
DROP POLICY IF EXISTS "Owners can upload working copies" ON storage.objects;
DROP POLICY IF EXISTS "Owners can read working copies" ON storage.objects;
DROP POLICY IF EXISTS "Owners can delete working copies" ON storage.objects;

CREATE POLICY "Owners can upload working copies"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Owners can read working copies"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Owners can delete working copies"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = auth.uid()::text
);
