import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({ session_id: z.string().uuid() });

function computeTopK(n: number): number {
  return Math.min(40, Math.max(5, Math.round(2.5 * Math.sqrt(n))));
}

function computeMinComparisons(n: number, topK: number): number {
  return Math.max(1, Math.ceil(Math.log2(n / topK) + 1));
}

function isBoundaryStable(
  photos: { elo_rating: number; uncertainty: number; comparison_count: number }[],
  topK: number,
): boolean {
  if (photos.length <= topK) return true;
  const byElo      = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const boundary   = byElo[topK - 1]!;
  const contenders = byElo.slice(topK, Math.min(topK + 3, byElo.length));
  return !contenders.some(
    (c) => Math.abs(c.elo_rating - boundary.elo_rating) < (c.uncertainty + boundary.uncertainty) * 0.5,
  );
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

  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('comparison_count, elo_rating, uncertainty')
    .eq('session_id', session_id)
    .eq('is_suppressed', false);

  if (photosError) {
    return new Response(JSON.stringify({ error: 'Failed to fetch photos' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const photoList      = photos ?? [];
  const topK           = session.top_k ?? computeTopK(session.photo_count);
  const minComparisons = computeMinComparisons(session.photo_count, topK);
  const totalComps     = Math.round(photoList.reduce((s, p) => s + p.comparison_count, 0) / 2);

  // Detect and persist completion
  let currentStage = session.stage as string;
  if (currentStage !== 'complete') {
    const allHaveCoverage = photoList.every((p) => p.comparison_count >= minComparisons);
    const stable          = isBoundaryStable(photoList, topK);
    const exhausted       = totalComps >= session.photo_count * 4;
    if ((allHaveCoverage && stable) || exhausted) {
      currentStage = 'complete';
      await supabase.from('sessions').update({ stage: 'complete' }).eq('id', session_id);
    }
  }

  return new Response(
    JSON.stringify({
      stage: currentStage,
      is_complete: currentStage === 'complete',
      top_photo_count: topK,
      total_comparisons: totalComps,
    }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
  );
});
