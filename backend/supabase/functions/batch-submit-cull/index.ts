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

  // One bulk UPDATE per decision type instead of one per photo (up to 300).
  // cull_decision IS NULL guard makes this idempotent - safe to retry.
  const [keepResult, dropResult] = await Promise.all([
    keepIds.length > 0
      ? supabase
        .from('photos')
        .update({ cull_decision: 'keep' })
        .eq('session_id', session_id)
        .in('id', keepIds)
        .is('cull_decision', null)
      : { error: null },
    dropIds.length > 0
      ? supabase
        .from('photos')
        .update({ cull_decision: 'drop', is_suppressed: true })
        .eq('session_id', session_id)
        .in('id', dropIds)
        .is('cull_decision', null)
      : { error: null },
  ]);

  // Zero rows updated for a given photo: decision already set - idempotent
  // success. With pre-registration, the photo row always exists before cull
  // starts, so that case just means cull_decision was already written.
  const resultFor = (ids: string[], error: { message: string } | null) => {
    const entry = error
      ? { success: false as const, error: error.message }
      : { success: true as const };
    return new Map(ids.map((photo_id) => [photo_id, entry]));
  };
  const resultMap = new Map([
    ...resultFor(keepIds, keepResult.error),
    ...resultFor(dropIds, dropResult.error),
  ]);
  const results = decisions.map(({ photo_id }) => ({ photo_id, ...resultMap.get(photo_id)! }));

  return json({ results });
});
