import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import {
  json,
  parseQuery,
  serveAuthed,
  SessionIdSchema,
  SIGNED_URL_EXPIRY_SECONDS,
  WORKING_COPIES_BUCKET,
} from '../_shared/http.ts';
initSentry();

const QuerySchema = SessionIdSchema.extend({
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = parseQuery(req, QuerySchema);
  if (parsed instanceof Response) return parsed;

  // Fetch session stage so iOS can show "Complete" / "In Progress" badge.
  const { data: session } = await supabase
    .from('sessions')
    .select('stage')
    .eq('id', parsed.session_id)
    .single();

  const { data: photos, error } = await supabase
    .from('photos')
    .select(
      'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, is_suppressed, cluster_id, quality_flags',
    )
    .eq('session_id', parsed.session_id)
    .eq('is_suppressed', false)
    .eq('upload_status', 'uploaded')
    .order('elo_rating', { ascending: false })
    .limit(parsed.limit);

  if (error) {
    return json({ error: 'Failed to fetch photos' }, 500);
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
      return json({ error: 'Failed to generate photo URLs' }, 500);
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
