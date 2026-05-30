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
  photo_id: z.string().uuid(),
  decision: z.enum(['keep', 'drop']),
});

Deno.serve(async (req) => {
  try {
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
      { global: { headers: { Authorization: authHeader } } }
    );

    const { session_id, photo_id, decision } = parsed.data;

    // Look up cluster_id from the given photo_id + session_id
    const { data: photo, error: photoError } = await supabase
      .from('photos')
      .select('cluster_id')
      .eq('id', photo_id)
      .eq('session_id', session_id)
      .single();

    if (photoError || !photo) {
      return new Response(JSON.stringify({ error: 'Photo not found' }), {
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const { cluster_id } = photo;

    // Apply decision to the WHOLE cluster
    const update = decision === 'keep'
      ? { cull_decision: 'keep' }
      : { cull_decision: 'drop', is_suppressed: true };

    const { error: updateError } = await supabase
      .from('photos')
      .update(update)
      .eq('cluster_id', cluster_id)
      .eq('session_id', session_id)
      .is('cull_decision', null);

    if (updateError) {
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // Count photos where is_suppressed = false AND cull_decision IS NULL
    const { count, error: countError } = await supabase
      .from('photos')
      .select('id', { count: 'exact', head: true })
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .is('cull_decision', null);

    if (countError) {
      return new Response(JSON.stringify({ error: countError.message }), {
        status: 500,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const done = count === 0;
    if (done) {
      await supabase.from('sessions').update({ stage: 'ranking' }).eq('id', session_id);
    }

    return new Response(JSON.stringify({ done }), {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
