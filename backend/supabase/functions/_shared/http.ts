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

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
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

// Returns the authenticated user, or a 401 Response if getUser() fails -
// check `instanceof Response` at the call site before using the result.
export async function requireUser(supabase: SupabaseClient): Promise<User | Response> {
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) {
    return json({ error: 'Unauthorized' }, 401);
  }
  return user;
}

// Fetches a session row by id, or returns a 404 Response if it doesn't
// exist - check `instanceof Response` at the call site before using the
// result. `columns` defaults to just 'id' for call sites that only need to
// verify the session exists.
export async function requireSession(
  supabase: SupabaseClient,
  sessionId: string,
  columns = 'id',
) {
  const { data: session, error } = await supabase
    .from('sessions')
    .select(columns)
    .eq('id', sessionId)
    .single();
  if (error || !session) {
    return json({ error: 'Session not found' }, 404);
  }
  return session;
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
