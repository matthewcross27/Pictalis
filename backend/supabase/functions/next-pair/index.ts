import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import {
  type CompletedComparison,
  computeMinComparisons,
  computeTopK,
  isBoundaryStable,
  type Photo,
} from '../_shared/ranking-logic.ts';
import {
  buildPairCounts,
  computeProgress,
  pairKey,
  selectPhotoA,
  selectPhotoB,
  totalComparisons,
} from '../_shared/pair-selection.ts';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({ session_id: z.string().uuid() });

Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

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
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // Already marked complete (e.g. by session-status)
    if (session.stage === 'complete') {
      return new Response(JSON.stringify({ error: 'Session already complete' }), {
        status: 422,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // 2. Fetch non-suppressed, non-dropped photos
    const { data: photos, error: photosError } = await supabase
      .from('photos')
      .select(
        'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id',
      )
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .eq('upload_status', 'uploaded')
      .or('cull_decision.is.null,cull_decision.eq.keep');

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

    const topK = session.top_k ?? computeTopK(session.photo_count);
    const minComparisons = computeMinComparisons(session.photo_count, topK);

    // 3. Fetch all comparisons (pending + completed) for pair-count deduplication.
    // Pending comparisons (completed_at IS NULL) are hard-excluded from re-selection.
    const { data: rawComparisons } = await supabase
      .from('comparisons')
      .select('photo_a_id, photo_b_id, completed_at')
      .eq('session_id', session_id);

    type RawComparison = CompletedComparison & { completed_at: string | null };
    const allComparisons = (rawComparisons ?? []) as RawComparison[];
    const pairCounts = buildPairCounts(allComparisons);
    const pendingPairs = new Set(
      allComparisons
        .filter((c) => !c.completed_at)
        .map((c) => pairKey(c.photo_a_id, c.photo_b_id)),
    );

    // 4. Check completion (safety net — session-status also writes this)
    // Guard against vacuous truth: [].every(...) === true in JS (photos.length < 2 already guarded above)
    const allHaveCoverage = photos.every((p) => p.comparison_count >= minComparisons);
    const stable = isBoundaryStable(photos as Photo[], topK);
    const exhausted = totalComparisons(photos as Photo[]) >= session.photo_count * 4;

    if ((allHaveCoverage && stable) || exhausted) {
      await supabase.from('sessions').update({ stage: 'complete' }).eq('id', session_id);
      return new Response(JSON.stringify({ error: 'Session complete' }), {
        status: 422,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // 5. Select Photo A and Photo B
    const inCoverage = !allHaveCoverage;
    const photoA = selectPhotoA(photos as Photo[], topK, minComparisons);
    const photoB = selectPhotoB(photos as Photo[], photoA, pairCounts, inCoverage, pendingPairs);

    // 6. Generate signed URLs (1-hour expiry)
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

    // 7. Insert pending comparison record
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
        stage: session.stage,
        progress: computeProgress(photos as Photo[], topK),
        photo_a: { ...photoA, signed_url: signedA.data.signedUrl },
        photo_b: { ...photoB, signed_url: signedB.data.signedUrl },
      }),
      { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
