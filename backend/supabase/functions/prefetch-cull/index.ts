import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BodySchema = z.object({
  session_id:      z.string().uuid(),
  count:           z.number().int().min(1).max(50),
  exclude_ids:     z.array(z.string().uuid()).default([]),
  thumbnail_width: z.number().int().min(100).max(3000),
});

type PhotoRow = {
  id: string;
  storage_path: string;
  cluster_id: string | null;
  quality_flags: Record<string, unknown> | null;
};

Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    let body: unknown;
    try { body = await req.json(); } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const parsed = BodySchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    const { session_id, count, exclude_ids, thumbnail_width } = parsed.data;

    // Gate has_more on upload completion
    const { data: session, error: sessionError } = await supabase
      .from('sessions')
      .select('upload_complete')
      .eq('id', session_id)
      .single();

    if (sessionError || !session) {
      return new Response(JSON.stringify({ error: 'Session not found' }), {
        status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // Fetch undecided, unsuppressed photos — apply exclude filter before grouping
    let query = supabase
      .from('photos')
      .select('id, storage_path, cluster_id, quality_flags')
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .is('cull_decision', null)
      .order('cluster_id')
      .order('id');

    if (exclude_ids.length > 0) {
      query = query.not('id', 'in', `(${exclude_ids.join(',')})`);
    }

    const { data: photos, error: photosError } = await query;

    if (photosError) {
      return new Response(JSON.stringify({ error: photosError.message }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    if (!photos || photos.length === 0) {
      const hasMore = !session.upload_complete;
      return new Response(JSON.stringify({ cards: [], has_more: hasMore }), {
        status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // Group by cluster; pick highest blur_score representative per cluster
    type ClusterGroup = { representative: PhotoRow; count: number; blurScore: number };
    const clusters = new Map<string, ClusterGroup>();

    for (const p of photos as PhotoRow[]) {
      const blurScore = typeof p.quality_flags?.blur_score === 'number' ? p.quality_flags.blur_score : 0;
      const clusterKey = p.cluster_id ?? p.id;
      const existing = clusters.get(clusterKey);
      if (!existing) {
        clusters.set(clusterKey, { representative: p, count: 1, blurScore });
      } else {
        existing.count++;
        if (blurScore > existing.blurScore) {
          existing.representative = p;
          existing.blurScore = blurScore;
        }
      }
    }

    const eligibleClusters = [...clusters.values()];
    const batch = eligibleClusters.slice(0, count);
    const hasMore = !session.upload_complete || eligibleClusters.length > count;

    // Generate all signed thumbnail URLs in parallel
    const cards = await Promise.all(
      batch.map(async ({ representative: rep, count: clusterSize }) => {
        const { data: signed } = await supabase.storage
          .from('working-copies')
          .createSignedUrl(rep.storage_path, 3600, {
            transform: { width: thumbnail_width, quality: 75 },
          });
        return {
          photo_id:     rep.id,
          photo_url:    signed?.signedUrl ?? null,
          cluster_id:   rep.cluster_id,
          cluster_size: clusterSize,
        };
      })
    );

    const validCards = cards.filter(c => c.photo_url !== null);

    return new Response(JSON.stringify({ cards: validCards, has_more: hasMore }), {
      status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
