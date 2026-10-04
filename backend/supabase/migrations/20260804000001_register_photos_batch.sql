-- Batch counterpart of register-photo's per-photo UPDATE. The batch-register-photos
-- edge function used to have to issue one UPDATE per photo (each setting a
-- different storage_path); this collapses them into a single statement so a whole
-- batch costs one round trip, and returns the ids that actually matched a row so
-- the caller can report a per-photo result.
--
-- Same semantics as register-photo's UPDATE: it only touches rows already inserted
-- by pre_register_photos_atomic (matched by id + session_id), never inserts one, and
-- is idempotent - re-registering an already-uploaded row rewrites the same values.
-- SECURITY INVOKER: the UPDATE runs under the caller's role, so the existing
-- "Users own photos in their sessions" RLS policy still prevents touching another
-- user's photos (those ids simply don't match and are not returned).
CREATE OR REPLACE FUNCTION public.register_photos_batch(
  p_session_id    uuid,
  p_photo_ids     uuid[],
  p_storage_paths text[]
) RETURNS TABLE (photo_id uuid) LANGUAGE plpgsql SECURITY INVOKER AS $$
BEGIN
  IF cardinality(p_photo_ids) IS DISTINCT FROM cardinality(p_storage_paths) THEN
    RAISE EXCEPTION 'p_photo_ids and p_storage_paths must have the same length'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  UPDATE public.photos AS p
  SET storage_path = v.storage_path, upload_status = 'uploaded'
  FROM unnest(p_photo_ids, p_storage_paths) AS v(id, storage_path)
  WHERE p.id = v.id
    AND p.session_id = p_session_id
  RETURNING p.id;
END;
$$;

REVOKE ALL ON FUNCTION public.register_photos_batch(uuid, uuid[], text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_photos_batch(uuid, uuid[], text[]) TO authenticated;
