import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { json, serveAuthed, WORKING_COPIES_BUCKET } from '../_shared/http.ts';
initSentry();

const QuerySchema = z.object({
  session_id: z.string().uuid(),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const url = new URL(req.url);
  const parsed = QuerySchema.safeParse({
    session_id: url.searchParams.get('session_id'),
    limit: url.searchParams.get('limit') ?? 20,
  });
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  // Fetch session stage so iOS can show "Complete" / "In Progress" badge.
  const { data: session } = await supabase
    .from('sessions')
    .select('stage')
    .eq('id', parsed.data.session_id)
    .single();

  const { data: photos, error } = await supabase
    .from('photos')
    .select(
      'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, is_suppressed, cluster_id, quality_flags',
    )
    .eq('session_id', parsed.data.session_id)
    .eq('is_suppressed', false)
    .eq('upload_status', 'uploaded')
    .order('elo_rating', { ascending: false })
    .limit(parsed.data.limit);

  if (error) {
    return json({ error: 'Failed to fetch photos' }, 500);
  }

  const photosWithUrls = await Promise.all(
    (photos ?? []).map(async (photo) => {
      const { data: signed, error: signedError } = await supabase.storage
        .from(WORKING_COPIES_BUCKET)
        .createSignedUrl(photo.storage_path, 3600);
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
