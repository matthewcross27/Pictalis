import { BatchPreRegisterBody } from '../_shared/batch-pre-register.ts';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseJsonBody, serveAuthed } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = BatchPreRegisterBody.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const { session_id, photo_ids } = parsed.data;

  // Verify the session belongs to the authenticated user (RLS handles this,
  // but an explicit check gives a clear 404 rather than a silent empty result).
  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return json({ error: 'Session not found' }, 404);
  }

  // Insert photo identity rows. ignoreDuplicates makes this idempotent:
  // a network retry after partial success won't double-insert existing rows.
  const rows = photo_ids.map((id) => ({
    id,
    session_id,
    upload_status: 'pending',
  }));

  const { error: insertError } = await supabase
    .from('photos')
    .upsert(rows, { onConflict: 'id', ignoreDuplicates: true });

  if (insertError) {
    console.error('Failed to pre-register photos:', insertError);
    return json({ error: 'Failed to pre-register photos' }, 500);
  }

  return json({ ok: true });
});
