import { z } from 'npm:zod@3';
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';
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
