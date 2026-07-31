import { assertEquals } from 'jsr:@std/assert@1';
import { clientIdentity } from './rate-limit.ts';

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
