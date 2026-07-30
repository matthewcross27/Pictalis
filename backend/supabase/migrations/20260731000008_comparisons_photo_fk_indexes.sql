-- comparisons.photo_a_id and comparisons.photo_b_id (20260516000000_init.sql)
-- are both `REFERENCES photos(id) ON DELETE CASCADE` but, unlike
-- comparisons.winner_id (idx_comparisons_winner) or comparisons.session_id
-- (idx_comparisons_session), neither has ever had a supporting index.
--
-- Postgres does not automatically index foreign-key columns. Whenever a
-- photos row is deleted - which happens via cascade for every photo in every
-- session the hourly cleanup_expired_sessions() cron reaps (up to ~300 photos
-- per session) - enforcing these two CASCADE constraints requires finding
-- every comparisons row referencing that photo_id, which without an index is
-- a full sequential scan of the comparisons table per deleted photo row.
CREATE INDEX IF NOT EXISTS idx_comparisons_photo_a_id ON public.comparisons(photo_a_id);
CREATE INDEX IF NOT EXISTS idx_comparisons_photo_b_id ON public.comparisons(photo_b_id);
