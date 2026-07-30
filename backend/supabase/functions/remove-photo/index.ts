import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, serveAuthed, SessionIdSchema } from '../_shared/http.ts';
initSentry();

const Body = SessionIdSchema.extend({
  photo_id: z.string().uuid(),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = await parseBody(req, Body);
  if (parsed instanceof Response) return parsed;

  const { session_id, photo_id } = parsed;

  // The comparison cleanup below only depends on photo_id/session_id (both
  // already known from the request), not on the update's result, so it can
  // run concurrently with the suppress-update instead of waiting on it. It's
  // idempotent (a no-op if there's nothing open to delete), so this stays
  // correct even if the update below turns out to match zero rows.
  const [{ data, error }] = await Promise.all([
    // RLS ensures the photo belongs to a session owned by the calling user.
    supabase
      .from('photos')
      .update({ is_suppressed: true })
      .eq('id', photo_id)
      .eq('session_id', session_id)
      .eq('is_suppressed', false) // idempotency guard
      .select('id')
      .single(),
    // Delete open comparison rows involving this photo so the partner can be re-paired.
    supabase
      .from('comparisons')
      .delete()
      .eq('session_id', session_id)
      .is('completed_at', null)
      .or(`photo_a_id.eq.${photo_id},photo_b_id.eq.${photo_id}`),
  ]);

  if (error || !data) {
    return json({ error: 'Photo not found or already removed' }, 404);
  }

  return json({ photo_id: data.id });
});
