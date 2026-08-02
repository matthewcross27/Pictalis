-- RLS performance hardening.
--
-- Every edge function query runs as the authenticated user (see
-- backend/supabase/functions/_shared/http.ts supabaseFromAuth), so every
-- single request is subject to these policies - this is not a cold path.
--
-- 1. sessions.user_id had no index despite being the sole filter column in
--    every RLS policy below. photos/comparisons policies run
--    `session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid())`
--    on every row-level check, which forced a full sequential scan of
--    sessions for every RLS-gated access to photos/comparisons.
CREATE INDEX idx_sessions_user_id ON public.sessions(user_id);

-- 2. Bare `auth.uid()` in a USING/WITH CHECK clause is re-evaluated by the
--    planner once per row scanned. Wrapping it as `(select auth.uid())`
--    lets Postgres hoist it into an InitPlan and evaluate it once per
--    statement instead - a documented Postgres/Supabase RLS optimization
--    with identical semantics (auth.uid() is stable within a statement).
DROP POLICY IF EXISTS "Users own their sessions" ON public.sessions;
CREATE POLICY "Users own their sessions"
ON public.sessions FOR ALL TO authenticated
USING (user_id = (select auth.uid()))
WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users own photos in their sessions" ON public.photos;
CREATE POLICY "Users own photos in their sessions"
ON public.photos FOR ALL TO authenticated
USING (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = (select auth.uid())
  )
)
WITH CHECK (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = (select auth.uid())
  )
);

DROP POLICY IF EXISTS "Users own comparisons in their sessions" ON public.comparisons;
CREATE POLICY "Users own comparisons in their sessions"
ON public.comparisons FOR ALL TO authenticated
USING (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = (select auth.uid())
  )
)
WITH CHECK (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = (select auth.uid())
  )
);

DROP POLICY IF EXISTS "Owners can upload working copies" ON storage.objects;
DROP POLICY IF EXISTS "Owners can read working copies" ON storage.objects;
DROP POLICY IF EXISTS "Owners can delete working copies" ON storage.objects;

CREATE POLICY "Owners can upload working copies"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = (select auth.uid())::text
);

CREATE POLICY "Owners can read working copies"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = (select auth.uid())::text
);

CREATE POLICY "Owners can delete working copies"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = (select auth.uid())::text
);
