-- Track which ranking stage a session is in.
-- Stage transitions are driven by next-pair (no extra write needed in submit-comparison).
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS stage TEXT NOT NULL DEFAULT 'stage1'
  CHECK (stage IN ('stage1', 'stage2', 'stage3', 'complete'));

-- Existing sessions get 'stage1' via DEFAULT. No data migration needed.

-- Update the atomic submission RPC to also decay uncertainty by 10% on each comparison.
-- Uncertainty starts at 350 and converges toward 0 as a photo is seen more.
-- Thresholds used by next-pair: top-20 avg < 100 → stage3; top-10 avg < 50 → complete.
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
  SET elo_rating       = p_winner_new_rating,
      comparison_count = comparison_count + 1,
      uncertainty      = uncertainty * 0.9
  WHERE id = p_winner_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'photo_not_found' USING HINT = 'winner photo not found';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_loser_new_rating,
      comparison_count = comparison_count + 1,
      uncertainty      = uncertainty * 0.9
  WHERE id = p_loser_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'photo_not_found' USING HINT = 'loser photo not found';
  END IF;
END;
$$;

-- Permissions unchanged — authenticated users can still call the RPC.
REVOKE ALL ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) TO authenticated;
