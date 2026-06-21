import { createClient } from 'jsr:@supabase/supabase-js@2';
import { initSentry, Sentry } from '../_shared/sentry.ts';
import { RegisterPhotoBody } from '../_shared/photo-registration.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

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

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
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

    const parsed = RegisterPhotoBody.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
        status: 400,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const { session_id, storage_path, photo_id } = parsed.data;
    const [pathUid, pathSessionId] = storage_path.split('/');

    if (pathUid !== user.id) {
      return new Response(
        JSON.stringify({ error: 'storage_path UID segment must match the authenticated user' }),
        { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } },
      );
    }
    if (pathSessionId !== session_id) {
      return new Response(
        JSON.stringify({ error: 'storage_path session_id segment must match session_id field' }),
        { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } },
      );
    }

    const filename = storage_path.split('/')[2];
    const { data: objects, error: listError } = await supabase.storage
      .from('working-copies')
      .list(`${pathUid}/${pathSessionId}`, { search: filename });

    if (listError || !objects || !objects.some((o) => o.name === filename)) {
      return new Response(JSON.stringify({ error: 'Storage object not found' }), {
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const { data: session, error: sessionError } = await supabase
      .from('sessions')
      .select('id')
      .eq('id', session_id)
      .single();

    if (sessionError || !session) {
      return new Response(JSON.stringify({ error: 'Session not found' }), {
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const PHOTO_COLUMNS =
      'id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed';

    // Row was pre-registered at session start. UPDATE sets the bytes location
    // and marks upload complete. Idempotent: a retry on an already-uploaded row
    // returns the existing data unchanged.
    const { data: photo, error: updateError } = await supabase
      .from('photos')
      .update({ storage_path, upload_status: 'uploaded' })
      .eq('id', photo_id)
      .eq('session_id', session_id)
      .select(PHOTO_COLUMNS)
      .single();

    if (updateError || !photo) {
      // Row missing: batch-pre-register wasn't called, or session/id mismatch.
      return new Response(JSON.stringify({ error: 'Photo not pre-registered or session mismatch' }), {
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ photo }), {
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
