import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseBody, serveAuthed, SessionIdSchema } from '../_shared/http.ts';
initSentry();

const BodySchema = SessionIdSchema.extend({
  decisions: z.array(z.object({
    photo_id: z.string().uuid(),
    decision: z.enum(['keep', 'drop']),
  })).min(1).max(300),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const parsed = await parseBody(req, BodySchema);
  if (parsed instanceof Response) return parsed;

  const { session_id, decisions } = parsed;

  const keepIds = decisions.filter((d) => d.decision === 'keep').map((d) => d.photo_id);
  const dropIds = decisions.filter((d) => d.decision === 'drop').map((d) => d.photo_id);

  // Single RPC call replaces the two concurrent bulk UPDATEs this used to
  // issue - the DB function merges them into one CASE-based UPDATE.
  // cull_decision IS NULL guard makes this idempotent - safe to retry.
  const { error } = await supabase.rpc('batch_submit_cull', {
    p_session_id: session_id,
    p_keep_ids: keepIds,
    p_drop_ids: dropIds,
  });

  // Zero rows updated for a given photo: decision already set - idempotent
  // success. With pre-registration, the photo row always exists before cull
  // starts, so that case just means cull_decision was already written.
  const entry = error
    ? { success: false as const, error: error.message }
    : { success: true as const };
  const results = decisions.map(({ photo_id }) => ({ photo_id, ...entry }));

  return json({ results });
});
