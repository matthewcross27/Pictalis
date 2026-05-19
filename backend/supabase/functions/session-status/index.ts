import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({
  session_id: z.string().uuid(),
});

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

  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('comparison_count, elo_rating')
    .eq('session_id', session_id)
    .eq('is_suppressed', false);

  if (photosError) {
    return new Response(JSON.stringify({ error: 'Failed to fetch photos' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const totalComparisons = Math.round(
    (photos ?? []).reduce((s, p) => s + p.comparison_count, 0) / 2,
  );
  const topPhotoCount = Math.min(20, (photos ?? []).length);

  return new Response(
    JSON.stringify({
      stage: session.stage,
      is_complete: session.stage === 'complete',
      top_photo_count: topPhotoCount,
      total_comparisons: totalComparisons,
    }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
