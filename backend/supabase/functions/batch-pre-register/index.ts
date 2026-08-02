import { BatchPreRegisterBody } from '../_shared/batch-pre-register.ts';
import { initSentry } from '../_shared/sentry.ts';
import {
  CORS,
  json,
  parseBody,
  requireSession,
  requireUser,
  serveAuthed,
  serverError,
} from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_WRITE, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('batch-pre-register', req, RATE_LIMIT_WRITE)) {
    return rateLimitResponse(CORS);
  }

  const parsed = await parseBody(req, BatchPreRegisterBody);
  if (parsed instanceof Response) return parsed;

  const { session_id, photo_ids } = parsed;

  // requireUser and requireSession are independent reads (neither depends on
  // the other's result), so run them concurrently to save a round trip.
  // Verify the session belongs to the authenticated user (RLS handles this,
  // but an explicit check gives a clear 404 rather than a silent empty result).
  const [user, session] = await Promise.all([
    requireUser(supabase),
    requireSession(supabase, session_id),
  ]);
  if (user instanceof Response) return user;
  if (session instanceof Response) return session;

  // Insert photo identity rows and enforce the session's photo_count cap
  // atomically. ON CONFLICT DO NOTHING (inside the RPC) makes this
  // idempotent: a network retry after partial success won't double-insert
  // existing rows or double-count them against the cap.
  const { error: insertError } = await supabase.rpc(
    'pre_register_photos_atomic',
    { p_session_id: session_id, p_photo_ids: photo_ids },
  );

  if (insertError) {
    if (insertError.code === 'UE002') {
      return json(
        { error: "Registering these photos would exceed this session's declared photo count" },
        409,
      );
    }
    return await serverError(insertError, 'Failed to pre-register photos');
  }

  return json({ ok: true });
});
