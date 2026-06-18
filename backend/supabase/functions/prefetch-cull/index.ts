import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BodySchema = z.object({
  session_id: z.string().uuid(),
  count: z.number().int().min(1).max(50),
  exclude_ids: z.array(z.string().uuid()).max(500).default([]),
});

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

    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const parsed = BodySchema.safeParse(body);
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

    const { session_id, count, exclude_ids } = parsed.data;

    const { data: session, error: sessionError } = await supabase
      .from('sessions')
      .select('upload_complete')
      .eq('id', session_id)
      .single();

    if (sessionError || !session) {
      return new Response(JSON.stringify({ error: 'Session not found' }), {
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const { data: photos, error: photosError } = await supabase
      .from('photos')
      .select('id, storage_path')
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .is('cull_decision', null)
      .order('id');

    if (photosError) {
      return new Response(JSON.stringify({ error: photosError.message }), {
        status: 500,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    if (!photos || photos.length === 0) {
      const hasMore = !session.upload_complete;
      return new Response(JSON.stringify({ cards: [], has_more: hasMore }), {
        status: 200,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const excludeSet = new Set(exclude_ids);
    const eligible = photos.filter((p) => !excludeSet.has(p.id));
    const batch = eligible.slice(0, count);
    const hasMore = !session.upload_complete || eligible.length > count;

    const cards = await Promise.all(
      batch.map(async (photo) => {
        try {
          // Plain signed URL — same pipeline as next-pair/results. Working copies
          // are already compressed and capped at 1920px on-device, so no
          // server-side transform is needed (or wanted: the transform service
          // produced cropped renditions).
          const { data: signed } = await supabase.storage
            .from('working-copies')
            .createSignedUrl(photo.storage_path, 3600);
          return { photo_id: photo.id, photo_url: signed?.signedUrl ?? null };
        } catch {
          return { photo_id: photo.id, photo_url: null };
        }
      }),
    );

    const validCards = cards.filter((c) => c.photo_url !== null);

    return new Response(JSON.stringify({ cards: validCards, has_more: hasMore }), {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
