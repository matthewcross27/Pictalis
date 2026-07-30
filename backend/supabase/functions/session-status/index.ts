import { isSessionComplete, resolveTopKAndMinComparisons } from '../_shared/ranking-logic.ts';
import { initSentry } from '../_shared/sentry.ts';
import {
  json,
  markSessionComplete,
  parseQuery,
  requireSession,
  serveAuthed,
  SessionIdSchema,
} from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = parseQuery(req, SessionIdSchema);
  if (parsed instanceof Response) return parsed;

  const { session_id } = parsed;

  const session = await requireSession(supabase, session_id, 'id, stage, photo_count, top_k');
  if (session instanceof Response) return session;

  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('comparison_count, elo_rating, uncertainty')
    .eq('session_id', session_id)
    .eq('is_suppressed', false);

  if (photosError) {
    return json({ error: 'Failed to fetch photos' }, 500);
  }

  const photoList = photos ?? [];
  const { topK, minComparisons } = resolveTopKAndMinComparisons(session);
  const totalComps = Math.round(
    photoList.reduce((s, p) => s + p.comparison_count, 0) / 2,
  );

  // Detect and persist completion
  let currentStage = session.stage as string;
  if (currentStage !== 'complete') {
    const complete = isSessionComplete(
      photoList,
      topK,
      minComparisons,
      totalComps,
      session.photo_count,
    );
    if (complete) {
      currentStage = 'complete';
      await markSessionComplete(supabase, session_id);
    }
  }

  return json({
    stage: currentStage,
    is_complete: currentStage === 'complete',
    top_photo_count: topK,
    total_comparisons: totalComps,
  });
});
