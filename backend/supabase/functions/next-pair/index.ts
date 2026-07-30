import {
  type CompletedComparison,
  hasFullCoverage,
  isSessionComplete,
  type Photo,
  resolveTopKAndMinComparisons,
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
import {
  json,
  markSessionComplete,
  parseQuery,
  requireSession,
  serveAuthed,
  SessionIdSchema,
  SIGNED_URL_EXPIRY_SECONDS,
  WORKING_COPIES_BUCKET,
} from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = parseQuery(req, SessionIdSchema);
  if (parsed instanceof Response) return parsed;

  const { session_id } = parsed;

  // 1. Fetch session
  const session = await requireSession(supabase, session_id, 'id, stage, photo_count, top_k');
  if (session instanceof Response) return session;

  // Already marked complete (e.g. by session-status)
  if (session.stage === 'complete') {
    return json({ error: 'Session already complete' }, 422);
  }

  // 2. Fetch non-suppressed, non-dropped photos, and all comparisons (pending + completed)
  // for pair-count deduplication, concurrently - neither query depends on the other's result.
  // Pending comparisons (completed_at IS NULL) are hard-excluded from re-selection.
  const [{ data: photos, error: photosError }, { data: rawComparisons }] = await Promise.all([
    supabase
      .from('photos')
      .select(
        'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id',
      )
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .eq('upload_status', 'uploaded')
      .or('cull_decision.is.null,cull_decision.eq.keep'),
    supabase
      .from('comparisons')
      .select('photo_a_id, photo_b_id, completed_at')
      .eq('session_id', session_id),
  ]);

  if (photosError) {
    return json({ error: photosError.message }, 500);
  }

  if (!photos || photos.length < 2) {
    return json({ error: 'Not enough photos to compare' }, 422);
  }

  const typedPhotos = photos as Photo[];

  const { topK, minComparisons } = resolveTopKAndMinComparisons(session);

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
    typedPhotos,
    topK,
    minComparisons,
    totalComparisons(typedPhotos),
    session.photo_count,
  );

  if (complete) {
    await markSessionComplete(supabase, session_id);
    return json({ error: 'Session complete' }, 422);
  }

  // 5. Select Photo A and Photo B
  const inCoverage = !allHaveCoverage;
  const photoA = selectPhotoA(typedPhotos, topK, minComparisons);
  const photoB = selectPhotoB(
    typedPhotos,
    photoA,
    pairCounts,
    inCoverage,
    pendingPairs,
  );

  // 6. Generate signed URLs (single batch call instead of one round trip per photo)
  const { data: signedUrls, error: signError } = await supabase.storage
    .from(WORKING_COPIES_BUCKET)
    .createSignedUrls(
      [photoA.storage_path, photoB.storage_path],
      SIGNED_URL_EXPIRY_SECONDS,
    );

  if (
    signError || !signedUrls || signedUrls.length !== 2 ||
    signedUrls.some((s) => s.error || !s.signedUrl)
  ) {
    return json({ error: 'Failed to generate photo URLs' }, 500);
  }

  const [signedA, signedB] = signedUrls;

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
    progress: computeProgress(typedPhotos, topK),
    photo_a: { ...photoA, signed_url: signedA.signedUrl },
    photo_b: { ...photoB, signed_url: signedB.signedUrl },
  });
});
