import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, serveAuthed } from '../_shared/http.ts';
initSentry();

const Body = z.object({
  session_id: z.string().uuid(),
  photo_id: z.string().uuid(),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = await parseBody(req, Body);
  if (parsed instanceof Response) return parsed;

  const { session_id, photo_id } = parsed;

  // RLS ensures the photo belongs to a session owned by the calling user.
  const { data, error } = await supabase
    .from('photos')
    .update({ is_suppressed: true })
    .eq('id', photo_id)
    .eq('session_id', session_id)
    .eq('is_suppressed', false) // idempotency guard
    .select('id')
    .single();

  if (error || !data) {
    return json({ error: 'Photo not found or already removed' }, 404);
  }

  // Delete open comparison rows involving this photo so the partner can be re-paired.
  await supabase
    .from('comparisons')
    .delete()
    .eq('session_id', session_id)
    .is('completed_at', null)
    .or(`photo_a_id.eq.${data.id},photo_b_id.eq.${data.id}`);

  return json({ photo_id: data.id });
});
