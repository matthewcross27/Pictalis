import { timingSafeEqual } from 'jsr:@std/crypto@1/timing-safe-equal';

// Keeps each Storage API `remove()` call to a bounded batch size rather than
// sending the whole (potentially large, e.g. after a backlog) path list in
// one request.
export const STORAGE_REMOVE_CHUNK_SIZE = 500;

export function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

// This function bypasses RLS (service-role client) and deletes arbitrary
// users' storage objects/sessions, so unlike every other Edge Function here
// it must not accept a normal user JWT - verify_jwt=true only proves the
// caller has *some* valid Supabase-signed token, not that they're the
// scheduled cron job. Requiring the literal service-role key as the bearer
// token (known only to the project's Vault, which only pg_cron/pg_net reads)
// closes that gap.
export function isAuthorizedCronCaller(req: Request, serviceRoleKey: string | undefined): boolean {
  if (!serviceRoleKey) return false;
  const authorization = req.headers.get('Authorization');
  if (!authorization) return false;

  const enc = new TextEncoder();
  const expected = enc.encode(`Bearer ${serviceRoleKey}`);
  const actual = enc.encode(authorization);
  if (actual.length !== expected.length) return false;
  return timingSafeEqual(actual, expected);
}
