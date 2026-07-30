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

  const { data, error } = await supabase
    .from('sessions')
    .update({ upload_complete: true })
    .eq('id', parsed.data.session_id)
    .select('id')
    .single();

  if (error || !data) {
    return json({ error: 'Session not found' }, 404);
  }

  return json({ ok: true });
});
