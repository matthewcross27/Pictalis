-- Allow the new 'dedup' stage value in the sessions table.
-- Existing sessions remain 'ranking' (no data migration needed).
ALTER TABLE public.sessions
  DROP CONSTRAINT IF EXISTS sessions_stage_check;

ALTER TABLE public.sessions
  ADD CONSTRAINT sessions_stage_check
  CHECK (stage IN ('dedup', 'ranking', 'complete'));
