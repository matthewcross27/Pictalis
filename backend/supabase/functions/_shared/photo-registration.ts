import { z } from 'npm:zod@3';

const UUID_RE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
export const STORAGE_PATH_RE = new RegExp(`^${UUID_RE}/${UUID_RE}/[^/]+$`, 'i');

export const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().regex(STORAGE_PATH_RE, 'Must match {uid}/{session_id}/{filename}'),
  photo_id: z.string().uuid().optional(),
});

// Postgres unique_violation — a retry of a register that already succeeded.
export function isUniqueViolation(error: { code?: string } | null): boolean {
  return error?.code === '23505';
}
