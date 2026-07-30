import { initSentry } from '../_shared/sentry.ts';
import { RegisterPhotoBody } from '../_shared/photo-registration.ts';
import { json, parseJsonBody, requireUser, serveAuthed } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  const user = await requireUser(supabase);
  if (user instanceof Response) return user;

  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = RegisterPhotoBody.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { session_id, storage_path, photo_id } = parsed.data;
  const [pathUid, pathSessionId] = storage_path.split('/');

  if (pathUid !== user.id) {
    return json(
      { error: 'storage_path UID segment must match the authenticated user' },
      400,
    );
  }
  if (pathSessionId !== session_id) {
    return json(
      { error: 'storage_path session_id segment must match session_id field' },
      400,
    );
  }

  const filename = storage_path.split('/')[2];
  const { data: objects, error: listError } = await supabase.storage
    .from('working-copies')
    .list(`${pathUid}/${pathSessionId}`, { search: filename });

  if (listError || !objects || !objects.some((o) => o.name === filename)) {
    return json({ error: 'Storage object not found' }, 404);
  }

  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return json({ error: 'Session not found' }, 404);
  }

  const PHOTO_COLUMNS =
    'id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed';

  // Row was pre-registered at session start. UPDATE sets the bytes location
  // and marks upload complete. Idempotent: a retry on an already-uploaded row
  // returns the existing data unchanged.
  const { data: photo, error: updateError } = await supabase
    .from('photos')
    .update({ storage_path, upload_status: 'uploaded' })
    .eq('id', photo_id)
    .eq('session_id', session_id)
    .select(PHOTO_COLUMNS)
    .single();

  if (updateError || !photo) {
    // Row missing: batch-pre-register wasn't called, or session/id mismatch.
    return json({ error: 'Photo not pre-registered or session mismatch' }, 404);
  }

  return json({ photo });
});
