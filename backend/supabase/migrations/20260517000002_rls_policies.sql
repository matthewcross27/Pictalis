-- Enforce NOT NULL on sessions.user_id so every session is tied to a user
ALTER TABLE public.sessions ALTER COLUMN user_id SET NOT NULL;

-- sessions: users can only see and modify their own sessions
DROP POLICY IF EXISTS "Users own their sessions" ON public.sessions;
CREATE POLICY "Users own their sessions"
ON public.sessions FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- photos: access gated through session ownership
DROP POLICY IF EXISTS "Users own photos in their sessions" ON public.photos;
CREATE POLICY "Users own photos in their sessions"
ON public.photos FOR ALL TO authenticated
USING (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
);

-- comparisons: access gated through session ownership
DROP POLICY IF EXISTS "Users own comparisons in their sessions" ON public.comparisons;
CREATE POLICY "Users own comparisons in their sessions"
ON public.comparisons FOR ALL TO authenticated
USING (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
);
