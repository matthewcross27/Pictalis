-- idx_comparisons_winner (comparisons.winner_id) has never been read by any
-- query: winner_id is only ever written (submit-comparison's
-- submit_comparison_atomic RPC) and looked up by photos.id, not filtered or
-- joined on via comparisons.winner_id. It's pure write overhead on every
-- comparison submission (every swipe) with no query it ever serves.
DROP INDEX IF EXISTS idx_comparisons_winner;
