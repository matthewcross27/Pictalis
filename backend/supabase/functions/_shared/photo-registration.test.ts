import { assertEquals } from 'jsr:@std/assert@1';
import { isUniqueViolation, RegisterPhotoBody } from './photo-registration.ts';

const VALID_PATH =
  '11111111-2222-3333-4444-555555555555/66666666-7777-8888-9999-aaaaaaaaaaaa/photo.jpg';

Deno.test('RegisterPhotoBody accepts a body without photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
  });
  assertEquals(result.success, true);
});

Deno.test('RegisterPhotoBody accepts a valid photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
    photo_id: 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',
  });
  assertEquals(result.success, true);
});

Deno.test('RegisterPhotoBody rejects a non-UUID photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
    photo_id: 'not-a-uuid',
  });
  assertEquals(result.success, false);
});

Deno.test('RegisterPhotoBody rejects a malformed storage_path', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: 'just-a-filename.jpg',
  });
  assertEquals(result.success, false);
});

Deno.test('isUniqueViolation detects Postgres code 23505', () => {
  assertEquals(isUniqueViolation({ code: '23505' }), true);
  assertEquals(isUniqueViolation({ code: '42P01' }), false);
  assertEquals(isUniqueViolation(null), false);
});
