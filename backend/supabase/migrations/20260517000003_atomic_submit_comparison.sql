-- Atomically mark a comparison complete and update both photo Elo ratings.
-- Raises 'already_submitted' (P0001) if the comparison was already completed,
-- eliminating the TOCTOU race in the Edge Function.
CREATE OR REPLACE FUNCTION public.submit_comparison_atomic(
  p_comparison_id   uuid,
  p_winner_id       uuid,
  p_loser_id        uuid,
  p_winner_new_rating float8,
  p_loser_new_rating  float8
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_affected int;
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
    RAISE EXCEPTION 'already_submitted'
      USING HINT = 'comparison already completed';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_winner_new_rating,
      comparison_count = comparison_count + 1
  WHERE id = p_winner_id;

  UPDATE public.photos
  SET elo_rating       = p_loser_new_rating,
      comparison_count = comparison_count + 1
  WHERE id = p_loser_id;
END;
$$;

-- Allow authenticated users (Edge Function callers) to invoke the RPC.
-- SECURITY INVOKER (default) keeps RLS active for all internal UPDATEs.
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic TO authenticated;
