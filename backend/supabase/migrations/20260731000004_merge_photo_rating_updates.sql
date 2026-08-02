-- submit_comparison_atomic is the hottest write path in the app (called once
-- per pairwise comparison, up to hundreds of times per ranking session).
-- It previously issued two near-identical sequential UPDATE public.photos
-- statements (one for the winner, one for the loser) that only differed in
-- which new elo_rating to write. Merge them into a single UPDATE ... WHERE
-- id IN (...) with a CASE expression, cutting one statement per RPC call.
--
-- Behavior is unchanged: both rows still must exist or the RPC raises
-- 'photo_not_found' (edge function submit-comparison/index.ts maps either
-- winner-missing or loser-missing to the same generic 500 response, so
-- losing the separate winner/loser HINT text is not observable).
CREATE OR REPLACE FUNCTION public.submit_comparison_atomic(
  p_comparison_id     uuid,
  p_winner_id         uuid,
  p_loser_id          uuid,
  p_winner_new_rating float8,
  p_loser_new_rating  float8
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE
  v_affected int;
BEGIN
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

  UPDATE public.photos
  SET elo_rating       = CASE WHEN id = p_winner_id THEN p_winner_new_rating ELSE p_loser_new_rating END,
      comparison_count = comparison_count + 1,
      uncertainty      = uncertainty * 0.9
  WHERE id IN (p_winner_id, p_loser_id);

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected <> 2 THEN
    RAISE EXCEPTION 'photo_not_found'
      USING HINT = 'winner or loser photo not found';
  END IF;
END;
$$;

-- Permissions unchanged — authenticated users can still call the RPC.
REVOKE ALL ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) TO authenticated;
