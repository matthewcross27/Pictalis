-- submit-comparison/index.ts previously did 3 sequential round trips per
-- request on the app's hottest write path: fetch the comparison row, fetch
-- both photos' current elo_rating to compute the Elo update in JS, then call
-- this RPC with the precomputed new ratings. Move the Elo math itself into
-- the RPC (mirroring _shared/elo.ts's calculateExpected/updateElo formula
-- exactly, K_FACTOR = 32) so the edge function only needs the comparison
-- fetch plus this one RPC call - cutting the middle "fetch photo ratings"
-- round trip entirely.
--
-- The new ratings are computed in a single UPDATE ... RETURNING CTE: each
-- row's CASE branch reads its own pre-update elo_rating via `p.elo_rating`
-- and the other row's via a correlated subquery. Both subqueries see the
-- same pre-update snapshot (standard single-statement MVCC semantics), so
-- this is equivalent to reading both ratings first and computing after,
-- without an extra round trip or a separate locking SELECT - identical
-- lock footprint to the single multi-row UPDATE this replaces.
--
-- Signature changes (uuid,uuid,uuid,float8,float8 -> uuid,uuid,uuid) and the
-- return type changes (void -> a one-row table), so the old overload must be
-- dropped explicitly; CREATE OR REPLACE cannot alter a function's parameter
-- list or RETURNS clause.
DROP FUNCTION IF EXISTS public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8);

CREATE FUNCTION public.submit_comparison_atomic(
  p_comparison_id uuid,
  p_winner_id     uuid,
  p_loser_id      uuid
) RETURNS TABLE(winner_new_rating float8, loser_new_rating float8)
LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE
  v_affected     int;
  v_found_count  int;
  v_winner_new   float8;
  v_loser_new    float8;
BEGIN
  -- Claim the comparison. RLS ensures it belongs to the caller.
  -- Only succeeds when completed_at IS NULL (not already submitted).
  UPDATE public.comparisons
  SET winner_id    = p_winner_id,
      completed_at = NOW()
  WHERE id = p_comparison_id
    AND completed_at IS NULL;

  GET DIAGNOSTICS v_affected = ROW_COUNT;

  IF v_affected = 0 THEN
    RAISE EXCEPTION 'Comparison already submitted'
      USING ERRCODE = 'UE001', HINT = 'comparison already completed';
  END IF;

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
              ((SELECT elo_rating FROM public.photos WHERE id = p_loser_id) - p.elo_rating) / 400.0
            ))
          )
        WHEN p.id = p_loser_id THEN
          p.elo_rating - 32 * (
            1 - 1 / (1 + power(
              10,
              ((SELECT elo_rating FROM public.photos WHERE id = p_winner_id) - p.elo_rating) / 400.0
            ))
          )
      END,
      comparison_count = p.comparison_count + 1,
      uncertainty      = p.uncertainty * 0.9
    WHERE p.id IN (p_winner_id, p_loser_id)
    RETURNING p.id, p.elo_rating
  )
  SELECT
    MAX(CASE WHEN id = p_winner_id THEN elo_rating END),
    MAX(CASE WHEN id = p_loser_id THEN elo_rating END),
    COUNT(*)
  INTO v_winner_new, v_loser_new, v_found_count
  FROM updated;

  IF v_found_count <> 2 THEN
    RAISE EXCEPTION 'photo_not_found'
      USING HINT = 'winner or loser photo not found';
  END IF;

  RETURN QUERY SELECT v_winner_new, v_loser_new;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid) TO authenticated;
