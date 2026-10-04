import { assertEquals } from 'jsr:@std/assert@1';
import { CreateSessionBody, resolveExistingSession } from './create-session.ts';

Deno.test('CreateSessionBody accepts a body without session_id', () => {
  assertEquals(CreateSessionBody.safeParse({ photo_count: 10 }).success, true);
});

Deno.test('CreateSessionBody accepts a UUID session_id', () => {
  const result = CreateSessionBody.safeParse({
    photo_count: 10,
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
  });
  assertEquals(result.success, true);
});

Deno.test('CreateSessionBody rejects a non-UUID session_id', () => {
  const result = CreateSessionBody.safeParse({ photo_count: 10, session_id: 'nope' });
  assertEquals(result.success, false);
});

Deno.test('CreateSessionBody still enforces the photo_count bounds', () => {
  assertEquals(CreateSessionBody.safeParse({ photo_count: 1 }).success, false);
  assertEquals(CreateSessionBody.safeParse({ photo_count: 301 }).success, false);
});

Deno.test('resolveExistingSession reuses a row with the same photo_count', () => {
  assertEquals(resolveExistingSession({ photo_count: 253 }, 253), 'reuse');
});

Deno.test('resolveExistingSession conflicts when the photo_count differs', () => {
  assertEquals(resolveExistingSession({ photo_count: 253 }, 100), 'conflict');
});

Deno.test('resolveExistingSession conflicts when the row is not visible to the caller', () => {
  assertEquals(resolveExistingSession(null, 253), 'conflict');
});
