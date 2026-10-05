import { assertEquals } from 'jsr:@std/assert@1';
import {
  clientIdentity,
  RATE_LIMIT_BATCH_WRITE,
  RATE_LIMIT_READ,
  RATE_LIMIT_WRITE,
  rateLimitResponse,
  retryAfterSeconds,
} from './rate-limit.ts';

Deno.test('clientIdentity uses the first hop of x-forwarded-for', () => {
  const req = new Request('https://example.com', {
    headers: { 'x-forwarded-for': '203.0.113.5, 10.0.0.1' },
  });
  assertEquals(clientIdentity(req), '203.0.113.5');
});

Deno.test('clientIdentity falls back to x-real-ip when x-forwarded-for is absent', () => {
  const req = new Request('https://example.com', {
    headers: { 'x-real-ip': '198.51.100.7' },
  });
  assertEquals(clientIdentity(req), '198.51.100.7');
});

Deno.test('clientIdentity falls back to "unknown" when no IP headers are present', () => {
  const req = new Request('https://example.com');
  assertEquals(clientIdentity(req), 'unknown');
});

Deno.test('clientIdentity ignores an empty x-forwarded-for value', () => {
  const req = new Request('https://example.com', {
    headers: { 'x-forwarded-for': '', 'x-real-ip': '198.51.100.7' },
  });
  assertEquals(clientIdentity(req), '198.51.100.7');
});

Deno.test('retryAfterSeconds is the time to refill one token, rounded up', () => {
  assertEquals(retryAfterSeconds(RATE_LIMIT_WRITE), 3);
  assertEquals(retryAfterSeconds(RATE_LIMIT_READ), 1);
  assertEquals(retryAfterSeconds(RATE_LIMIT_BATCH_WRITE), 1);
});

Deno.test('rateLimitResponse is a 429 that carries Retry-After only when given a tier', () => {
  const withTier = rateLimitResponse({}, RATE_LIMIT_WRITE);
  assertEquals(withTier.status, 429);
  assertEquals(withTier.headers.get('Retry-After'), '3');

  const withoutTier = rateLimitResponse({});
  assertEquals(withoutTier.status, 429);
  assertEquals(withoutTier.headers.get('Retry-After'), null);
});

// submit-comparison fires once per comparison tap, so it must sustain a human
// tap pace. On RATE_LIMIT_WRITE (20 burst, then 1 per 3s) taps past the first
// 20 were refused and the user's choice was dropped (scout finding F3).
Deno.test('RATE_LIMIT_READ sustains a comparison tap every 2 seconds, RATE_LIMIT_WRITE does not', () => {
  // Token bucket starting full, one call every 2s for 15 minutes (450 taps).
  const refused = (config: { capacity: number; refillPerSecond: number }) => {
    let tokens = config.capacity;
    let count = 0;
    for (let i = 0; i < 450; i++) {
      tokens = Math.min(config.capacity, tokens + 2 * config.refillPerSecond);
      if (tokens >= 1) tokens -= 1;
      else count++;
    }
    return count;
  };
  assertEquals(refused(RATE_LIMIT_READ), 0);
  assertEquals(refused(RATE_LIMIT_WRITE) > 100, true);
});

Deno.test('submit-comparison is checked against the polling tier and answers 429 with Retry-After', async () => {
  const source = await Deno.readTextFile(
    new URL('../submit-comparison/index.ts', import.meta.url),
  );
  assertEquals(source.includes("isRateLimited('submit-comparison', req, RATE_LIMIT_READ)"), true);
  assertEquals(/isRateLimited\([^)]*RATE_LIMIT_WRITE/.test(source), false);
  // The client waits out Retry-After and resubmits, so the 429 has to carry it.
  assertEquals(source.includes('rateLimitResponse(CORS, RATE_LIMIT_READ)'), true);
});
