import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({ session_id: z.string().uuid() });

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

    const { data: photos, error: photosError } = await supabase
      .from('photos')
      .select('id, storage_path, cluster_id, quality_flags')
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .is('cull_decision', null)
      .order('cluster_id')
      .order('id');

    if (photosError) {
      return new Response(JSON.stringify({ error: photosError.message }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    if (!photos || photos.length === 0) {
      await supabase.from('sessions').update({ stage: 'ranking' }).eq('id', session_id);
      return new Response(JSON.stringify({ done: true }), {
        status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

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

    const groups        = [...clusters.values()];
    const cardsRemaining = groups.length;
    const next          = groups[0];
    const rep           = next.representative;

    const { data: signed, error: urlError } = await supabase.storage
      .from('working-copies')
      .createSignedUrl(rep.storage_path, 3600);

    if (urlError || !signed?.signedUrl) {
      return new Response(JSON.stringify({ error: 'Failed to generate photo URL' }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(
      JSON.stringify({
        done: false,
        photo_id: rep.id,
        photo_url: signed.signedUrl,
        cluster_id: rep.cluster_id,
        cluster_size: next.count,
        cards_remaining: cardsRemaining,
      }),
      { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
