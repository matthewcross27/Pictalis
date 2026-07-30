import {
  type CompletedComparison,
  computeMinComparisons,
  computeTopK,
  hasFullCoverage,
  isSessionComplete,
  type Photo,
} from '../_shared/ranking-logic.ts';
import {
  buildPairCounts,
  computeProgress,
  pairKey,
  selectPhotoA,
  selectPhotoB,
  totalComparisons,
} from '../_shared/pair-selection.ts';
import { initSentry } from '../_shared/sentry.ts';
import { json, requireSession, serveAuthed, SessionIdSchema, WORKING_COPIES_BUCKET } from '../_shared/http.ts';
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

  // 1. Fetch session
  const session = await requireSession(supabase, session_id, 'id, stage, photo_count, top_k');
  if (session instanceof Response) return session;

  // Already marked complete (e.g. by session-status)
  if (session.stage === 'complete') {
    return json({ error: 'Session already complete' }, 422);
  }

  // 2. Fetch non-suppressed, non-dropped photos
  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select(
      'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id',
    )
    .eq('session_id', session_id)
    .eq('is_suppressed', false)
    .eq('upload_status', 'uploaded')
    .or('cull_decision.is.null,cull_decision.eq.keep');

  if (photosError) {
    return json({ error: photosError.message }, 500);
  }

  if (!photos || photos.length < 2) {
    return json({ error: 'Not enough photos to compare' }, 422);
  }

  const topK = session.top_k ?? computeTopK(session.photo_count);
  const minComparisons = computeMinComparisons(session.photo_count, topK);

  // 3. Fetch all comparisons (pending + completed) for pair-count deduplication.
  // Pending comparisons (completed_at IS NULL) are hard-excluded from re-selection.
  const { data: rawComparisons } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id, completed_at')
    .eq('session_id', session_id);

  type RawComparison = CompletedComparison & { completed_at: string | null };
  const allComparisons = (rawComparisons ?? []) as RawComparison[];
  const pairCounts = buildPairCounts(allComparisons);
  const pendingPairs = new Set(
    allComparisons
      .filter((c) => !c.completed_at)
      .map((c) => pairKey(c.photo_a_id, c.photo_b_id)),
  );

  // 4. Check completion (safety net - session-status also writes this)
  const allHaveCoverage = hasFullCoverage(photos, minComparisons);
  const complete = isSessionComplete(
    photos as Photo[],
    topK,
    minComparisons,
    totalComparisons(photos as Photo[]),
    session.photo_count,
  );

  if (complete) {
    await supabase.from('sessions').update({ stage: 'complete' }).eq(
      'id',
      session_id,
    );
    return json({ error: 'Session complete' }, 422);
  }

  // 5. Select Photo A and Photo B
  const inCoverage = !allHaveCoverage;
  const photoA = selectPhotoA(photos as Photo[], topK, minComparisons);
  const photoB = selectPhotoB(
    photos as Photo[],
    photoA,
    pairCounts,
    inCoverage,
    pendingPairs,
  );

  // 6. Generate signed URLs (1-hour expiry)
  const [signedA, signedB] = await Promise.all([
    supabase.storage.from(WORKING_COPIES_BUCKET).createSignedUrl(
      photoA.storage_path,
      3600,
    ),
    supabase.storage.from(WORKING_COPIES_BUCKET).createSignedUrl(
      photoB.storage_path,
      3600,
    ),
  ]);

  if (!signedA.data?.signedUrl || !signedB.data?.signedUrl) {
    return json({ error: 'Failed to generate photo URLs' }, 500);
  }

  // 7. Insert pending comparison record
  const { data: comparison, error: compError } = await supabase
    .from('comparisons')
    .insert({ session_id, photo_a_id: photoA.id, photo_b_id: photoB.id })
    .select('id')
    .single();

  if (compError || !comparison) {
    return json({ error: 'Failed to create comparison' }, 500);
  }

  return json({
    comparison_id: comparison.id,
    stage: session.stage,
    progress: computeProgress(photos as Photo[], topK),
    photo_a: { ...photoA, signed_url: signedA.data.signedUrl },
    photo_b: { ...photoB, signed_url: signedB.data.signedUrl },
  });
});
