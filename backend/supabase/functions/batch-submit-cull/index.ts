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
  decisions:  z.array(z.object({
    photo_id: z.string().uuid(),
    decision: z.enum(['keep', 'drop']),
  })).min(1),
});

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

    const { session_id, decisions } = parsed.data;

    // Process each decision with same cluster-wide logic as submit-cull.
    // cull_decision IS NULL guard makes this idempotent — safe to retry.
    const results = await Promise.all(
      decisions.map(async ({ photo_id, decision }) => {
        try {
          const { data: photo, error: photoError } = await supabase
            .from('photos')
            .select('cluster_id')
            .eq('id', photo_id)
            .eq('session_id', session_id)
            .single();

          if (photoError || !photo) {
            return { photo_id, success: false, error: 'Photo not found' };
          }

          const update = decision === 'keep'
            ? { cull_decision: 'keep' }
            : { cull_decision: 'drop', is_suppressed: true };

          const { error: updateError } = await supabase
            .from('photos')
            .update(update)
            .eq('cluster_id', photo.cluster_id)
            .eq('session_id', session_id)
            .is('cull_decision', null);

          if (updateError) {
            return { photo_id, success: false, error: updateError.message };
          }

          return { photo_id, success: true };
        } catch (err) {
          return { photo_id, success: false, error: String(err) };
        }
      })
    );

    return new Response(JSON.stringify({ results }), {
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
