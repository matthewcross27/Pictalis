import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, serveAuthed, SessionIdSchema } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = await parseBody(req, SessionIdSchema);
  if (parsed instanceof Response) return parsed;

  const { data, error } = await supabase
    .from('sessions')
    .update({ upload_complete: true })
    .eq('id', parsed.session_id)
    .select('id')
    .single();

  if (error || !data) {
    return json({ error: 'Session not found' }, 404);
  }

  return json({ ok: true });
});
