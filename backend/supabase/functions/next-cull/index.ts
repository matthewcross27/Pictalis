import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
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
      return new Response(
        JSON.stringify({ error: 'Missing Authorization header' }),
        {
          status: 401,
          headers: { ...CORS, 'Content-Type': 'application/json' },
        },
      );
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
      { global: { headers: { Authorization: authHeader } } },
    );

    const { session_id } = parsed.data;

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
      await supabase.from('sessions').update({ stage: 'ranking' }).eq(
        'id',
        session_id,
      );
      return new Response(JSON.stringify({ done: true }), {
        status: 200,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const photo = photos[0];
    const cardsRemaining = photos.length;

    const { data: signed, error: urlError } = await supabase.storage
      .from('working-copies')
      .createSignedUrl(photo.storage_path, 3600);

    if (urlError || !signed?.signedUrl) {
      return new Response(
        JSON.stringify({ error: 'Failed to generate photo URL' }),
        {
          status: 500,
          headers: { ...CORS, 'Content-Type': 'application/json' },
        },
      );
    }

    return new Response(
      JSON.stringify({
        done: false,
        photo_id: photo.id,
        photo_url: signed.signedUrl,
        cards_remaining: cardsRemaining,
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
