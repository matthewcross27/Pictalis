import { z } from 'npm:zod@3';
import { createClient, type SupabaseClient, type User } from 'jsr:@supabase/supabase-js@2';
import { Sentry } from './sentry.ts';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Shared by every endpoint that takes only a session_id, whether as a JSON
// body field (mutations) or a query param (reads) - see call sites.
export const SessionIdSchema = z.object({ session_id: z.string().uuid() });

// The private Storage bucket compressed working copies are uploaded to and
// signed-URL'd from - see backend/supabase/migrations/20260517000001_storage_bucket.sql.
export const WORKING_COPIES_BUCKET = 'working-copies';

// Expiry (in seconds) for signed URLs generated for working-copy photos.
export const SIGNED_URL_EXPIRY_SECONDS = 3600;

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// Reports a handled (non-thrown) failure - e.g. a Supabase query returning
// an `error` field instead of throwing - to Sentry before building the error
// Response, so DB/storage failures are as visible in production as the
// uncaught exceptions serveAuthed's top-level catch already reports.
export async function serverError(
  cause: unknown,
  message: string,
  status = 500,
): Promise<Response> {
  Sentry.captureException(cause instanceof Error ? cause : new Error(String(cause)));
  await Sentry.flush(2000);
  return json({ error: message }, status);
}

export function supabaseFromAuth(authHeader: string): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } },
  );
}

// Returns the parsed body, or a 400 Response if req.json() throws - check
// `instanceof Response` at the call site before using the result.
export async function parseJsonBody(req: Request): Promise<unknown | Response> {
  try {
    return await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
}

// Parses and validates a JSON request body against a zod schema in one step,
// or returns a 400 Response (invalid JSON, or schema violation) - check
// `instanceof Response` at the call site before using the result.
export async function parseBody<T extends z.ZodTypeAny>(
  req: Request,
  schema: T,
): Promise<z.infer<T> | Response> {
  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = schema.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }
  return parsed.data;
}

// Parses and validates a request URL's query params against a zod schema in
// one step, or returns a 400 Response (schema violation) - check `instanceof
// Response` at the call site before using the result.
export function parseQuery<T extends z.ZodTypeAny>(
  req: Request,
  schema: T,
): z.infer<T> | Response {
  const url = new URL(req.url);
  const parsed = schema.safeParse(Object.fromEntries(url.searchParams));
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }
  return parsed.data;
}

// Returns the authenticated user, or a 401 Response if getUser() fails -
// check `instanceof Response` at the call site before using the result.
export async function requireUser(supabase: SupabaseClient): Promise<User | Response> {
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) {
    return json({ error: 'Unauthorized' }, 401);
  }
  return user;
}

// Shape returned by requireSession(supabase, sessionId, 'id, stage, photo_count, top_k'),
// used by both next-pair and session-status.
export interface SessionRow {
  id: string;
  stage: string;
  photo_count: number;
  top_k: number | null;
}

// Fetches a session row by id, or returns a 404 Response if it doesn't
// exist - check `instanceof Response` at the call site before using the
// result. `columns` defaults to just 'id' for call sites that only need to
// verify the session exists.
export async function requireSession<Row = { id: string }>(
  supabase: SupabaseClient,
  sessionId: string,
  columns = 'id',
): Promise<Row | Response> {
  const { data: session, error } = await supabase
    .from('sessions')
    .select(columns)
    .eq('id', sessionId)
    .single();
  if (error || !session) {
    return json({ error: 'Session not found' }, 404);
  }
  // `columns` is a plain runtime string, not a literal type, so Supabase's
  // select() can't infer a row shape from it - callers assert the shape they
  // asked for via the `Row` type parameter instead. Passing the columns
  // string as a literal generic here blows up `deno check` with a runaway
  // recursive-type OOM (supabase-js's select<Query> parser).
  return session as unknown as Row;
}

// Persists a session's transition to the terminal 'complete' stage. Called
// from both next-pair and session-status, whichever detects completion first.
export async function markSessionComplete(
  supabase: SupabaseClient,
  sessionId: string,
): Promise<void> {
  await supabase.from('sessions').update({ stage: 'complete' }).eq('id', sessionId);
}

// Wraps a handler with the boilerplate every Edge Function repeated
// identically: OPTIONS preflight, Authorization header presence check,
// Supabase client construction, and top-level Sentry error reporting.
export function serveAuthed(
  handler: (
    req: Request,
    authHeader: string,
    supabase: SupabaseClient,
  ) => Promise<Response>,
): void {
  Deno.serve(async (req) => {
    try {
      if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

      const authHeader = req.headers.get('Authorization');
      if (!authHeader) {
        return json({ error: 'Missing Authorization header' }, 401);
      }

      return await handler(req, authHeader, supabaseFromAuth(authHeader));
    } catch (err) {
      Sentry.captureException(err);
      await Sentry.flush(2000);
      return json({ error: 'Internal server error' }, 500);
    }
  });
}
