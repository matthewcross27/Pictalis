-- batch-submit-cull/index.ts previously issued two concurrent bulk UPDATE
-- statements (one for 'keep' decisions, one for 'drop' decisions) as two
-- separate PostgREST requests. Collapse them into a single RPC call that
-- does one UPDATE with a CASE expression, matching the same
-- merge-sequential-per-row-updates-into-one-statement pattern already
-- applied to submit_comparison_atomic.
--
-- Behavior is unchanged: cull_decision IS NULL keeps the update idempotent,
-- an empty array on either side matches zero rows via `= ANY(...)` (no need
-- for the two ternary empty-array guards the edge function used to need),
-- and the caller still can't distinguish per-photo failure from a blanket
-- SQL error - both the old and new code only ever report success:false for
-- every id in the request when the statement errors.
CREATE OR REPLACE FUNCTION public.batch_submit_cull(
  p_session_id uuid,
  p_keep_ids   uuid[],
  p_drop_ids   uuid[]
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
BEGIN
  UPDATE public.photos
  SET cull_decision = CASE WHEN id = ANY(p_keep_ids) THEN 'keep' ELSE 'drop' END,
      is_suppressed = CASE WHEN id = ANY(p_drop_ids) THEN true ELSE is_suppressed END
  WHERE session_id = p_session_id
    AND id = ANY(p_keep_ids || p_drop_ids)
    AND cull_decision IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_submit_cull(uuid, uuid[], uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.batch_submit_cull(uuid, uuid[], uuid[]) TO authenticated;
