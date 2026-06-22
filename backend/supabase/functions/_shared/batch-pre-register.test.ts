import { assertEquals } from 'jsr:@std/assert@1';
import { BatchPreRegisterBody } from './batch-pre-register.ts';

Deno.test('BatchPreRegisterBody accepts valid session_id and photo_ids', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: [
      'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'ffffffff-0000-1111-2222-333333333333',
    ],
  });
  assertEquals(result.success, true);
});

Deno.test('BatchPreRegisterBody rejects non-UUID photo_ids', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: ['not-a-uuid'],
  });
  assertEquals(result.success, false);
});

Deno.test('BatchPreRegisterBody rejects empty photo_ids array', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: [],
  });
  assertEquals(result.success, false);
});

Deno.test('BatchPreRegisterBody rejects more than 300 photo_ids', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: Array.from(
      { length: 301 },
      () => '11111111-2222-3333-4444-555555555555',
    ),
  });
  assertEquals(result.success, false);
});

Deno.test('BatchPreRegisterBody rejects missing session_id', () => {
  const result = BatchPreRegisterBody.safeParse({
    photo_ids: ['aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'],
  });
  assertEquals(result.success, false);
});
