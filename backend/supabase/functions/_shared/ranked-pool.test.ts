import { assertEquals } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';
import { selectRankablePhotos, splitRankedPool } from './ranked-pool.ts';

// Records the PostgREST filter chain selectRankablePhotos builds, so the pool
// definition is asserted against the query the edge functions actually send.
function recordingClient() {
  const calls: [string, ...unknown[]][] = [];
  const query = {
    select(columns: string) {
      calls.push(['select', columns]);
      return query;
    },
    eq(column: string, value: unknown) {
      calls.push(['eq', column, value]);
      return query;
    },
    or(filter: string) {
      calls.push(['or', filter]);
      return query;
    },
  };
  const client = {
    from(table: string) {
      calls.push(['from', table]);
      return query;
    },
  };
  return { client: client as unknown as SupabaseClient, calls };
}

Deno.test('selectRankablePhotos — excludes suppressed and dropped photos, keeps undecided', () => {
  const { client, calls } = recordingClient();
  selectRankablePhotos(client, 'session-1', 'id, elo_rating');
  assertEquals(calls, [
    ['from', 'photos'],
    ['select', 'id, elo_rating, upload_status'],
    ['eq', 'session_id', 'session-1'],
    ['eq', 'is_suppressed', false],
    ['or', 'cull_decision.is.null,cull_decision.eq.keep'],
  ]);
});

Deno.test('splitRankedPool — only uploaded photos are ranked, and upload_status is stripped', () => {
  const pool = splitRankedPool<{ id: string }>([
    { id: 'a', upload_status: 'uploaded' },
    { id: 'b', upload_status: 'pending' },
    { id: 'c', upload_status: 'uploaded' },
  ]);
  assertEquals(pool.photos, [{ id: 'a' }, { id: 'c' }]);
  assertEquals(pool.incoming, 1);
});

Deno.test('splitRankedPool — expectedSize counts photos still uploading', () => {
  const pool = splitRankedPool<{ id: string }>([
    { id: 'a', upload_status: 'uploaded' },
    { id: 'b', upload_status: 'pending' },
    { id: 'c', upload_status: 'pending' },
  ]);
  assertEquals(pool.photos.length, 1);
  assertEquals(pool.expectedSize, 3);
});

Deno.test('splitRankedPool — null rows (query error/empty) → empty pool', () => {
  assertEquals(splitRankedPool(null), { photos: [], incoming: 0, expectedSize: 0 });
});
