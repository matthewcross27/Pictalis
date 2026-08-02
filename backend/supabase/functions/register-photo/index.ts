import { initSentry } from '../_shared/sentry.ts';
import { RegisterPhotoBody } from '../_shared/photo-registration.ts';
import {
  CORS,
  json,
  parseBody,
  requireSession,
  requireUser,
  serveAuthed,
  WORKING_COPIES_BUCKET,
} from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_WRITE, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('register-photo', req, RATE_LIMIT_WRITE)) {
    return rateLimitResponse(CORS);
  }

  // requireUser (an auth-server round trip) and parseBody (no network call,
  // just reading the request body) are independent - run them concurrently.
  const [user, parsed] = await Promise.all([
    requireUser(supabase),
    parseBody(req, RegisterPhotoBody),
  ]);
  if (user instanceof Response) return user;
  if (parsed instanceof Response) return parsed;

  const { session_id, storage_path, photo_id } = parsed;
  const [pathUid, pathSessionId, filename] = storage_path.split('/');

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

  // Storage existence check and session lookup are independent reads - run
  // them concurrently to save a round trip on the upload hot path.
  const [{ data: objects, error: listError }, session] = await Promise.all([
    supabase.storage
      .from(WORKING_COPIES_BUCKET)
      .list(`${pathUid}/${pathSessionId}`, { search: filename }),
    requireSession(supabase, session_id),
  ]);

  if (listError || !objects || !objects.some((o) => o.name === filename)) {
    return json({ error: 'Storage object not found' }, 404);
  }
  if (session instanceof Response) return session;

  const PHOTO_COLUMNS =
    'id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed';

  // Row was pre-registered at session start. UPDATE sets the bytes location
  // and marks upload complete. Idempotent: a retry on an already-uploaded row
  // returns the existing data unchanged.
  //
  // This UPDATE can only touch a row that already exists (matched by
  // photo_id + session_id below) - it never inserts one. The session's
  // photo_count cap is enforced where rows actually get created, in
  // batch-pre-register's pre_register_photos_atomic RPC, so there's
  // nothing to re-check here.
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
