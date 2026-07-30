import { BatchPreRegisterBody } from '../_shared/batch-pre-register.ts';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, requireSession, requireUser, serveAuthed } from '../_shared/http.ts';
initSentry();

serveAuthed(async (req, _authHeader, supabase) => {
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
