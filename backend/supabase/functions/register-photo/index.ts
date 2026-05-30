import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { computeDHash, computeBlurScore, hammingDistance } from '../_shared/phash.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const UUID_RE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const STORAGE_PATH_RE = new RegExp(`^${UUID_RE}/${UUID_RE}/[^/]+$`, 'i');

const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().regex(STORAGE_PATH_RE, 'Must match {uid}/{session_id}/{filename}'),
});

// Hamming distance thresholds for duplicate/cluster decisions.
const DUPLICATE_THRESHOLD = 3;  // ≤ 3 bits differ → near-identical → suppress
const CLUSTER_THRESHOLD = 10;   // ≤ 10 bits differ → same scene → share cluster_id
const BLUR_THRESHOLD = 200;     // pixel variance below this → blurry → suppress

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

  // Insert the photo row with defaults first — ensures the photo is registered
  // even if the hashing step below fails.
  const { data: photo, error: insertError } = await supabase
    .from('photos')
    .insert({ session_id, storage_path })
    .select('id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed, cluster_id, quality_flags, phash')
    .single();

  if (insertError || !photo) {
    console.error('Failed to insert photo record:', insertError);
    return new Response(JSON.stringify({ error: 'Failed to register photo' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // --- pHash computation (graceful degradation on any error) ---
  try {
    // Download the uploaded image bytes using a short-lived signed URL.
    const { data: signed, error: signedError } = await supabase.storage
      .from('working-copies')
      .createSignedUrl(storage_path, 60);

    if (signedError || !signed?.signedUrl) throw new Error('Could not create signed URL');

    const response = await fetch(signed.signedUrl);
    if (!response.ok) throw new Error(`Image fetch failed: ${response.status}`);
    const imageBytes = new Uint8Array(await response.arrayBuffer());

    // Compute hash and blur score in parallel (both read the same buffer).
    const [phash, blurScore] = await Promise.all([
      computeDHash(imageBytes),
      computeBlurScore(imageBytes),
    ]);

    // Fetch all existing hashes for this session to find cluster match.
    const { data: existingPhotos } = await supabase
      .from('photos')
      .select('id, cluster_id, phash')
      .eq('session_id', session_id)
      .not('phash', 'is', null)
      .neq('id', photo.id); // Exclude the photo we just inserted

    // Find the closest existing hash by Hamming distance.
    let closestDistance = Infinity;
    let closestClusterId: string | null = null;
    for (const existing of existingPhotos ?? []) {
      const dist = hammingDistance(phash, existing.phash);
      if (dist < closestDistance) {
        closestDistance = dist;
        closestClusterId = existing.cluster_id;
      }
    }

    const clusterId = closestDistance <= CLUSTER_THRESHOLD && closestClusterId
      ? closestClusterId
      : crypto.randomUUID(); // New cluster for this photo

    const isNearIdentical = closestDistance <= DUPLICATE_THRESHOLD;
    const isBlurry = blurScore < BLUR_THRESHOLD;
    const isSuppressed = isNearIdentical || isBlurry;

    const qualityFlags = {
      blur_score: Math.round(blurScore),
      blurry: isBlurry,
      near_identical: isNearIdentical,
    };

    // Patch the photo row with computed values.
    await supabase
      .from('photos')
      .update({ phash, cluster_id: clusterId, quality_flags: qualityFlags, is_suppressed: isSuppressed })
      .eq('id', photo.id);

    // Return the enriched photo response.
    return new Response(
      JSON.stringify({
        photo: {
          ...photo,
          phash,
          cluster_id: clusterId,
          quality_flags: qualityFlags,
          is_suppressed: isSuppressed,
        },
      }),
      { status: 201, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    // Hashing failed — return the photo with defaults. Registration succeeded.
    console.error('pHash computation failed (non-fatal):', err);
    return new Response(JSON.stringify({ photo }), {
      status: 201,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
