import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseJsonBody, serveAuthed } from '../_shared/http.ts';
initSentry();

const BodySchema = z.object({
  session_id: z.string().uuid(),
  decisions: z.array(z.object({
    photo_id: z.string().uuid(),
    decision: z.enum(['keep', 'drop']),
  })).min(1).max(300),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { session_id, decisions } = parsed.data;

  // Apply each decision to the individual photo only.
  // cull_decision IS NULL guard makes this idempotent - safe to retry.
  const results = await Promise.all(
    decisions.map(async ({ photo_id, decision }) => {
      try {
        const update = decision === 'keep'
          ? { cull_decision: 'keep' }
          : { cull_decision: 'drop', is_suppressed: true };

        const { error: updateError } = await supabase
          .from('photos')
          .update(update)
          .eq('id', photo_id)
          .eq('session_id', session_id)
          .is('cull_decision', null);

        if (updateError) {
          return { photo_id, success: false, error: updateError.message };
        }

        // Zero rows updated: decision already set - idempotent success.
        // With pre-registration, the photo row always exists before cull
        // starts, so zero-rows-updated means cull_decision was already written.
        return { photo_id, success: true };
      } catch (err) {
        return { photo_id, success: false, error: String(err) };
      }
    }),
  );

  return json({ results });
});
