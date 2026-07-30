-- submit-comparison/index.ts (the app's hottest write path) still issued 2
-- sequential round trips per request after iteration 26's elo-in-RPC change:
-- fetch the comparison row (id, photo_a_id, photo_b_id) to validate winner_id
-- and derive loser_id, then call this RPC. Move that fetch + validation
-- inside the RPC itself so the edge function only makes ONE network round
-- trip total - cutting round trips on this path from 2 to 1.
--
-- The RPC now locks the comparison row (SELECT ... FOR UPDATE) to read its
-- photo ids and completed_at, replicating the same validation order/status
-- codes the edge function used to apply before calling the RPC:
--   - row missing (or hidden by RLS)      -> UE002 (404 upstream)
--   - already completed_at IS NOT NULL    -> UE001 (409 upstream, unchanged)
--   - p_winner_id not one of the two ids  -> UE003 (400 upstream)
-- Only after all three checks pass does it perform the claim UPDATE (setting
-- winner_id + completed_at together, required by the winner_set_when_complete
-- CHECK constraint) and the Elo update, exactly as before. The FOR UPDATE
-- lock is at least as safe as the previous plain claim-UPDATE: it serializes
-- concurrent submissions for the same comparison_id via a row lock instead of
-- relying solely on the WHERE completed_at IS NULL guard.
--
-- Signature changes (uuid,uuid,uuid -> uuid,uuid) and the return type adds a
-- loser_id column (the edge function no longer computes it itself), so the
-- old overload must be dropped explicitly; CREATE OR REPLACE cannot alter a
-- function's parameter list or RETURNS clause.
DROP FUNCTION IF EXISTS public.submit_comparison_atomic(uuid, uuid, uuid);

CREATE FUNCTION public.submit_comparison_atomic(
  p_comparison_id uuid,
  p_winner_id     uuid
) RETURNS TABLE(loser_id uuid, winner_new_rating float8, loser_new_rating float8)
LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE
  v_photo_a      uuid;
  v_photo_b      uuid;
  v_completed_at timestamptz;
  v_loser_id     uuid;
  v_found_count  int;
  v_winner_new   float8;
  v_loser_new    float8;
BEGIN
  -- Lock and read the comparison row. RLS ensures it belongs to the caller's
  -- session (same guarantee the removed standalone SELECT provided).
  SELECT photo_a_id, photo_b_id, completed_at
  INTO v_photo_a, v_photo_b, v_completed_at
  FROM public.comparisons
  WHERE id = p_comparison_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comparison not found'
      USING ERRCODE = 'UE002', HINT = 'no comparison with this id (or not owned by caller)';
  END IF;

  IF v_completed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Comparison already submitted'
      USING ERRCODE = 'UE001', HINT = 'comparison already completed';
  END IF;

  IF p_winner_id <> v_photo_a AND p_winner_id <> v_photo_b THEN
    RAISE EXCEPTION 'winner_id must be one of the two compared photos'
      USING ERRCODE = 'UE003', HINT = 'invalid winner_id for this comparison';
  END IF;

  v_loser_id := CASE WHEN p_winner_id = v_photo_a THEN v_photo_b ELSE v_photo_a END;

  UPDATE public.comparisons
  SET winner_id    = p_winner_id,
      completed_at = NOW()
  WHERE id = p_comparison_id;

  -- COUNT(*) (not GET DIAGNOSTICS) is used to detect a missing photo: the
  -- aggregate SELECT below always produces exactly one output row (even if
  -- zero input rows matched), so ROW_COUNT on it would always read 1.
  WITH updated AS (
    UPDATE public.photos AS p
    SET
      elo_rating = CASE
        WHEN p.id = p_winner_id THEN
          p.elo_rating + 32 * (
            1 - 1 / (1 + power(
              10,
              ((SELECT elo_rating FROM public.photos WHERE id = v_loser_id) - p.elo_rating) / 400.0
            ))
          )
        WHEN p.id = v_loser_id THEN
          p.elo_rating - 32 * (
            1 - 1 / (1 + power(
              10,
              ((SELECT elo_rating FROM public.photos WHERE id = p_winner_id) - p.elo_rating) / 400.0
            ))
          )
      END,
      comparison_count = p.comparison_count + 1,
      uncertainty      = p.uncertainty * 0.9
    WHERE p.id IN (p_winner_id, v_loser_id)
    RETURNING p.id, p.elo_rating
  )
  SELECT
    MAX(CASE WHEN id = p_winner_id THEN elo_rating END),
    MAX(CASE WHEN id = v_loser_id THEN elo_rating END),
    COUNT(*)
  INTO v_winner_new, v_loser_new, v_found_count
  FROM updated;

  IF v_found_count <> 2 THEN
    RAISE EXCEPTION 'photo_not_found'
      USING HINT = 'winner or loser photo not found';
  END IF;

  RETURN QUERY SELECT v_loser_id, v_winner_new, v_loser_new;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_comparison_atomic(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic(uuid, uuid) TO authenticated;
