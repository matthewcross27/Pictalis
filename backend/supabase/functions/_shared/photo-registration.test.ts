import { assertEquals } from 'jsr:@std/assert@1';
import {
  BATCH_REGISTER_MAX,
  BatchRegisterPhotosBody,
  buildBatchResults,
  listAllFilenames,
  RegisterPhotoBody,
  splitByStoragePath,
  STORAGE_LIST_PAGE_SIZE,
} from './photo-registration.ts';

const VALID_PATH =
  '11111111-2222-3333-4444-555555555555/66666666-7777-8888-9999-aaaaaaaaaaaa/photo.jpg';

Deno.test('RegisterPhotoBody rejects a body without photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
  });
  assertEquals(result.success, false);
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
    photo_id: 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',
  });
  assertEquals(result.success, false);
});

const UID = '11111111-2222-3333-4444-555555555555';
const SID = '66666666-7777-8888-9999-aaaaaaaaaaaa';

function photoId(n: number): string {
  return `00000000-0000-4000-8000-${n.toString().padStart(12, '0')}`;
}

function batchPhoto(n: number, uid = UID, sid = SID) {
  return { photo_id: photoId(n), storage_path: `${uid}/${sid}/${photoId(n)}.jpg` };
}

Deno.test('BatchRegisterPhotosBody accepts a valid batch', () => {
  const result = BatchRegisterPhotosBody.safeParse({
    session_id: SID,
    photos: [batchPhoto(1), batchPhoto(2)],
  });
  assertEquals(result.success, true);
});

Deno.test('BatchRegisterPhotosBody rejects an empty batch', () => {
  assertEquals(
    BatchRegisterPhotosBody.safeParse({ session_id: SID, photos: [] }).success,
    false,
  );
});

Deno.test('BatchRegisterPhotosBody caps the batch at the session photo cap', () => {
  const photos = (n: number) => Array.from({ length: n }, (_, i) => batchPhoto(i + 1));
  assertEquals(
    BatchRegisterPhotosBody.safeParse({ session_id: SID, photos: photos(BATCH_REGISTER_MAX) })
      .success,
    true,
  );
  assertEquals(
    BatchRegisterPhotosBody.safeParse({
      session_id: SID,
      photos: photos(BATCH_REGISTER_MAX + 1),
    }).success,
    false,
  );
});

Deno.test('BatchRegisterPhotosBody rejects duplicate photo ids and malformed entries', () => {
  assertEquals(
    BatchRegisterPhotosBody.safeParse({
      session_id: SID,
      photos: [batchPhoto(1), batchPhoto(1)],
    }).success,
    false,
  );
  assertEquals(
    BatchRegisterPhotosBody.safeParse({
      session_id: SID,
      photos: [{ photo_id: photoId(1), storage_path: 'nope.jpg' }],
    }).success,
    false,
  );
  assertEquals(
    BatchRegisterPhotosBody.safeParse({
      session_id: SID,
      photos: [{ photo_id: 'not-a-uuid', storage_path: batchPhoto(1).storage_path }],
    }).success,
    false,
  );
});

Deno.test('splitByStoragePath rejects only photos whose path has the wrong user or session', () => {
  const good = batchPhoto(1);
  const wrongUser = batchPhoto(2, 'ffffffff-2222-3333-4444-555555555555');
  const wrongSession = batchPhoto(3, UID, 'ffffffff-7777-8888-9999-aaaaaaaaaaaa');
  const { candidates, rejected } = splitByStoragePath([good, wrongUser, wrongSession], UID, SID);
  assertEquals(candidates, [good]);
  assertEquals(rejected, [
    { photo_id: wrongUser.photo_id, success: false, error: 'invalid_storage_path' },
    { photo_id: wrongSession.photo_id, success: false, error: 'invalid_storage_path' },
  ]);
});

// A fake storage folder that, like Supabase Storage, returns at most `limit`
// entries starting at `offset`.
function fakeFolder(names: string[]) {
  const calls: { limit: number; offset: number }[] = [];
  const listPage = ({ limit, offset }: { limit: number; offset: number }) => {
    calls.push({ limit, offset });
    return Promise.resolve({
      data: names.slice(offset, offset + limit).map((name) => ({ name })),
      error: null,
    });
  };
  return { listPage, calls };
}

Deno.test('listAllFilenames pages past the first page for folders over the page size', async () => {
  const names = Array.from({ length: STORAGE_LIST_PAGE_SIZE + 250 }, (_, i) => `${i}.jpg`);
  const { listPage, calls } = fakeFolder(names);
  const found = await listAllFilenames(listPage);
  assertEquals(found.size, names.length);
  assertEquals(found.has(`${STORAGE_LIST_PAGE_SIZE + 249}.jpg`), true);
  assertEquals(calls.map((c) => c.offset), [0, STORAGE_LIST_PAGE_SIZE]);
});

Deno.test('listAllFilenames uses a single call for a small folder', async () => {
  const { listPage, calls } = fakeFolder(['a.jpg', 'b.jpg']);
  assertEquals(await listAllFilenames(listPage), new Set(['a.jpg', 'b.jpg']));
  assertEquals(calls.length, 1);
});

Deno.test('listAllFilenames throws when a page fails instead of reporting files as missing', async () => {
  let threw = false;
  try {
    await listAllFilenames(() => Promise.resolve({ data: null, error: new Error('boom') }));
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});

Deno.test('buildBatchResults reports each photo in request order with its own outcome', () => {
  const ok = batchPhoto(1);
  const noObject = batchPhoto(2);
  const noRow = batchPhoto(3);
  const badPath = batchPhoto(4, 'ffffffff-2222-3333-4444-555555555555');
  const photos = [ok, noObject, noRow, badPath];
  const { rejected } = splitByStoragePath(photos, UID, SID);

  const results = buildBatchResults(
    photos,
    rejected,
    new Set([`${ok.photo_id}.jpg`, `${noRow.photo_id}.jpg`]),
    new Set([ok.photo_id]),
  );

  assertEquals(results, [
    { photo_id: ok.photo_id, success: true },
    { photo_id: noObject.photo_id, success: false, error: 'storage_object_not_found' },
    { photo_id: noRow.photo_id, success: false, error: 'photo_not_found' },
    { photo_id: badPath.photo_id, success: false, error: 'invalid_storage_path' },
  ]);
});
