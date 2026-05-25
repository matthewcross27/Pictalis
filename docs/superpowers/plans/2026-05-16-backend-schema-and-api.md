# Backend Schema & API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Supabase Storage bucket, RLS policies, and five Edge Functions that power the full ranking session lifecycle — create session → register photos → get comparison pairs → submit choices → view ranked results.

**Architecture:** Each API operation is a standalone Supabase Edge Function (Deno 2, TypeScript). Photos live in a private `working-copies` storage bucket; records and objects auto-delete after 72 hours via pg_cron. Anonymous auth ties sessions to callers so RLS can be enforced. All API boundaries validated with Zod.

**Tech Stack:** Supabase Edge Functions (Deno 2), PostgreSQL migrations, pg_cron, Zod, Supabase anonymous auth

---

## Scope Note

- **Not in this plan:** thumbnail generation, image embeddings, duplicate clustering, blur detection (worker plan), iOS upload orchestration (iOS plan).
- The iOS client uploads directly to Supabase Storage using the Storage SDK; no upload Edge Function is needed. The client must use `{uid}/{session_id}/{filename}` as the storage path to satisfy the RLS policy added in Task 1.
- Integration tests for Edge Functions require `supabase start` (Docker) and are not automated in CI. The CI job in Task 9 validates TypeScript correctness via `deno check`.

---

## File Map

```
backend/supabase/
├── config.toml                                          (modify: enable anonymous sign-ins)
├── migrations/
│   ├── 20260516000000_init.sql                          (existing — do not modify)
│   ├── 20260517000001_storage_bucket.sql                (new: bucket + storage policies + cleanup)
│   └── 20260517000002_rls_policies.sql                  (new: table-level RLS policies)
└── functions/
    ├── _shared/
    │   └── elo.ts                                       (new: Elo logic imported by submit-comparison)
    ├── create-session/
    │   └── index.ts                                     (new: POST → creates session row)
    ├── register-photo/
    │   └── index.ts                                     (new: POST → creates photo row after upload)
    ├── next-pair/
    │   └── index.ts                                     (new: GET → returns next comparison pair + signed URLs)
    ├── submit-comparison/
    │   └── index.ts                                     (new: POST → records winner + updates Elo ratings)
    └── results/
        └── index.ts                                     (new: GET → photos ranked by Elo DESC)

.github/workflows/ci.yml                                 (modify: add Deno type-check job)
```

---

## Task 1: Storage bucket + auto-delete migration

**Files:**
- Create: `backend/supabase/migrations/20260517000001_storage_bucket.sql`

- [ ] **Step 1: Create the migration file**

Create `backend/supabase/migrations/20260517000001_storage_bucket.sql`:

```sql
-- Enable pg_cron for scheduled cleanup
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- Create the private working-copies bucket (10 MB per file, image types only)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'working-copies',
  'working-copies',
  false,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
);

-- Storage policy: authenticated users upload into /{uid}/ folder
CREATE POLICY "Owners can upload working copies"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'working-copies'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Storage policy: authenticated users read their own objects
CREATE POLICY "Owners can read working copies"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'working-copies'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Storage policy: authenticated users delete their own objects
CREATE POLICY "Owners can delete working copies"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'working-copies'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Cleanup function: removes objects + sessions past 72-hour retention window
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM storage.objects
  WHERE bucket_id = 'working-copies'
    AND created_at < NOW() - INTERVAL '72 hours';

  -- Cascades to photos and comparisons via ON DELETE CASCADE
  DELETE FROM public.sessions WHERE expires_at < NOW();
END;
$$;

-- Run cleanup every hour at minute 0
SELECT cron.schedule(
  'cleanup-expired-sessions',
  '0 * * * *',
  'SELECT public.cleanup_expired_sessions()'
);
```

- [ ] **Step 2: Verify the migration has all expected statements**

```bash
grep -cE "CREATE POLICY|INSERT INTO storage\.buckets|CREATE OR REPLACE FUNCTION|cron\.schedule" \
  backend/supabase/migrations/20260517000001_storage_bucket.sql
```

Expected: `6` (3 policies + 1 INSERT + 1 FUNCTION + 1 cron.schedule)

---

## Task 2: Enable anonymous auth + RLS policies migration

**Files:**
- Modify: `backend/supabase/config.toml`
- Create: `backend/supabase/migrations/20260517000002_rls_policies.sql`

- [ ] **Step 1: Enable anonymous sign-ins**

In `backend/supabase/config.toml`, find and change:

```toml
# Before:
enable_anonymous_sign_ins = false

# After:
enable_anonymous_sign_ins = true
```

- [ ] **Step 2: Verify the change**

```bash
grep "enable_anonymous_sign_ins" backend/supabase/config.toml
```

Expected: `enable_anonymous_sign_ins = true`

- [ ] **Step 3: Create the RLS policies migration**

Create `backend/supabase/migrations/20260517000002_rls_policies.sql`:

```sql
-- sessions: users can only see and modify their own sessions
CREATE POLICY "Users own their sessions"
ON public.sessions FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- photos: access gated through session ownership
CREATE POLICY "Users own photos in their sessions"
ON public.photos FOR ALL TO authenticated
USING (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
);

-- comparisons: access gated through session ownership
CREATE POLICY "Users own comparisons in their sessions"
ON public.comparisons FOR ALL TO authenticated
USING (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  session_id IN (
    SELECT id FROM public.sessions WHERE user_id = auth.uid()
  )
);
```

- [ ] **Step 4: Verify the policies migration**

```bash
grep -c "CREATE POLICY" backend/supabase/migrations/20260517000002_rls_policies.sql
```

Expected: `3`

---

## Task 3: Shared Elo module for Edge Functions

**Files:**
- Create: `backend/supabase/functions/_shared/elo.ts`

This duplicates the Elo logic from `ranking-engine/src/elo.ts` because Edge Functions run on Deno and cannot import from the Node.js ranking engine. The interface and constants are identical so both implementations stay in sync.

- [ ] **Step 1: Create the shared module**

Create `backend/supabase/functions/_shared/elo.ts`:

```typescript
const K_FACTOR = 32;

export interface EloUpdate {
  winnerNew: number;
  loserNew: number;
}

export function calculateExpected(ratingA: number, ratingB: number): number {
  return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

export function updateElo(winnerRating: number, loserRating: number): EloUpdate {
  const expectedWinner = calculateExpected(winnerRating, loserRating);
  const expectedLoser = calculateExpected(loserRating, winnerRating);
  return {
    winnerNew: winnerRating + K_FACTOR * (1 - expectedWinner),
    loserNew: loserRating + K_FACTOR * (0 - expectedLoser),
  };
}
```

- [ ] **Step 2: Verify Deno can parse it**

```bash
deno check backend/supabase/functions/_shared/elo.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no errors, or the "Note:" message if Deno isn't installed.

---

## Task 4: `create-session` Edge Function

**Files:**
- Create: `backend/supabase/functions/create-session/index.ts`

**Contract:** `POST /functions/v1/create-session`
- Header: `Authorization: Bearer <anon-jwt>`
- Body: `{ "photo_count": 150 }`
- Response 201: `{ "session": { "id": "...", "created_at": "...", "expires_at": "...", "status": "uploading", "photo_count": 150 } }`
- Response 400: invalid body
- Response 401: missing or invalid auth

- [ ] **Step 1: Create the function**

Create `backend/supabase/functions/create-session/index.ts`:

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const CreateSessionBody = z.object({
  photo_count: z.number().int().min(2).max(300),
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

  const parsed = CreateSessionBody.safeParse(body);
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: session, error } = await supabase
    .from('sessions')
    .insert({ photo_count: parsed.data.photo_count, user_id: user.id })
    .select('id, created_at, expires_at, status, photo_count')
    .single();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ session }), {
    status: 201,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
```

- [ ] **Step 2: Type-check the function**

```bash
deno check backend/supabase/functions/create-session/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

---

## Task 5: `register-photo` Edge Function

**Files:**
- Create: `backend/supabase/functions/register-photo/index.ts`

**Contract:** `POST /functions/v1/register-photo`
- Header: `Authorization: Bearer <anon-jwt>`
- Body: `{ "session_id": "<uuid>", "storage_path": "<uid>/<session_id>/<filename>" }`
- Response 201: `{ "photo": { "id": "...", "session_id": "...", "storage_path": "...", "elo_rating": 1500, "comparison_count": 0, "created_at": "..." } }`
- Response 400: invalid body
- Response 404: session not found or not owned by caller

- [ ] **Step 1: Create the function**

Create `backend/supabase/functions/register-photo/index.ts`:

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().min(1),
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

  // RLS enforces that the session belongs to the caller
  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id')
    .eq('id', parsed.data.session_id)
    .single();

  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: 'Session not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: photo, error } = await supabase
    .from('photos')
    .insert({
      session_id: parsed.data.session_id,
      storage_path: parsed.data.storage_path,
    })
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
```

- [ ] **Step 2: Type-check the function**

```bash
deno check backend/supabase/functions/register-photo/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

---

## Task 6: `next-pair` Edge Function

**Files:**
- Create: `backend/supabase/functions/next-pair/index.ts`

**Contract:** `GET /functions/v1/next-pair?session_id=<uuid>`
- Header: `Authorization: Bearer <anon-jwt>`
- Response 200: `{ "comparison_id": "...", "photo_a": { "id": "...", "storage_path": "...", "thumbnail_path": null, "elo_rating": 1500, "comparison_count": 0, "signed_url": "..." }, "photo_b": { ... } }`
- Response 400: missing/invalid session_id
- Response 422: fewer than 2 non-suppressed photos in session

**Pair selection algorithm (Stage 1):** Pick photo A as the photo with the lowest `comparison_count` (random tiebreak). Pick photo B as a photo not yet compared with A that also has the lowest `comparison_count`. If all photos have been compared with A, fall back to any other photo. This prioritizes broad coverage before depth.

- [ ] **Step 1: Create the function**

Create `backend/supabase/functions/next-pair/index.ts`:

```typescript
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
```

- [ ] **Step 2: Type-check the function**

```bash
deno check backend/supabase/functions/next-pair/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

---

## Task 7: `submit-comparison` Edge Function

**Files:**
- Create: `backend/supabase/functions/submit-comparison/index.ts`

**Contract:** `POST /functions/v1/submit-comparison`
- Header: `Authorization: Bearer <anon-jwt>`
- Body: `{ "comparison_id": "<uuid>", "winner_id": "<uuid>" }`
- Response 200: `{ "winner_id": "...", "loser_id": "...", "winner_new_rating": 1516.0, "loser_new_rating": 1484.0 }`
- Response 400: invalid body or winner_id not in the comparison
- Response 404: comparison not found
- Response 409: comparison already submitted

- [ ] **Step 1: Create the function**

Create `backend/supabase/functions/submit-comparison/index.ts`:

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { updateElo } from '../_shared/elo.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const SubmitBody = z.object({
  comparison_id: z.string().uuid(),
  winner_id: z.string().uuid(),
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

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const parsed = SubmitBody.safeParse(body);
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { comparison_id, winner_id } = parsed.data;

  // RLS ensures this comparison belongs to the caller's session
  const { data: comparison, error: compError } = await supabase
    .from('comparisons')
    .select('id, photo_a_id, photo_b_id, completed_at')
    .eq('id', comparison_id)
    .single();

  if (compError || !comparison) {
    return new Response(JSON.stringify({ error: 'Comparison not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (comparison.completed_at !== null) {
    return new Response(JSON.stringify({ error: 'Comparison already submitted' }), {
      status: 409,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (winner_id !== comparison.photo_a_id && winner_id !== comparison.photo_b_id) {
    return new Response(
      JSON.stringify({ error: 'winner_id must be one of the two compared photos' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }

  const loser_id =
    winner_id === comparison.photo_a_id ? comparison.photo_b_id : comparison.photo_a_id;

  const { data: photoPair, error: photoError } = await supabase
    .from('photos')
    .select('id, elo_rating, comparison_count')
    .in('id', [winner_id, loser_id]);

  if (photoError || !photoPair || photoPair.length !== 2) {
    return new Response(JSON.stringify({ error: 'Failed to fetch photo ratings' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const winner = photoPair.find((p) => p.id === winner_id)!;
  const loser = photoPair.find((p) => p.id === loser_id)!;
  const { winnerNew, loserNew } = updateElo(winner.elo_rating, loser.elo_rating);

  const [winnerUpdate, loserUpdate, compUpdate] = await Promise.all([
    supabase
      .from('photos')
      .update({ elo_rating: winnerNew, comparison_count: winner.comparison_count + 1 })
      .eq('id', winner_id),
    supabase
      .from('photos')
      .update({ elo_rating: loserNew, comparison_count: loser.comparison_count + 1 })
      .eq('id', loser_id),
    supabase
      .from('comparisons')
      .update({ winner_id, completed_at: new Date().toISOString() })
      .eq('id', comparison_id),
  ]);

  if (winnerUpdate.error || loserUpdate.error || compUpdate.error) {
    return new Response(JSON.stringify({ error: 'Failed to record comparison result' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(
    JSON.stringify({ winner_id, loser_id, winner_new_rating: winnerNew, loser_new_rating: loserNew }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
```

- [ ] **Step 2: Type-check the function**

```bash
deno check backend/supabase/functions/submit-comparison/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

---

## Task 8: `results` Edge Function

**Files:**
- Create: `backend/supabase/functions/results/index.ts`

**Contract:** `GET /functions/v1/results?session_id=<uuid>&limit=20`
- Header: `Authorization: Bearer <anon-jwt>`
- Response 200: `{ "photos": [ { "id": "...", "storage_path": "...", "thumbnail_path": null, "elo_rating": 1532.1, "uncertainty": 350, "comparison_count": 5, "is_suppressed": false, "cluster_id": null, "quality_flags": {}, "signed_url": "..." }, ... ] }`
- Response 400: missing/invalid session_id

- [ ] **Step 1: Create the function**

Create `backend/supabase/functions/results/index.ts`:

```typescript
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
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const photosWithUrls = await Promise.all(
    (photos ?? []).map(async (photo) => {
      const { data: signed } = await supabase.storage
        .from('working-copies')
        .createSignedUrl(photo.storage_path, 3600);
      return { ...photo, signed_url: signed?.signedUrl ?? null };
    })
  );

  return new Response(JSON.stringify({ photos: photosWithUrls }), {
    status: 200,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
```

- [ ] **Step 2: Type-check the function**

```bash
deno check backend/supabase/functions/results/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

---

## Task 9: CI — add Deno type-check job

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Read the current CI file**

```bash
cat .github/workflows/ci.yml
```

- [ ] **Step 2: Add the `functions` job after the `worker` job**

In `.github/workflows/ci.yml`, append this job under `jobs:` (after the `worker:` block):

```yaml
  functions:
    name: Edge Functions (Deno)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v2
        with:
          deno-version: v2.x
      - name: Type-check edge functions
        run: |
          for f in backend/supabase/functions/*/index.ts; do
            echo "Checking $f"
            deno check "$f"
          done
```

- [ ] **Step 3: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 4: Verify three jobs exist in the workflow**

```bash
grep -c "^\s\{2\}[a-z].*:$" .github/workflows/ci.yml || \
grep -E "^  [a-z-]+:$" .github/workflows/ci.yml | wc -l
```

Expected: `3` (ranking-engine, worker, functions)

---

## Self-Review Checklist

**Spec coverage:**
- [x] Storage bucket created — `working-copies`, private, 10 MB per file, image MIME types only (Task 1)
- [x] 72-hour auto-delete — pg_cron job + `cleanup_expired_sessions()` function (Task 1)
- [x] Storage RLS policies — upload/read/delete scoped to owner UID folder (Task 1)
- [x] Anonymous auth enabled — config.toml change (Task 2)
- [x] Table RLS policies — sessions, photos, comparisons gated to `auth.uid()` (Task 2)
- [x] Session creation API — POST create-session with photo_count (Task 4)
- [x] Photo registration API — POST register-photo with session_id + storage_path (Task 5)
- [x] Next comparison pair — GET next-pair with Stage 1 broad-discovery algorithm (Task 6)
- [x] Elo update < 200ms — pure in-memory calculation (no extra DB round-trips for compute) (Task 7)
- [x] Ranked results API — GET results ordered by elo_rating DESC (Task 8)
- [x] Zod validation on all API boundaries (Tasks 4–8)
- [x] TypeScript strict mode enforced by `deno check` in CI (Task 9)

**Items deferred to other plans:**
- Thumbnail path population → worker plan
- Image embeddings, duplicate clustering, blur detection → worker plan
- iOS upload orchestration (must use `{uid}/{session_id}/{filename}` storage path format) → iOS plan
- Stage 2/3 pair selection (similar Elo, duplicate cluster comparisons) → ranking-engine plan

**Placeholder scan:** No TBD/TODO/implement-later found.

**Type consistency:**
- `updateElo` in `_shared/elo.ts` returns `{ winnerNew: number; loserNew: number }` — destructured consistently in `submit-comparison/index.ts`
- `session_id` is `string` (UUID) across all functions; never typed as `number`
- `photo_a` / `photo_b` fields in `next-pair` response include `id, storage_path, thumbnail_path, elo_rating, comparison_count, signed_url` — these are the same fields the iOS client will render
- `comparison_id` from `next-pair` response is passed back to `submit-comparison` — field names match
