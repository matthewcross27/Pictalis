import {
  isSessionComplete,
  type Photo,
  resolveTopKAndMinComparisons,
} from '../_shared/ranking-logic.ts';
import { totalComparisons } from '../_shared/pair-selection.ts';
import { selectRankablePhotos, splitRankedPool } from '../_shared/ranked-pool.ts';
import { initSentry } from '../_shared/sentry.ts';
import {
  CORS,
  json,
  markSessionComplete,
  parseQuery,
  requireSession,
  serveAuthed,
  serverError,
  SessionIdSchema,
  type SessionRow,
} from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_READ, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('session-status', req, RATE_LIMIT_READ)) {
    return rateLimitResponse(CORS);
  }

  const parsed = parseQuery(req, SessionIdSchema);
  if (parsed instanceof Response) return parsed;

  const { session_id } = parsed;

  // Session and photos are fetched concurrently - the photos query only
  // depends on session_id (already known from the parsed request), not on
  // any field of the session row.
  const [session, { data: photos, error: photosError }] = await Promise.all([
    requireSession<SessionRow>(supabase, session_id, 'id, stage, photo_count, top_k'),
    selectRankablePhotos(supabase, session_id, 'comparison_count, elo_rating, uncertainty'),
  ]);
  if (session instanceof Response) return session;

  if (photosError) {
    return await serverError(photosError, 'Failed to fetch photos');
  }

  const pool = splitRankedPool<Pick<Photo, 'comparison_count' | 'elo_rating' | 'uncertainty'>>(
    photos,
  );
  const photoList = pool.photos;
  const { topK, minComparisons } = resolveTopKAndMinComparisons(session, pool.expectedSize);
  const totalComps = Math.round(totalComparisons(photoList));

  // Detect and persist completion
  let currentStage = session.stage as string;
  if (currentStage !== 'complete') {
    const complete = isSessionComplete(
      photoList,
      topK,
      minComparisons,
      totalComps,
      pool.expectedSize,
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
