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
