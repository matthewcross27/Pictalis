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
  const parsed = QuerySchema.safeParse({
    session_id: url.searchParams.get('session_id'),
  });
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

  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('id, storage_path, thumbnail_path, elo_rating, comparison_count')
    .eq('session_id', session_id)
    .eq('is_suppressed', false)
    .order('comparison_count', { ascending: true });

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

  // Photo A: fewest comparisons, random tiebreak
  const minCount = photos[0]!.comparison_count;
  const aPool = photos.filter((p) => p.comparison_count === minCount);
  const photoA = aPool[Math.floor(Math.random() * aPool.length)]!;

  // Find which photos have already been paired with A
  const { data: priorComparisons } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id')
    .eq('session_id', session_id)
    .or(`photo_a_id.eq.${photoA.id},photo_b_id.eq.${photoA.id}`);

  const seenWithA = new Set<string>();
  for (const c of priorComparisons ?? []) {
    seenWithA.add(c.photo_a_id === photoA.id ? c.photo_b_id : c.photo_a_id);
  }

  // Photo B: fewest comparisons among photos not yet paired with A
  const eligible = photos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
  const bPool = eligible.length > 0 ? eligible : photos.filter((p) => p.id !== photoA.id);
  const photoB = bPool[Math.floor(Math.random() * bPool.length)]!;

  // Generate signed URLs (1-hour expiry)
  const [signedA, signedB] = await Promise.all([
    supabase.storage.from('working-copies').createSignedUrl(photoA.storage_path, 3600),
    supabase.storage.from('working-copies').createSignedUrl(photoB.storage_path, 3600),
  ]);

  // Create a pending comparison record
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
      photo_a: { ...photoA, signed_url: signedA.data?.signedUrl ?? null },
      photo_b: { ...photoB, signed_url: signedB.data?.signedUrl ?? null },
    }),
    {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    }
  );
});
