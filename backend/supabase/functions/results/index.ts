import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import {
  json,
  parseQuery,
  serveAuthed,
  SIGNED_URL_EXPIRY_SECONDS,
  WORKING_COPIES_BUCKET,
} from '../_shared/http.ts';
initSentry();

const QuerySchema = z.object({
  session_id: z.string().uuid(),
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

  const photosWithUrls = await Promise.all(
    (photos ?? []).map(async (photo) => {
      const { data: signed, error: signedError } = await supabase.storage
        .from(WORKING_COPIES_BUCKET)
        .createSignedUrl(photo.storage_path, SIGNED_URL_EXPIRY_SECONDS);
      if (signedError) throw signedError;
      return { ...photo, signed_url: signed?.signedUrl ?? null };
    }),
  ).catch(() => null);

  if (!photosWithUrls) {
    return json({ error: 'Failed to generate photo URLs' }, 500);
  }

  return json({
    photos: photosWithUrls,
    session: {
      stage: session?.stage ?? 'ranking',
      is_complete: session?.stage === 'complete',
    },
  });
});
