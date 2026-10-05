import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';

// The one definition of "which photos are being ranked": uploaded, not
// suppressed, and either kept or not yet decided in the cull (undecided photos
// stay rankable so a "Rank only" session works). Dropped photos are out.
//
// next-pair and session-status both size the coverage floor and the comparison
// budget from this pool rather than from `sessions.photo_count` (the whole
// batch), so a 30% cull shrinks what the engine asks of the user.

// Fetches every candidate for the pool: everything but suppressed and dropped
// photos. Upload status is applied in `splitRankedPool` rather than here so the
// same rows also say how many photos are still on their way into the pool.
export function selectRankablePhotos(
  supabase: SupabaseClient,
  sessionId: string,
  columns: string,
) {
  return supabase
    .from('photos')
    .select(`${columns}, upload_status`)
    .eq('session_id', sessionId)
    .eq('is_suppressed', false)
    .or('cull_decision.is.null,cull_decision.eq.keep');
}

export type RankedPool<Row> = {
  // Uploaded photos: the ones that can actually be shown in a comparison.
  photos: Row[];
  // Rankable photos that haven't finished uploading yet.
  incoming: number;
  // Final size of the pool once uploads land. The coverage floor and budget use
  // this, not `photos.length`: ranking starts while the batch is still
  // uploading, and sizing from the few photos uploaded so far would let a
  // session finish after a handful of taps with most of the batch unranked.
  expectedSize: number;
};

// `Row` is the shape of the columns passed to selectRankablePhotos. The select
// string is a runtime value, so supabase-js can't infer it (same as
// requireSession) - callers assert the shape they asked for.
export function splitRankedPool<Row>(rows: unknown[] | null): RankedPool<Row> {
  const photos: Row[] = [];
  let incoming = 0;
  for (const row of (rows ?? []) as (Row & { upload_status: string })[]) {
    if (row.upload_status === 'uploaded') {
      const { upload_status: _status, ...photo } = row;
      photos.push(photo as Row);
    } else {
      incoming++;
    }
  }
  return { photos, incoming, expectedSize: photos.length + incoming };
}
