import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import {
  CORS,
  json,
  parseQuery,
  serveAuthed,
  serverError,
  SessionIdSchema,
  SIGNED_URL_EXPIRY_SECONDS,
  WORKING_COPIES_BUCKET,
} from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_READ, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

const QuerySchema = SessionIdSchema.extend({
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('results', req, RATE_LIMIT_READ)) {
    return rateLimitResponse(CORS);
  }

  const parsed = parseQuery(req, QuerySchema);
  if (parsed instanceof Response) return parsed;

  // Session stage (for the iOS "Complete" / "In Progress" badge) and the
  // ranked photo list are fetched concurrently - neither depends on the
  // other's result.
  const [{ data: session }, { data: photos, error }] = await Promise.all([
    supabase
      .from('sessions')
      .select('stage')
      .eq('id', parsed.session_id)
      .single(),
    supabase
      .from('photos')
      .select(
        'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, is_suppressed, cluster_id, quality_flags',
      )
      .eq('session_id', parsed.session_id)
      .eq('is_suppressed', false)
      .eq('upload_status', 'uploaded')
      .order('elo_rating', { ascending: false })
      .limit(parsed.limit),
  ]);

  if (error) {
    return await serverError(error, 'Failed to fetch photos');
  }

  const photoList = photos ?? [];
  let photosWithUrls: (typeof photoList[number] & { signed_url: string | null })[];
  if (photoList.length === 0) {
    photosWithUrls = [];
  } else {
    // Single batch call instead of one createSignedUrl round trip per photo
    // (up to `limit`, i.e. 100, photos per request).
    const { data: signedUrls, error: signError } = await supabase.storage
      .from(WORKING_COPIES_BUCKET)
      .createSignedUrls(
        photoList.map((photo) => photo.storage_path),
        SIGNED_URL_EXPIRY_SECONDS,
      );
    if (signError || !signedUrls || signedUrls.some((s) => s.error)) {
      return await serverError(
        signError ?? new Error('createSignedUrls returned no data'),
        'Failed to generate photo URLs',
      );
    }
    photosWithUrls = photoList.map((photo, i) => ({
      ...photo,
      signed_url: signedUrls[i]!.signedUrl,
    }));
  }

  return json({
    photos: photosWithUrls,
    session: {
      stage: session?.stage ?? 'ranking',
      is_complete: session?.stage === 'complete',
    },
  });
});
