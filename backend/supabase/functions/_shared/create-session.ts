import { z } from 'npm:zod@3';

export const CreateSessionBody = z.object({
  photo_count: z.number().int().min(2).max(300),
  // Client-generated id. Lets the client safely repeat the call after a
  // dropped connection: a repeat resolves to the row the first call created
  // instead of inserting a second (orphaned) session.
  session_id: z.string().uuid().optional(),
});

// Postgres unique_violation, raised when the supplied session_id is taken.
export const UNIQUE_VIOLATION = '23505';

export interface ExistingSession {
  photo_count: number;
}

export type ExistingSessionOutcome = 'reuse' | 'conflict';

// Decides what a repeated create-session call with an already-used session_id
// should do. `existing` is read under the caller's RLS, so null means the id
// belongs to someone else (or vanished), which is a conflict, never a reuse.
// A different photo_count means this is not a repeat of the original call.
export function resolveExistingSession(
  existing: ExistingSession | null,
  requestedPhotoCount: number,
): ExistingSessionOutcome {
  if (existing && existing.photo_count === requestedPhotoCount) return 'reuse';
  return 'conflict';
}
