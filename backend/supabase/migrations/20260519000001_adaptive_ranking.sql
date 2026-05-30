-- Drop old constraint before changing any values
ALTER TABLE public.sessions
  DROP CONSTRAINT IF EXISTS sessions_stage_check;

-- Migrate existing in-progress sessions to the new 'ranking' value
UPDATE public.sessions
  SET stage = 'ranking'
  WHERE stage IN ('stage1', 'stage2', 'stage3');

-- Set new column default
ALTER TABLE public.sessions
  ALTER COLUMN stage SET DEFAULT 'ranking';

-- Re-add constraint with simplified allowed values (all existing rows are now 'ranking' or 'complete')
ALTER TABLE public.sessions
  ADD CONSTRAINT sessions_stage_check
  CHECK (stage IN ('ranking', 'complete'));

-- Add top_k; existing sessions default to 10 until re-created
ALTER TABLE public.sessions
  ADD COLUMN IF NOT EXISTS top_k INT NOT NULL DEFAULT 10;
