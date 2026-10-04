import { z } from 'npm:zod@3';

const UUID_RE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
export const STORAGE_PATH_RE = new RegExp(`^${UUID_RE}/${UUID_RE}/[^/]+$`, 'i');

export const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().regex(
    STORAGE_PATH_RE,
    'Must match {uid}/{session_id}/{filename}',
  ),
  photo_id: z.string().uuid(),
});

// Matches the session's photo_count cap (create-session / batch-pre-register).
export const BATCH_REGISTER_MAX = 300;

export const BatchRegisterPhotosBody = z.object({
  session_id: z.string().uuid(),
  photos: z.array(z.object({
    photo_id: z.string().uuid(),
    storage_path: z.string().regex(
      STORAGE_PATH_RE,
      'Must match {uid}/{session_id}/{filename}',
    ),
  })).min(1).max(BATCH_REGISTER_MAX),
}).refine(
  (body) => new Set(body.photos.map((p) => p.photo_id)).size === body.photos.length,
  { message: 'photo_id values must be unique within a batch', path: ['photos'] },
);

export type BatchRegisterPhoto = z.infer<typeof BatchRegisterPhotosBody>['photos'][number];

export type BatchRegisterResult =
  | { photo_id: string; success: true }
  | { photo_id: string; success: false; error: BatchRegisterError };

export type BatchRegisterError =
  | 'invalid_storage_path'
  | 'storage_object_not_found'
  | 'photo_not_found';

// Splits a batch into the photos whose storage_path is consistent with the
// authenticated user + session (worth checking against storage and the DB)
// and per-photo rejections for the rest. A bad path on one photo must not
// block the others in the same request.
export function splitByStoragePath(
  photos: BatchRegisterPhoto[],
  userId: string,
  sessionId: string,
): { candidates: BatchRegisterPhoto[]; rejected: BatchRegisterResult[] } {
  const candidates: BatchRegisterPhoto[] = [];
  const rejected: BatchRegisterResult[] = [];
  for (const photo of photos) {
    const [pathUid, pathSessionId] = photo.storage_path.split('/');
    if (pathUid !== userId || pathSessionId !== sessionId) {
      rejected.push({
        photo_id: photo.photo_id,
        success: false,
        error: 'invalid_storage_path',
      });
    } else {
      candidates.push(photo);
    }
  }
  return { candidates, rejected };
}

// Storage's list() returns at most `limit` entries per call (100 by default),
// so a folder with more files than that has to be paged through - a single
// default call would report every photo past the first page as missing.
export const STORAGE_LIST_PAGE_SIZE = 1000;
// Safety bound: a session folder holds at most photo_count (<= 300) objects.
const STORAGE_LIST_MAX_PAGES = 20;

export type StorageListPage = (
  options: { limit: number; offset: number },
) => Promise<{ data: { name: string }[] | null; error: unknown }>;

// Returns the filenames in one storage folder, paging through all of it.
// Throws if a page fails to load, so the caller can fail the whole batch
// (retryable) instead of misreporting photos as missing.
export async function listAllFilenames(listPage: StorageListPage): Promise<Set<string>> {
  const names = new Set<string>();
  for (let page = 0; page < STORAGE_LIST_MAX_PAGES; page++) {
    const { data, error } = await listPage({
      limit: STORAGE_LIST_PAGE_SIZE,
      offset: page * STORAGE_LIST_PAGE_SIZE,
    });
    if (error || !data) {
      throw error instanceof Error ? error : new Error(`Storage list failed: ${String(error)}`);
    }
    for (const entry of data) names.add(entry.name);
    if (data.length < STORAGE_LIST_PAGE_SIZE) return names;
  }
  throw new Error('Storage folder exceeds the expected maximum size');
}

// Builds the per-photo response, in request order, from the three possible
// outcomes: rejected up front, missing from storage, or the set of ids the
// batch UPDATE actually matched.
export function buildBatchResults(
  photos: BatchRegisterPhoto[],
  rejected: BatchRegisterResult[],
  storageFilenames: Set<string>,
  registeredIds: Set<string>,
): BatchRegisterResult[] {
  const rejectedById = new Map(rejected.map((r) => [r.photo_id, r]));
  return photos.map((photo): BatchRegisterResult => {
    const early = rejectedById.get(photo.photo_id);
    if (early) return early;
    const filename = photo.storage_path.split('/')[2];
    if (!storageFilenames.has(filename)) {
      return { photo_id: photo.photo_id, success: false, error: 'storage_object_not_found' };
    }
    if (!registeredIds.has(photo.photo_id)) {
      return { photo_id: photo.photo_id, success: false, error: 'photo_not_found' };
    }
    return { photo_id: photo.photo_id, success: true };
  });
}
