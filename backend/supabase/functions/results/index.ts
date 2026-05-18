import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const QuerySchema = z.object({
  session_id: z.string().uuid(),
  limit: z.coerce.number().int().min(1).max(100).default(20),
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
    limit: url.searchParams.get('limit') ?? 20,
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

  const { data: photos, error } = await supabase
    .from('photos')
    .select(
      'id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, is_suppressed, cluster_id, quality_flags'
    )
    .eq('session_id', parsed.data.session_id)
    .eq('is_suppressed', false)
    .order('elo_rating', { ascending: false })
    .limit(parsed.data.limit);

  if (error) {
    console.error('Failed to fetch photos:', error);
    return new Response(JSON.stringify({ error: 'Failed to fetch photos' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const photosWithUrls = await Promise.all(
    (photos ?? []).map(async (photo) => {
      const { data: signed, error: signedError } = await supabase.storage
        .from('working-copies')
        .createSignedUrl(photo.storage_path, 3600);
      if (signedError) throw signedError;
      return { ...photo, signed_url: signed?.signedUrl ?? null };
    })
  ).catch((err) => {
    console.error('Failed to generate signed URLs:', err);
    return null;
  });

  if (!photosWithUrls) {
    return new Response(JSON.stringify({ error: 'Failed to generate photo URLs' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ photos: photosWithUrls }), {
    status: 200,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
