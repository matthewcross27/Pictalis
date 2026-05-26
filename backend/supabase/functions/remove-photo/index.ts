import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const Body = z.object({
  session_id: z.string().uuid(),
  photo_id:   z.string().uuid(),
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } },
  );

  let body: unknown;
  try { body = await req.json(); }
  catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const parsed = Body.safeParse(body);
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { session_id, photo_id } = parsed.data;

  // RLS ensures the photo belongs to a session owned by the calling user.
  const { data, error } = await supabase
    .from('photos')
    .update({ is_suppressed: true })
    .eq('id', photo_id)
    .eq('session_id', session_id)
    .eq('is_suppressed', false) // idempotency guard
    .select('id')
    .single();

  if (error || !data) {
    return new Response(JSON.stringify({ error: 'Photo not found or already removed' }), {
      status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Delete open comparison rows involving this photo so the partner can be re-paired.
  await supabase
    .from('comparisons')
    .delete()
    .eq('session_id', session_id)
    .is('completed_at', null)
    .or(`photo_a_id.eq.${data.id},photo_b_id.eq.${data.id}`);

  return new Response(
    JSON.stringify({ photo_id: data.id }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
  );
});
