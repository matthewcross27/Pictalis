import { assertEquals } from 'jsr:@std/assert@1';
import { chunk, isAuthorizedCronCaller } from './cleanup-expired-sessions.ts';

Deno.test('chunk splits into groups of the given size', () => {
  assertEquals(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
});

Deno.test('chunk returns a single group when items fit within size', () => {
  assertEquals(chunk([1, 2], 5), [[1, 2]]);
});

Deno.test('chunk returns an empty array for an empty input', () => {
  assertEquals(chunk([], 5), []);
});

Deno.test('isAuthorizedCronCaller accepts an exact service-role bearer match', () => {
  const req = new Request('https://example.com', {
    headers: { Authorization: 'Bearer secret-key' },
  });
  assertEquals(isAuthorizedCronCaller(req, 'secret-key'), true);
});

Deno.test('isAuthorizedCronCaller rejects a mismatched token', () => {
  const req = new Request('https://example.com', {
    headers: { Authorization: 'Bearer wrong-key' },
  });
  assertEquals(isAuthorizedCronCaller(req, 'secret-key'), false);
});

Deno.test('isAuthorizedCronCaller rejects a missing Authorization header', () => {
  const req = new Request('https://example.com');
  assertEquals(isAuthorizedCronCaller(req, 'secret-key'), false);
});

Deno.test('isAuthorizedCronCaller rejects when the service-role key is unset', () => {
  const req = new Request('https://example.com', {
    headers: { Authorization: 'Bearer secret-key' },
  });
  assertEquals(isAuthorizedCronCaller(req, undefined), false);
});
