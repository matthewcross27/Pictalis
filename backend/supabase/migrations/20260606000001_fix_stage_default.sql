-- Fix stage column DEFAULT to match the current CHECK constraint.
-- Previous migrations changed the constraint from ('stage1','stage2','stage3','complete')
-- to ('cull','dedup','ranking','complete') but never updated the DEFAULT 'stage1',
-- causing new session inserts to fail at the DB level.
ALTER TABLE public.sessions ALTER COLUMN stage SET DEFAULT 'ranking';
