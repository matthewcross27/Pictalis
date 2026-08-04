import { createClient } from 'jsr:@supabase/supabase-js@2';
import { initSentry, Sentry } from '../_shared/sentry.ts';
import { CORS, json, serverError, WORKING_COPIES_BUCKET } from '../_shared/http.ts';
import {
  chunk,
  isAuthorizedCronCaller,
  STORAGE_REMOVE_CHUNK_SIZE,
} from '../_shared/cleanup-expired-sessions.ts';
initSentry();

// Invoked hourly by pg_cron/pg_net (see
// backend/supabase/migrations/20260803000001_cleanup_via_storage_api.sql).
// Unlike every other function here, this one runs as an admin/system job,
// not on behalf of an authenticated end user: it must see and delete every
// user's expired sessions, which requires bypassing RLS with the
// service-role key rather than forwarding a caller's JWT.
//
// Storage objects are removed via the Storage API *before* the owning
// sessions rows are deleted, and only once that removal is confirmed to
// have succeeded - a raw SQL `DELETE FROM storage.objects` is rejected by
// the platform's protect_delete() trigger (it only removes the Postgres
// metadata row, not the underlying stored object). If storage removal
// fails, this returns an error without touching `sessions`, so the next
// hourly run retries the same (still-expired) rows - safe because
// `remove()` is a no-op for paths already deleted and the expiry query has
// no lower bound.
Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!isAuthorizedCronCaller(req, serviceRoleKey)) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const admin = createClient(Deno.env.get('SUPABASE_URL') ?? '', serviceRoleKey!);
    const nowIso = new Date().toISOString();

    const { data: expiredSessions, error: sessionsError } = await admin
      .from('sessions')
      .select('id')
      .lt('expires_at', nowIso);
    if (sessionsError) {
      return await serverError(sessionsError, 'Failed to query expired sessions');
    }

    const sessionIds = (expiredSessions ?? []).map((s) => s.id as string);
    if (sessionIds.length === 0) {
      return json({ sessions_deleted: 0, objects_removed: 0 });
    }

    const { data: expiredPhotos, error: photosError } = await admin
      .from('photos')
      .select('storage_path')
      .in('session_id', sessionIds)
      .not('storage_path', 'is', null);
    if (photosError) {
      return await serverError(photosError, 'Failed to query expired photos');
    }

    const paths = [...new Set((expiredPhotos ?? []).map((p) => p.storage_path as string))];

    for (const batch of chunk(paths, STORAGE_REMOVE_CHUNK_SIZE)) {
      const { error: removeError } = await admin.storage.from(WORKING_COPIES_BUCKET).remove(batch);
      if (removeError) {
        return await serverError(removeError, 'Failed to remove expired storage objects');
      }
    }

    // Cascades to photos (and their comparisons) via ON DELETE CASCADE.
    const { error: deleteError, count } = await admin
      .from('sessions')
      .delete({ count: 'exact' })
      .in('id', sessionIds);
    if (deleteError) {
      return await serverError(deleteError, 'Failed to delete expired sessions');
    }

    return json({ sessions_deleted: count ?? sessionIds.length, objects_removed: paths.length });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return json({ error: 'Internal server error' }, 500);
  }
});
