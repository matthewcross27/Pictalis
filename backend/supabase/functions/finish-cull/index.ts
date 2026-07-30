import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, serveAuthed, SessionIdSchema } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = await parseBody(req, SessionIdSchema);
  if (parsed instanceof Response) return parsed;

  const { error, count } = await supabase
    .from('sessions')
    .update({ stage: 'ranking' }, { count: 'exact' })
    .eq('id', parsed.session_id)
    .eq('stage', 'cull');

  if (error) {
    return json({ error: error.message }, 500);
  }

  if (count === 0) {
    return json({ error: 'Session not in cull stage' }, 409);
  }

  return json({ stage: 'ranking' });
});
