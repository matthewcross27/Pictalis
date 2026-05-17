-- Atomically mark a comparison complete and update both photo Elo ratings.
-- Raises SQLSTATE UE001 if the comparison was already completed,
-- eliminating the TOCTOU race in the Edge Function.
CREATE OR REPLACE FUNCTION public.submit_comparison_atomic(
  p_comparison_id   uuid,
  p_winner_id       uuid,
  p_loser_id        uuid,
  p_winner_new_rating float8,
  p_loser_new_rating  float8
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
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
    RAISE EXCEPTION 'Comparison already submitted'
      USING ERRCODE = 'UE001', HINT = 'comparison already completed';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_winner_new_rating,
      comparison_count = comparison_count + 1
  WHERE id = p_winner_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'photo_not_found'
      USING HINT = 'winner photo not found';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_loser_new_rating,
      comparison_count = comparison_count + 1
  WHERE id = p_loser_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'photo_not_found'
      USING HINT = 'loser photo not found';
  END IF;
END;
$$;

-- Allow authenticated users (Edge Function callers) to invoke the RPC.
-- SECURITY INVOKER keeps RLS active for all internal UPDATEs.
REVOKE ALL ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) TO authenticated;
