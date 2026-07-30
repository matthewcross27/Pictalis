import { computeMinComparisons, computeTopK, isSessionComplete } from '../_shared/ranking-logic.ts';
import { initSentry } from '../_shared/sentry.ts';
import { json, serveAuthed, SessionIdSchema } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const url = new URL(req.url);
  const parsed = SessionIdSchema.safeParse({
    session_id: url.searchParams.get('session_id'),
  });
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { session_id } = parsed.data;

  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id, stage, photo_count, top_k')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return json({ error: 'Session not found' }, 404);
  }

  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('comparison_count, elo_rating, uncertainty')
    .eq('session_id', session_id)
    .eq('is_suppressed', false);

  if (photosError) {
    return json({ error: 'Failed to fetch photos' }, 500);
  }

  const photoList = photos ?? [];
  const topK = session.top_k ?? computeTopK(session.photo_count);
  const minComparisons = computeMinComparisons(session.photo_count, topK);
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
      await supabase.from('sessions').update({ stage: 'complete' }).eq(
        'id',
        session_id,
      );
    }
  }

  return json({
    stage: currentStage,
    is_complete: currentStage === 'complete',
    top_photo_count: topK,
    total_comparisons: totalComps,
  });
});
