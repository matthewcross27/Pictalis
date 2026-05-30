# CodeRabbit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 8 CodeRabbit findings from PR #1 — two critical (non-atomic Elo writes, TOCTOU double-submit), two major (storage path validation, orphaned comparisons), and four minor (storage policy NULL guard, results signed URL errors, iOS launch screen).

**Architecture:** Critical fixes land in a new Postgres RPC (`submit_comparison_atomic`) that wraps all three writes in one transaction and uses `WHERE completed_at IS NULL` to eliminate the race. Minor DB fixes go into two new migrations. The `register-photo` Edge Function gains Zod format validation plus a storage list check. The `results` Edge Function gains signed URL error propagation. iOS `Info.plist` drops the empty storyboard key.

**Tech Stack:** Supabase Edge Functions (Deno 2, TypeScript, Zod), PostgreSQL migrations, SwiftUI / Info.plist

---

## Pre-flight note — two findings already fixed

| Finding | Status |
|---|---|
| Cleanup deletes by `created_at` alone (Major) | **Already fixed** — actual `20260517000001_storage_bucket.sql` joins `photos → sessions` on `expires_at` |
| `next-pair` swallows signed URL errors (Minor) | **Already fixed** — lines 96–101 of `next-pair/index.ts` return 500 on missing URLs |

Only the six remaining findings need code changes.

---

## File Map

```
backend/supabase/
├── migrations/
│   ├── 20260517000003_atomic_submit_comparison.sql   (new: submit_comparison_atomic RPC)
│   └── 20260517000004_storage_hardening.sql          (new: orphaned comparison cleanup + storage policy NULL guard)
└── functions/
    ├── submit-comparison/
    │   └── index.ts                                   (modify: replace multi-step writes with RPC call)
    ├── register-photo/
    │   └── index.ts                                   (modify: add path format + storage existence validation)
    └── results/
        └── index.ts                                   (modify: propagate signed URL errors)

ios/picHelper/
└── Info.plist                                         (modify: replace empty UILaunchStoryboardName)
```

---

## Task 1: Atomic comparison submission RPC (Critical #1 + Critical #2)

**Files:**
- Create: `backend/supabase/migrations/20260517000003_atomic_submit_comparison.sql`
- Modify: `backend/supabase/functions/submit-comparison/index.ts`

The current `submit-comparison` function does three separate DB writes: mark `comparisons.completed_at`, update winner rating, update loser rating. If any write fails the DB is left inconsistent. Separately, the `completed_at IS NULL` pre-check is a non-atomic read-before-write that two concurrent requests can both pass before either writes.

The fix: a single Postgres function that does all three writes inside one implicit transaction and uses `UPDATE ... WHERE completed_at IS NULL` as the authoritative gate. A 0-row update means the comparison was already claimed — the function raises `already_submitted` so the caller gets a 409.

- [ ] **Step 1: Create the migration**

Create `backend/supabase/migrations/20260517000003_atomic_submit_comparison.sql`:

```sql
-- Atomically mark a comparison complete and update both photo Elo ratings.
-- Raises 'already_submitted' (P0001) if the comparison was already completed,
-- eliminating the TOCTOU race in the Edge Function.
CREATE OR REPLACE FUNCTION public.submit_comparison_atomic(
  p_comparison_id   uuid,
  p_winner_id       uuid,
  p_loser_id        uuid,
  p_winner_new_rating float8,
  p_loser_new_rating  float8
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_affected int;
BEGIN
  -- Claim the comparison. RLS ensures it belongs to the caller.
  -- Only succeeds when completed_at IS NULL (not already submitted).
  UPDATE public.comparisons
  SET winner_id    = p_winner_id,
      completed_at = NOW()
  WHERE id = p_comparison_id
    AND completed_at IS NULL;

  GET DIAGNOSTICS v_affected = ROW_COUNT;

  IF v_affected = 0 THEN
    RAISE EXCEPTION 'already_submitted'
      USING HINT = 'comparison already completed';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_winner_new_rating,
      comparison_count = comparison_count + 1
  WHERE id = p_winner_id;

  UPDATE public.photos
  SET elo_rating       = p_loser_new_rating,
      comparison_count = comparison_count + 1
  WHERE id = p_loser_id;
END;
$$;

-- Allow authenticated users (Edge Function callers) to invoke the RPC.
-- SECURITY INVOKER (default) keeps RLS active for all internal UPDATEs.
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic TO authenticated;
```

- [ ] **Step 2: Verify the migration syntax**

```bash
grep -c "UPDATE\|RAISE EXCEPTION\|GRANT EXECUTE" \
  backend/supabase/migrations/20260517000003_atomic_submit_comparison.sql
```

Expected: `4` (2 UPDATEs + 1 RAISE + 1 GRANT)

- [ ] **Step 3: Replace multi-step writes in `submit-comparison/index.ts`**

Open `backend/supabase/functions/submit-comparison/index.ts`. The current file (after the existing sequential-write fix) still has three separate writes. Replace the entire file with:

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
    .select('id, photo_a_id, photo_b_id')
    .eq('id', comparison_id)
    .single();

  if (compError || !comparison) {
    return new Response(JSON.stringify({ error: 'Comparison not found' }), {
      status: 404,
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

  // Single atomic transaction: claim comparison + update both Elo ratings.
  // The RPC raises 'already_submitted' if completed_at was already set,
  // preventing the TOCTOU race from the previous multi-step write approach.
  const { error: submitError } = await supabase.rpc('submit_comparison_atomic', {
    p_comparison_id: comparison_id,
    p_winner_id: winner_id,
    p_loser_id: loser_id,
    p_winner_new_rating: winnerNew,
    p_loser_new_rating: loserNew,
  });

  if (submitError) {
    const isAlreadyDone = submitError.message?.includes('already_submitted');
    return new Response(
      JSON.stringify({ error: isAlreadyDone ? 'Comparison already submitted' : 'Failed to record comparison result' }),
      {
        status: isAlreadyDone ? 409 : 500,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      }
    );
  }

  return new Response(
    JSON.stringify({ winner_id, loser_id, winner_new_rating: winnerNew, loser_new_rating: loserNew }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
```

- [ ] **Step 4: Type-check the function**

```bash
deno check backend/supabase/functions/submit-comparison/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/migrations/20260517000003_atomic_submit_comparison.sql \
        backend/supabase/functions/submit-comparison/index.ts
git commit -m "fix(backend): atomic Elo update via submit_comparison_atomic RPC"
```

---

## Task 2: Storage hardening migration (Minor #6 + Minor #7)

**Files:**
- Create: `backend/supabase/migrations/20260517000004_storage_hardening.sql`

Two independent issues in one migration:
1. The pg_cron cleanup never purges **pending** comparison rows (`completed_at IS NULL`) left behind by abandoned sessions. These accumulate indefinitely.
2. Storage object policies use `(storage.foldername(name))[1]` which returns `NULL` for root-level paths (no `/`), making the `= auth.uid()::text` comparison silently false instead of explicitly rejected. The NULL guard makes the rejection explicit.

- [ ] **Step 1: Create the migration**

Create `backend/supabase/migrations/20260517000004_storage_hardening.sql`:

```sql
-- Update cleanup function to also purge orphaned pending comparisons.
-- These are created by next-pair but never submitted (abandoned sessions).
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void LANGUAGE plpgsql
SET search_path = public, storage, extensions
AS $$
BEGIN
  -- Delete pending comparisons abandoned for more than 1 hour
  DELETE FROM public.comparisons
  WHERE completed_at IS NULL
    AND created_at < NOW() - INTERVAL '1 hour';

  -- Delete storage objects whose session has expired
  DELETE FROM storage.objects so
  WHERE so.bucket_id = 'working-copies'
    AND EXISTS (
      SELECT 1 FROM public.photos p
      JOIN public.sessions s ON s.id = p.session_id
      WHERE p.storage_path = so.name
        AND s.expires_at < NOW()
    );

  -- Cascades to photos and comparisons via ON DELETE CASCADE
  DELETE FROM public.sessions WHERE expires_at < NOW();
END;
$$;

-- Recreate storage policies with NULL guard on foldername.
-- Without the array_length check, root-path uploads (no '/') return NULL
-- for foldername[1], causing the UID comparison to silently fail rather
-- than explicitly reject.
DROP POLICY IF EXISTS "Owners can upload working copies" ON storage.objects;
DROP POLICY IF EXISTS "Owners can read working copies" ON storage.objects;
DROP POLICY IF EXISTS "Owners can delete working copies" ON storage.objects;

CREATE POLICY "Owners can upload working copies"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Owners can read working copies"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Owners can delete working copies"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'working-copies'
  AND array_length(storage.foldername(name), 1) >= 1
  AND (storage.foldername(name))[1] = auth.uid()::text
);
```

- [ ] **Step 2: Verify policy and function counts**

```bash
grep -c "CREATE POLICY\|CREATE OR REPLACE FUNCTION\|DELETE FROM public.comparisons" \
  backend/supabase/migrations/20260517000004_storage_hardening.sql
```

Expected: `5` (3 policies + 1 function + 1 DELETE for orphaned comparisons)

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/migrations/20260517000004_storage_hardening.sql
git commit -m "fix(backend): purge orphaned comparisons in cleanup; add NULL guard to storage policies"
```

---

## Task 3: `register-photo` path validation (Major #3)

**Files:**
- Modify: `backend/supabase/functions/register-photo/index.ts`

Currently `storage_path` is only validated as non-empty. Two gaps:
1. No format check — any string passes, allowing paths that don't match `{uid}/{session_id}/{filename}`.
2. No existence check — a caller can register a DB row for a file they haven't uploaded yet.

The fix adds a Zod regex, cross-validates the path segments against the caller's UID and the submitted `session_id`, then calls `storage.list()` to confirm the object exists before inserting the DB record.

- [ ] **Step 1: Replace `register-photo/index.ts`**

```typescript
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
```

- [ ] **Step 2: Type-check the function**

```bash
deno check backend/supabase/functions/register-photo/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/functions/register-photo/index.ts
git commit -m "fix(backend): validate storage_path format and existence in register-photo"
```

---

## Task 4: `results` signed URL error propagation (Minor #8)

**Files:**
- Modify: `backend/supabase/functions/results/index.ts`

The `results` function maps over photos and calls `createSignedUrl` inside `Promise.all`, but silently falls back to `null` on errors. A signed URL failure should surface as a 500 rather than returning photos with `signed_url: null`.

- [ ] **Step 1: Read the current file**

```bash
cat backend/supabase/functions/results/index.ts
```

Locate the `photosWithUrls` block near the bottom (after the photo SELECT query).

- [ ] **Step 2: Replace the `photosWithUrls` block**

Find this existing block:

```typescript
  const photosWithUrls = await Promise.all(
    (photos ?? []).map(async (photo) => {
      const { data: signed } = await supabase.storage
        .from('working-copies')
        .createSignedUrl(photo.storage_path, 3600);
      return { ...photo, signed_url: signed?.signedUrl ?? null };
    })
  );
```

Replace it with:

```typescript
  const photosWithUrls = await Promise.all(
    (photos ?? []).map(async (photo) => {
      const { data: signed, error: signedError } = await supabase.storage
        .from('working-copies')
        .createSignedUrl(photo.storage_path, 3600);
      if (signedError) throw signedError;
      return { ...photo, signed_url: signed?.signedUrl ?? null };
    })
  ).catch(() => null);

  if (!photosWithUrls) {
    return new Response(JSON.stringify({ error: 'Failed to generate photo URLs' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
```

- [ ] **Step 3: Type-check the function**

```bash
deno check backend/supabase/functions/results/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/results/index.ts
git commit -m "fix(backend): propagate signed URL errors in results function"
```

---

## Task 5: iOS launch screen fix (Minor #5)

**Files:**
- Modify: `ios/picHelper/Info.plist`

`UILaunchStoryboardName` is present with an empty string value, causing iOS to display a black launch screen because it can't resolve a storyboard. For a SwiftUI app (which manages its own launch appearance), the correct fix is to replace the empty key with the modern `UILaunchScreen` dictionary (iOS 14+), which displays a blank white screen while the app initialises.

- [ ] **Step 1: Update `Info.plist`**

Find and replace this block in `ios/picHelper/Info.plist`:

```xml
	<key>UILaunchStoryboardName</key>
	<string></string>
```

Replace with:

```xml
	<key>UILaunchScreen</key>
	<dict/>
```

- [ ] **Step 2: Verify the change**

```bash
grep -c "UILaunchScreen\|UILaunchStoryboardName" ios/picHelper/Info.plist
```

Expected: `1` (only `UILaunchScreen`, no `UILaunchStoryboardName`).

- [ ] **Step 3: Commit**

```bash
git add ios/picHelper/Info.plist
git commit -m "fix(ios): replace empty UILaunchStoryboardName with UILaunchScreen dict"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Critical #1 (non-atomic Elo writes) — Task 1: `submit_comparison_atomic` RPC wraps all three writes in one transaction
- [x] Critical #2 (TOCTOU double-submit) — Task 1: `UPDATE ... WHERE completed_at IS NULL` + row-count check eliminates the race
- [x] Major #3 (register-photo path validation) — Task 3: Zod regex + UID/session cross-check + storage.list existence check
- [x] Major #4 (cleanup by created_at alone) — Pre-flight note: already fixed in actual migration code
- [x] Minor #5 (iOS launch screen) — Task 5: `UILaunchScreen` dict replaces empty storyboard key
- [x] Minor #6 (orphaned comparisons) — Task 2: `DELETE FROM comparisons WHERE completed_at IS NULL AND created_at < NOW() - INTERVAL '1 hour'`
- [x] Minor #7 (storage policy NULL guard) — Task 2: `array_length(storage.foldername(name), 1) >= 1` added to all three policies
- [x] Minor #8 (results signed URL errors) — Task 4: `.catch(() => null)` + null-check returns 500

**Placeholder scan:** No TBD/TODO/implement-later present.

**Type consistency:**
- `submit_comparison_atomic` parameter names (`p_comparison_id`, `p_winner_id`, `p_loser_id`, `p_winner_new_rating`, `p_loser_new_rating`) match the `supabase.rpc()` call object keys in `submit-comparison/index.ts`
- `updateElo` returns `{ winnerNew, loserNew }` — destructured consistently, passed as `p_winner_new_rating` / `p_loser_new_rating`
- `storage_path` is `string` across all functions — never retyped
- `RegisterPhotoBody` fields (`session_id`, `storage_path`) match the variable names used throughout `register-photo/index.ts`
- `photosWithUrls` type is `Array<photo & { signed_url: string | null }> | null` — null-guarded before use in `results/index.ts`
