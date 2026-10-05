import { DEFAULT_TOP_K } from '../_shared/ranking-logic.ts';
import { initSentry } from '../_shared/sentry.ts';
import { CORS, json, parseBody, requireUser, serveAuthed, serverError } from '../_shared/http.ts';
import {
  CreateSessionBody,
  resolveExistingSession,
  UNIQUE_VIOLATION,
} from '../_shared/create-session.ts';
import { isRateLimited, RATE_LIMIT_WRITE, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

const SESSION_COLUMNS = 'id, created_at, expires_at, status, photo_count, top_k';

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

  const { data: session, error } = await supabase
    .from('sessions')
    .insert({
      // Omitted when the client sent no id, so the column default applies.
      ...(parsed.session_id ? { id: parsed.session_id } : {}),
      photo_count: parsed.photo_count,
      user_id: user.id,
      top_k: DEFAULT_TOP_K,
      stage: 'ranking',
    })
    .select(SESSION_COLUMNS)
    .single();

  if (error && error.code === UNIQUE_VIOLATION && parsed.session_id) {
    // A repeat of a call that already created this session (e.g. the client
    // lost the response). Return the existing row so the caller can carry on.
    const { data: existing } = await supabase
      .from('sessions')
      .select(SESSION_COLUMNS)
      .eq('id', parsed.session_id)
      .maybeSingle();
    if (resolveExistingSession(existing, parsed.photo_count) === 'reuse') {
      return json({ session: existing }, 200);
    }
    return json({ error: 'session_id already in use' }, 409);
  }

  if (error) {
    return await serverError(error, error.message);
  }

  return json({ session }, 201);
});
