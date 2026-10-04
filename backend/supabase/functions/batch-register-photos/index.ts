import { initSentry } from '../_shared/sentry.ts';
import {
  BatchRegisterPhotosBody,
  buildBatchResults,
  listAllFilenames,
  splitByStoragePath,
} from '../_shared/photo-registration.ts';
import {
  CORS,
  json,
  parseBody,
  requireSession,
  requireUser,
  serveAuthed,
  serverError,
  WORKING_COPIES_BUCKET,
} from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_BATCH_WRITE, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

// Registers many uploaded photos in one request: the user/session checks, the
// storage folder listing and the UPDATE each happen once per batch instead of
// once per photo (see register-photo, which stays as-is for older app
// versions). Per-photo outcomes are in `results`; a non-2xx status means the
// whole batch failed and can be retried as-is.
serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('batch-register-photos', req, RATE_LIMIT_BATCH_WRITE)) {
    return rateLimitResponse(CORS, RATE_LIMIT_BATCH_WRITE);
  }

  const parsed = await parseBody(req, BatchRegisterPhotosBody);
  if (parsed instanceof Response) return parsed;

  const { session_id, photos } = parsed;

  const [user, session] = await Promise.all([
    requireUser(supabase),
    requireSession(supabase, session_id),
  ]);
  if (user instanceof Response) return user;
  if (session instanceof Response) return session;

  const { candidates, rejected } = splitByStoragePath(photos, user.id, session_id);

  let storageFilenames = new Set<string>();
  let registeredIds = new Set<string>();

  if (candidates.length > 0) {
    try {
      storageFilenames = await listAllFilenames((options) =>
        supabase.storage.from(WORKING_COPIES_BUCKET).list(`${user.id}/${session_id}`, {
          ...options,
          sortBy: { column: 'name', order: 'asc' },
        })
      );
    } catch (err) {
      return await serverError(err, 'Failed to check storage for uploaded photos');
    }

    const toRegister = candidates.filter((p) => storageFilenames.has(p.storage_path.split('/')[2]));

    if (toRegister.length > 0) {
      // One UPDATE for the whole batch. Idempotent: re-registering an
      // already-uploaded row rewrites the same values.
      const { data, error } = await supabase.rpc('register_photos_batch', {
        p_session_id: session_id,
        p_photo_ids: toRegister.map((p) => p.photo_id),
        p_storage_paths: toRegister.map((p) => p.storage_path),
      });
      if (error) {
        return await serverError(error, 'Failed to register photos');
      }
      registeredIds = new Set((data as { photo_id: string }[]).map((row) => row.photo_id));
    }
  }

  return json({
    results: buildBatchResults(photos, rejected, storageFilenames, registeredIds),
  });
});
