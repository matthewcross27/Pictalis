import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, serveAuthed, serverError, SessionIdSchema } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = await parseBody(req, SessionIdSchema);
  if (parsed instanceof Response) return parsed;

  const { session_id } = parsed;

  const { error, count } = await supabase
    .from('sessions')
    .update({ stage: 'cull' }, { count: 'exact' })
    .eq('id', session_id)
    .not('stage', 'eq', 'complete');

  if (error) {
    return await serverError(error, error.message);
  }

  if (count === 0) {
    return json({ error: 'Session not found or already complete' }, 409);
  }

  return json({ stage: 'cull' });
});
