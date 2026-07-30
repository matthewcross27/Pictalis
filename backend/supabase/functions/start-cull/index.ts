import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseJsonBody, serveAuthed } from '../_shared/http.ts';
initSentry();

const BodySchema = z.object({ session_id: z.string().uuid() });

serveAuthed(async (req, _authHeader, supabase) => {
  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { session_id } = parsed.data;

  const { error, count } = await supabase
    .from('sessions')
    .update({ stage: 'cull' }, { count: 'exact' })
    .eq('id', session_id)
    .not('stage', 'eq', 'complete');

  if (error) {
    return json({ error: error.message }, 500);
  }

  if (count === 0) {
    return json({ error: 'Session not found or already complete' }, 409);
  }

  return json({ stage: 'cull' });
});
