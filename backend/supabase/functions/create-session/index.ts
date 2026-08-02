import { z } from 'npm:zod@3';
import { computeTopK } from '../_shared/ranking-logic.ts';
import { initSentry } from '../_shared/sentry.ts';
import { CORS, json, parseBody, requireUser, serveAuthed, serverError } from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_WRITE, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

const CreateSessionBody = z.object({
  photo_count: z.number().int().min(2).max(300),
});

serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('create-session', req, RATE_LIMIT_WRITE)) {
    return rateLimitResponse(CORS);
  }

  // requireUser (an auth-server round trip) and parseBody (no network call,
  // just reading the request body) are independent - run them concurrently.
  const [user, parsed] = await Promise.all([
    requireUser(supabase),
    parseBody(req, CreateSessionBody),
  ]);
  if (user instanceof Response) return user;
  if (parsed instanceof Response) return parsed;

  const topK = computeTopK(parsed.photo_count);
  const { data: session, error } = await supabase
    .from('sessions')
    .insert({
      photo_count: parsed.photo_count,
      user_id: user.id,
      top_k: topK,
      stage: 'ranking',
    })
    .select('id, created_at, expires_at, status, photo_count, top_k')
    .single();

  if (error) {
    return await serverError(error, error.message);
  }

  return json({ session }, 201);
});
