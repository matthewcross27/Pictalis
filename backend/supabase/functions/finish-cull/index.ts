import { initSentry } from '../_shared/sentry.ts';
import { json, parseJsonBody, serveAuthed, SessionIdSchema } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = SessionIdSchema.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { error, count } = await supabase
    .from('sessions')
    .update({ stage: 'ranking' }, { count: 'exact' })
    .eq('id', parsed.data.session_id)
    .eq('stage', 'cull');

  if (error) {
    return json({ error: error.message }, 500);
  }

  if (count === 0) {
    return json({ error: 'Session not in cull stage' }, 409);
  }

  return json({ stage: 'ranking' });
});
