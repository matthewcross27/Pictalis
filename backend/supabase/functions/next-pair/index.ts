import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({
  session_id: z.string().uuid(),
});

// Stage transition thresholds
const STAGE2_MIN_COMPARISONS = 3;
const STAGE3_TOP_N = 20;
const STAGE3_UNCERTAINTY_THRESHOLD = 100;
const COMPLETE_TOP_N = 10;
const COMPLETE_UNCERTAINTY_THRESHOLD = 50;
const COMPLETE_COMPARISON_MULTIPLIER = 3;

type Photo = {
  id: string;
  storage_path: string;
  thumbnail_path: string | null;
  elo_rating: number;
  uncertainty: number;
  comparison_count: number;
  cluster_id: string | null;
};

// Pure functions — operate on the already-fetched photo array.

function totalComparisons(photos: Photo[]): number {
  // Each comparison increments both participants' comparison_count.
  return photos.reduce((s, p) => s + p.comparison_count, 0) / 2;
}

function avgUncertainty(photos: Photo[], topN: number): number {
  const sorted = [...photos].sort((a, b) => b.elo_rating - a.elo_rating).slice(0, topN);
  if (sorted.length === 0) return Infinity;
  return sorted.reduce((s, p) => s + p.uncertainty, 0) / sorted.length;
}

function nextStage(
  current: string,
  photos: Photo[],
  photoCount: number,
): string | null {
  if (current === 'stage1') {
    const ready = photos.every((p) => p.comparison_count >= STAGE2_MIN_COMPARISONS);
    return ready ? 'stage2' : null;
  }
  if (current === 'stage2') {
    const ready = avgUncertainty(photos, STAGE3_TOP_N) < STAGE3_UNCERTAINTY_THRESHOLD;
    return ready ? 'stage3' : null;
  }
  if (current === 'stage3') {
    const converged = avgUncertainty(photos, COMPLETE_TOP_N) < COMPLETE_UNCERTAINTY_THRESHOLD;
    const exhausted = totalComparisons(photos) >= photoCount * COMPLETE_COMPARISON_MULTIPLIER;
    return converged || exhausted ? 'complete' : null;
  }
  return null;
}

function priorPartners(comparisons: { photo_a_id: string; photo_b_id: string }[], photoId: string): Set<string> {
  const seen = new Set<string>();
  for (const c of comparisons) {
    if (c.photo_a_id === photoId) seen.add(c.photo_b_id);
    if (c.photo_b_id === photoId) seen.add(c.photo_a_id);
  }
  return seen;
}

function pickRandom<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)]!;
}

function selectStage1(photos: Photo[], seenWithA: Set<string>, photoA: Photo): Photo {
  const eligible = photos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
  const pool = eligible.length > 0 ? eligible : photos.filter((p) => p.id !== photoA.id);

  // Prefer a different cluster_id than Photo A (cluster diversity in Stage 1).
  const diffCluster = pool.filter(
    (p) => !p.cluster_id || !photoA.cluster_id || p.cluster_id !== photoA.cluster_id,
  );
  const bPool = diffCluster.length > 0 ? diffCluster : pool;

  const minCount = Math.min(...bPool.map((p) => p.comparison_count));
  return pickRandom(bPool.filter((p) => p.comparison_count === minCount));
}

function selectStage2(photos: Photo[], seenWithA: Set<string>, photoA: Photo): Photo {
  const eligible = photos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
  const pool = eligible.length > 0 ? eligible : photos.filter((p) => p.id !== photoA.id);

  // Closest Elo rating to Photo A.
  return pool.reduce((best, p) =>
    Math.abs(p.elo_rating - photoA.elo_rating) < Math.abs(best.elo_rating - photoA.elo_rating)
      ? p
      : best,
  );
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const url = new URL(req.url);
  const parsed = QuerySchema.safeParse({ session_id: url.searchParams.get('session_id') });
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } }
  );

  const { session_id } = parsed.data;

  // 1. Fetch session
  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id, stage, photo_count')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: 'Session not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 2. Fetch all non-suppressed photos (includes uncertainty + cluster_id for stage logic)
  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id')
    .eq('session_id', session_id)
    .eq('is_suppressed', false)
    .order('comparison_count', { ascending: true })
    .order('elo_rating', { ascending: false });

  if (photosError) {
    return new Response(JSON.stringify({ error: photosError.message }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (!photos || photos.length < 2) {
    return new Response(JSON.stringify({ error: 'Not enough photos to compare' }), {
      status: 422,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 3. Evaluate stage transition (pure, no extra DB query).
  let currentStage = session.stage as string;
  const advanced = nextStage(currentStage, photos, session.photo_count);
  if (advanced) {
    currentStage = advanced;
    await supabase.from('sessions').update({ stage: advanced }).eq('id', session_id);
  }

  // 4. Pick Photo A based on current stage.
  let photoA: Photo;
  if (currentStage === 'stage1') {
    const minCount = photos[0]!.comparison_count;
    const aPool = photos.filter((p) => p.comparison_count === minCount);
    photoA = pickRandom(aPool);
  } else {
    // stage2, stage3, complete: highest uncertainty in top half by Elo.
    const byElo = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
    const topHalf = byElo.slice(0, Math.ceil(byElo.length / 2));
    const maxUncertainty = Math.max(...topHalf.map((p) => p.uncertainty));
    const aPool = topHalf.filter((p) => p.uncertainty === maxUncertainty);
    photoA = pickRandom(aPool);
  }

  // 5. Fetch prior comparisons for Photo A (avoid repeats).
  const { data: priorComps } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id')
    .eq('session_id', session_id)
    .or(`photo_a_id.eq.${photoA.id},photo_b_id.eq.${photoA.id}`);

  const seenWithA = priorPartners(priorComps ?? [], photoA.id);

  // 6. Pick Photo B based on stage.
  let photoB: Photo;

  if (currentStage === 'stage3') {
    // Try to find a within-cluster pair from a cluster containing a top-20 photo.
    const top20Ids = new Set(
      [...photos].sort((a, b) => b.elo_rating - a.elo_rating).slice(0, 20).map((p) => p.id),
    );
    const topClusters = [
      ...new Set(photos.filter((p) => top20Ids.has(p.id) && p.cluster_id).map((p) => p.cluster_id!)),
    ];

    let stage3B: Photo | null = null;
    for (const clusterId of topClusters) {
      const clusterPhotos = photos.filter((p) => p.cluster_id === clusterId);
      if (clusterPhotos.length < 2) continue;

      const eligible = clusterPhotos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
      if (eligible.length > 0) {
        // Override Photo A to be the top-Elo photo in this cluster.
        const clusterByElo = [...clusterPhotos].sort((a, b) => b.elo_rating - a.elo_rating);
        photoA = clusterByElo[0]!;

        const { data: clusterPriorComps } = await supabase
          .from('comparisons')
          .select('photo_a_id, photo_b_id')
          .eq('session_id', session_id)
          .or(`photo_a_id.eq.${photoA.id},photo_b_id.eq.${photoA.id}`);
        const newSeenWithA = priorPartners(clusterPriorComps ?? [], photoA.id);

        const clusterEligible = clusterPhotos.filter(
          (p) => p.id !== photoA.id && !newSeenWithA.has(p.id),
        );
        if (clusterEligible.length > 0) {
          stage3B = clusterEligible[0]!;
          for (const id of newSeenWithA) seenWithA.add(id);
          break;
        }
      }
    }
    photoB = stage3B ?? selectStage2(photos, seenWithA, photoA);
  } else if (currentStage === 'stage1') {
    photoB = selectStage1(photos, seenWithA, photoA);
  } else {
    // stage2, complete
    photoB = selectStage2(photos, seenWithA, photoA);
  }

  // 7. Generate signed URLs (1-hour expiry).
  const [signedA, signedB] = await Promise.all([
    supabase.storage.from('working-copies').createSignedUrl(photoA.storage_path, 3600),
    supabase.storage.from('working-copies').createSignedUrl(photoB.storage_path, 3600),
  ]);

  if (!signedA.data?.signedUrl || !signedB.data?.signedUrl) {
    return new Response(JSON.stringify({ error: 'Failed to generate photo URLs' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 8. Create pending comparison record.
  const { data: comparison, error: compError } = await supabase
    .from('comparisons')
    .insert({ session_id, photo_a_id: photoA.id, photo_b_id: photoB.id })
    .select('id')
    .single();

  if (compError || !comparison) {
    return new Response(JSON.stringify({ error: 'Failed to create comparison' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(
    JSON.stringify({
      comparison_id: comparison.id,
      stage: currentStage,
      photo_a: { ...photoA, signed_url: signedA.data.signedUrl },
      photo_b: { ...photoB, signed_url: signedB.data.signedUrl },
    }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
