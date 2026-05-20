import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({ session_id: z.string().uuid() });

// Tunable constants — adjust empirically
const BOUNDARY_ALPHA = 1;
const WEIGHTS_POST   = { elo: 0.40, overlap: 0.20, fresh: 0.20, repeat: 0.15, cluster: 0.05 };
const WEIGHTS_COVER  = { elo: 0.30, overlap: 0.15, fresh: 0.50, repeat: 0.05, cluster: 0.00 };

type Photo = {
  id: string;
  storage_path: string;
  thumbnail_path: string | null;
  elo_rating: number;
  uncertainty: number;
  comparison_count: number;
  cluster_id: string | null;
};

type CompletedComparison = { photo_a_id: string; photo_b_id: string };

function computeTopK(n: number): number {
  return Math.min(40, Math.max(5, Math.round(2.5 * Math.sqrt(n))));
}

function computeMinComparisons(n: number, topK: number): number {
  return Math.max(1, Math.ceil(Math.log2(n / topK) + 1));
}

function pairKey(a: string, b: string): string {
  return [a, b].sort().join(':');
}

function buildPairCounts(comparisons: CompletedComparison[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const c of comparisons) {
    const key = pairKey(c.photo_a_id, c.photo_b_id);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function pickRandom<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)]!;
}

function selectPhotoA(photos: Photo[], topK: number, minComparisons: number): Photo {
  // Coverage floor: under-compared photos always win
  const under = photos.filter((p) => p.comparison_count < minComparisons);
  if (under.length > 0) {
    const minCount = Math.min(...under.map((p) => p.comparison_count));
    return pickRandom(under.filter((p) => p.comparison_count === minCount));
  }

  // Priority = uncertainty × boundary weight (α=1, symmetric around topK)
  const byElo = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const rankOf = new Map(byElo.map((p, i) => [p.id, i + 1]));

  let best = -Infinity;
  let pool: Photo[] = [];
  for (const p of photos) {
    const rank = rankOf.get(p.id)!;
    const score = p.uncertainty * Math.exp(-BOUNDARY_ALPHA * Math.abs(rank - topK) / topK);
    if (score > best) { best = score; pool = [p]; }
    else if (score === best) pool.push(p);
  }
  return pickRandom(pool);
}

function selectPhotoB(
  photos: Photo[],
  photoA: Photo,
  pairCounts: Map<string, number>,
  inCoverage: boolean,
): Photo {
  const candidates = photos.filter((p) => p.id !== photoA.id);
  const w = inCoverage ? WEIGHTS_COVER : WEIGHTS_POST;

  const maxEloDiff = Math.max(...candidates.map((c) => Math.abs(c.elo_rating - photoA.elo_rating)), 1);
  const maxCount   = Math.max(...candidates.map((c) => c.comparison_count), 1);

  let best = -Infinity;
  let bestB = candidates[0]!;
  for (const b of candidates) {
    const eloSim  = 1 - Math.abs(b.elo_rating - photoA.elo_rating) / maxEloDiff;
    const overlap = (b.uncertainty + photoA.uncertainty) / 700;
    const fresh   = 1 - b.comparison_count / maxCount;
    const count   = pairCounts.get(pairKey(photoA.id, b.id)) ?? 0;
    const repeat  = Math.exp(-count);
    const cluster = !b.cluster_id || !photoA.cluster_id || b.cluster_id !== photoA.cluster_id ? 1 : 0;

    const score = w.elo * eloSim + w.overlap * overlap + w.fresh * fresh
                + w.repeat * repeat + w.cluster * cluster;

    if (score > best) { best = score; bestB = b; }
  }
  return bestB;
}

function isBoundaryStable(photos: Photo[], topK: number): boolean {
  if (photos.length <= topK) return true;
  const byElo      = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const boundary   = byElo[topK - 1]!;
  const contenders = byElo.slice(topK, Math.min(topK + 3, byElo.length));
  return !contenders.some(
    (c) => Math.abs(c.elo_rating - boundary.elo_rating) < (c.uncertainty + boundary.uncertainty) * 0.5,
  );
}

function totalComparisons(photos: Photo[]): number {
  return photos.reduce((s, p) => s + p.comparison_count, 0) / 2;
}

function computeProgress(photos: Photo[], topK: number): number {
  const byElo    = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const boundary = byElo[Math.min(topK - 1, byElo.length - 1)]!;
  return Math.min(1, 1 - boundary.uncertainty / 350);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const url    = new URL(req.url);
  const parsed = QuerySchema.safeParse({ session_id: url.searchParams.get('session_id') });
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } },
  );

  const { session_id } = parsed.data;

  // 1. Fetch session
  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id, stage, photo_count, top_k')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: 'Session not found' }), {
      status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Already marked complete (e.g. by session-status)
  if (session.stage === 'complete') {
    return new Response(JSON.stringify({ error: 'Session already complete' }), {
      status: 422, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 2. Fetch non-suppressed photos
  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id')
    .eq('session_id', session_id)
    .eq('is_suppressed', false);

  if (photosError) {
    return new Response(JSON.stringify({ error: photosError.message }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (!photos || photos.length < 2) {
    return new Response(JSON.stringify({ error: 'Not enough photos to compare' }), {
      status: 422, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const topK           = session.top_k ?? computeTopK(session.photo_count);
  const minComparisons = computeMinComparisons(session.photo_count, topK);

  // 3. Fetch completed comparisons upfront (pair counts + coverage check)
  const { data: rawComparisons } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id')
    .eq('session_id', session_id)
    .not('completed_at', 'is', null);

  const comparisons = (rawComparisons ?? []) as CompletedComparison[];
  const pairCounts  = buildPairCounts(comparisons);

  // 4. Check completion (safety net — session-status also writes this)
  const allHaveCoverage = photos.every((p) => p.comparison_count >= minComparisons);
  const stable          = isBoundaryStable(photos, topK);
  const exhausted       = totalComparisons(photos) >= session.photo_count * 4;

  if ((allHaveCoverage && stable) || exhausted) {
    await supabase.from('sessions').update({ stage: 'complete' }).eq('id', session_id);
    return new Response(JSON.stringify({ error: 'Session complete' }), {
      status: 422, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 5. Select Photo A and Photo B
  const inCoverage = !allHaveCoverage;
  const photoA     = selectPhotoA(photos, topK, minComparisons);
  const photoB     = selectPhotoB(photos, photoA, pairCounts, inCoverage);

  // 6. Generate signed URLs (1-hour expiry)
  const [signedA, signedB] = await Promise.all([
    supabase.storage.from('working-copies').createSignedUrl(photoA.storage_path, 3600),
    supabase.storage.from('working-copies').createSignedUrl(photoB.storage_path, 3600),
  ]);

  if (!signedA.data?.signedUrl || !signedB.data?.signedUrl) {
    return new Response(JSON.stringify({ error: 'Failed to generate photo URLs' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 7. Insert pending comparison record
  const { data: comparison, error: compError } = await supabase
    .from('comparisons')
    .insert({ session_id, photo_a_id: photoA.id, photo_b_id: photoB.id })
    .select('id')
    .single();

  if (compError || !comparison) {
    return new Response(JSON.stringify({ error: 'Failed to create comparison' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(
    JSON.stringify({
      comparison_id: comparison.id,
      stage: 'ranking',
      progress: computeProgress(photos, topK),
      photo_a: { ...photoA, signed_url: signedA.data.signedUrl },
      photo_b: { ...photoB, signed_url: signedB.data.signedUrl },
    }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
  );
});
