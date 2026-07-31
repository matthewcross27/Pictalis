import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

// Postgres-backed token bucket rate limiter.
//
// Supabase Edge Functions are stateless and horizontally scaled, so an
// in-process limiter wouldn't be shared across instances. Supabase's
// built-in `[auth.rate_limit]` config only covers Auth operations
// (sign-in/sign-up/token refresh/anonymous sign-in) and doesn't cover these
// business endpoints at all. The `check_rate_limit` Postgres function
// (backend/supabase/migrations/20260731000001_abuse_protection.sql) gives
// every function instance a shared, atomic view of each caller's remaining
// budget with no extra infrastructure (no Redis/proxy needed).
//
// Buckets are keyed by endpoint + caller IP (see `clientIdentity`), not by
// user id: most endpoints don't otherwise call `auth.getUser()`, and keying
// on IP avoids adding an auth round-trip to every function purely for
// throttling. The tradeoff is that callers sharing an IP (NAT/corporate
// networks) share a budget - acceptable for "basic" abuse protection.

export interface RateLimitConfig {
  capacity: number;
  refillPerSecond: number;
}

// Mutating endpoints: stricter, since each call can create/modify rows.
export const RATE_LIMIT_WRITE: RateLimitConfig = { capacity: 20, refillPerSecond: 20 / 60 };
// Read-only/polling endpoints: more generous.
export const RATE_LIMIT_READ: RateLimitConfig = { capacity: 60, refillPerSecond: 1 };

export function clientIdentity(req: Request): string {
  const fwd = req.headers.get('x-forwarded-for');
  if (fwd) {
    const first = fwd.split(',')[0].trim();
    if (first) return first;
  }
  return req.headers.get('x-real-ip') ?? 'unknown';
}

// Checks and consumes one request's worth of budget for `bucket` (typically
// the function name) + the caller's IP. Uses a bare anon-key client (no
// forwarded Authorization) since throttling should apply before/regardless
// of auth. Fails open on a Postgres error so a limiter outage never takes
// down the API.
export async function isRateLimited(
  bucket: string,
  req: Request,
  config: RateLimitConfig,
): Promise<boolean> {
  const supabase: SupabaseClient = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  );
  const key = `${bucket}:${clientIdentity(req)}`;
  const { data, error } = await supabase.rpc('check_rate_limit', {
    p_key: key,
    p_capacity: config.capacity,
    p_refill_per_second: config.refillPerSecond,
  });
  if (error) {
    console.error('Rate limit check failed, failing open:', error);
    return false;
  }
  return data === false;
}

export function rateLimitResponse(cors: Record<string, string>): Response {
  return new Response(
    JSON.stringify({ error: 'Too many requests, please slow down' }),
    { status: 429, headers: { ...cors, 'Content-Type': 'application/json' } },
  );
}
