import { z } from 'npm:zod@3';
import { computeTopK } from '../_shared/ranking-logic.ts';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseJsonBody, serveAuthed } from '../_shared/http.ts';
initSentry();

const CreateSessionBody = z.object({
  photo_count: z.number().int().min(2).max(300),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = CreateSessionBody.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const topK = computeTopK(parsed.data.photo_count);
  const { data: session, error } = await supabase
    .from('sessions')
    .insert({
      photo_count: parsed.data.photo_count,
      user_id: user.id,
      top_k: topK,
      stage: 'ranking',
    })
    .select('id, created_at, expires_at, status, photo_count, top_k')
    .single();

  if (error) {
    return json({ error: error.message }, 500);
  }

  return json({ session }, 201);
});
