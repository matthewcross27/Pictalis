-- Add 'cull' as a valid session stage (inserted before dedup/ranking).
ALTER TABLE public.sessions
  DROP CONSTRAINT IF EXISTS sessions_stage_check;

ALTER TABLE public.sessions
  ADD CONSTRAINT sessions_stage_check
  CHECK (stage IN ('cull', 'dedup', 'ranking', 'complete'));

-- Track per-photo cull decisions. Set on ALL photos in a cluster when the
-- representative is decided, so next-cull can filter by IS NULL efficiently.
ALTER TABLE public.photos
  ADD COLUMN IF NOT EXISTS cull_decision TEXT
  CHECK (cull_decision IN ('keep', 'drop'));
