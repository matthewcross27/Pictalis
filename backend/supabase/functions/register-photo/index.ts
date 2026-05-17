import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Path must be exactly {uuid}/{uuid}/{filename} — no deeper nesting, no root paths.
const UUID_RE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const STORAGE_PATH_RE = new RegExp(`^${UUID_RE}/${UUID_RE}/[^/]+$`, 'i');

const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().regex(STORAGE_PATH_RE, 'Must match {uid}/{session_id}/{filename}'),
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

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } }
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

  const { session_id, storage_path } = parsed.data;
  const [pathUid, pathSessionId, filename] = storage_path.split('/');

  // Cross-validate path segments against caller identity and request body
  if (pathUid !== user.id) {
    return new Response(
      JSON.stringify({ error: 'storage_path UID segment must match the authenticated user' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }
  if (pathSessionId !== session_id) {
    return new Response(
      JSON.stringify({ error: 'storage_path session_id segment must match session_id field' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }

  // Verify the object actually exists in storage before creating a DB record
  const { data: objects, error: listError } = await supabase.storage
    .from('working-copies')
    .list(`${pathUid}/${pathSessionId}`, { search: filename });

  if (listError || !objects || objects.length === 0) {
    return new Response(JSON.stringify({ error: 'Storage object not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // RLS enforces that the session belongs to the caller
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

  const { data: photo, error } = await supabase
    .from('photos')
    .insert({ session_id, storage_path })
    .select('id, session_id, storage_path, elo_rating, comparison_count, created_at')
    .single();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ photo }), {
    status: 201,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
