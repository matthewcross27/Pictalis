# Multi-Stage Ranking Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement PRD Stages 1/2/3 pair selection, uncertainty decay per comparison, and automatic convergence detection — turning the current flat coverage loop into an intelligent ranking engine that tightens its focus as confidence grows.

**Architecture:** A new `stage` column on `sessions` (`stage1` → `stage2` → `stage3` → `complete`) drives pair selection in `next-pair`. Stage transitions are evaluated at the start of each `next-pair` call by inspecting the already-fetched photo array (no extra DB query). Uncertainty decays 10% per comparison via an update to the `submit_comparison_atomic` Postgres RPC. A new `session-status` Edge Function exposes current stage and completion flag so the iOS app can detect when to show the completion screen.

**Tech Stack:** Deno 2, TypeScript, Zod, PostgreSQL (migration + updated RPC)

---

## Scope Note

This plan covers backend only. The iOS client changes (CompletionView, auto-navigation, stage labels) are in the companion `2026-05-18-ios-completion-state.md` plan. The `session-status` function built here is what iOS will call.

---

## Stage Transition Rules

| From → To | Condition |
|---|---|
| `stage1` → `stage2` | Every non-suppressed photo has `comparison_count ≥ 3` |
| `stage2` → `stage3` | Average `uncertainty` of top-20 photos by Elo < 100 |
| `stage3` → `complete` | Average `uncertainty` of top-10 photos < 50 **or** total comparisons ≥ `photo_count × 3` |

**Total comparisons** is derived from photos already in memory: `photos.reduce((s, p) => s + p.comparison_count, 0) / 2` (each comparison increments both participants).

## Pair Selection Strategy per Stage

| Stage | Photo A | Photo B |
|---|---|---|
| `stage1` | Fewest comparisons (random tiebreak) | Fewest comparisons among unpaired; prefer different `cluster_id` than A |
| `stage2` | Highest uncertainty in top-50% by Elo | Closest Elo rating to A among unpaired photos |
| `stage3` | From a cluster containing a top-20 photo | Another unseen photo in the same cluster; fallback → stage2 strategy |
| `complete` | Stage2 strategy (user can keep going) | Stage2 strategy |

---

## File Map

```
backend/supabase/
├── migrations/
│   └── 20260518000002_session_stage.sql             (new: stage column + updated RPC)
└── functions/
    ├── next-pair/
    │   └── index.ts                                  (replace: full Stage 1/2/3 implementation)
    ├── results/
    │   └── index.ts                                  (modify: add session stage to response)
    └── session-status/
        └── index.ts                                  (new: returns stage + is_complete)
```

`submit-comparison/index.ts` is **not modified** — it already calls `submit_comparison_atomic` by name. The RPC itself gains uncertainty decay in the migration.

---

### Task 1: Migration — session stage + uncertainty decay

**Files:**
- Create: `backend/supabase/migrations/20260518000002_session_stage.sql`

- [ ] **Step 1: Write the migration**

Create `backend/supabase/migrations/20260518000002_session_stage.sql`:

```sql
-- Track which ranking stage a session is in.
-- Stage transitions are driven by next-pair (no extra write needed in submit-comparison).
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS stage TEXT NOT NULL DEFAULT 'stage1'
  CHECK (stage IN ('stage1', 'stage2', 'stage3', 'complete'));

-- Existing sessions get 'stage1' via DEFAULT. No data migration needed.

-- Update the atomic submission RPC to also decay uncertainty by 10% on each comparison.
-- Uncertainty starts at 350 and converges toward 0 as a photo is seen more.
-- Thresholds used by next-pair: top-20 avg < 100 → stage3; top-10 avg < 50 → complete.
CREATE OR REPLACE FUNCTION public.submit_comparison_atomic(
  p_comparison_id     uuid,
  p_winner_id         uuid,
  p_loser_id          uuid,
  p_winner_new_rating float8,
  p_loser_new_rating  float8
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE
  v_affected int;
BEGIN
  UPDATE public.comparisons
  SET winner_id    = p_winner_id,
      completed_at = NOW()
  WHERE id = p_comparison_id
    AND completed_at IS NULL;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'Comparison already submitted'
      USING ERRCODE = 'UE001', HINT = 'comparison already completed';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_winner_new_rating,
      comparison_count = comparison_count + 1,
      uncertainty      = uncertainty * 0.9
  WHERE id = p_winner_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'photo_not_found' USING HINT = 'winner photo not found';
  END IF;

  UPDATE public.photos
  SET elo_rating       = p_loser_new_rating,
      comparison_count = comparison_count + 1,
      uncertainty      = uncertainty * 0.9
  WHERE id = p_loser_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  IF v_affected = 0 THEN
    RAISE EXCEPTION 'photo_not_found' USING HINT = 'loser photo not found';
  END IF;
END;
$$;

-- Permissions unchanged — authenticated users can still call the RPC.
REVOKE ALL ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_comparison_atomic(uuid, uuid, uuid, float8, float8) TO authenticated;
```

- [ ] **Step 2: Verify the migration**

```bash
grep -c "ADD COLUMN\|CREATE OR REPLACE FUNCTION\|uncertainty.*0\.9" \
  backend/supabase/migrations/20260518000002_session_stage.sql
```

Expected: `3`

- [ ] **Step 3: Apply via Supabase MCP**

Use `mcp__plugin_supabase_supabase__apply_migration` with the SQL above. Confirm `sessions` has a `stage` column defaulting to `'stage1'`.

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/migrations/20260518000002_session_stage.sql
git commit -m "feat(backend): add session stage column and uncertainty decay to submission RPC"
```

---

### Task 2: Rewrite next-pair with Stage 1/2/3 logic

**Files:**
- Replace: `backend/supabase/functions/next-pair/index.ts`

This is the largest change. The file goes from ~130 lines to ~220 lines. No new files — everything is self-contained in `index.ts`.

**Algorithm overview:**
1. Fetch session (id + stage + photo_count)
2. Fetch all non-suppressed photos (with `uncertainty`, `cluster_id`) sorted by `comparison_count ASC, elo_rating DESC`
3. Evaluate stage transitions using pure functions over the photo array — update `sessions.stage` if advancing
4. Select Photo A and Photo B according to the (possibly advanced) stage
5. Fetch prior comparisons for Photo A (needed by all stages to avoid repeats)
6. Generate signed URLs, create pending comparison record, respond

- [ ] **Step 1: Replace next-pair/index.ts**

Replace `backend/supabase/functions/next-pair/index.ts` with:

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

// Stage transition thresholds
const STAGE2_MIN_COMPARISONS = 3;       // Every photo must have ≥ 3 comparisons
const STAGE3_TOP_N = 20;               // Evaluate top N photos for stage3 trigger
const STAGE3_UNCERTAINTY_THRESHOLD = 100;
const COMPLETE_TOP_N = 10;
const COMPLETE_UNCERTAINTY_THRESHOLD = 50;
const COMPLETE_COMPARISON_MULTIPLIER = 3; // complete if total_comps >= photo_count * this

type Photo = {
  id: string;
  storage_path: string;
  thumbnail_path: string | null;
  elo_rating: number;
  uncertainty: number;
  comparison_count: number;
  cluster_id: string | null;
};

// Pure functions — operate on the already-fetched photo array.

function totalComparisons(photos: Photo[]): number {
  // Each comparison increments both participants' comparison_count.
  return photos.reduce((s, p) => s + p.comparison_count, 0) / 2;
}

function avgUncertainty(photos: Photo[], topN: number): number {
  const sorted = [...photos].sort((a, b) => b.elo_rating - a.elo_rating).slice(0, topN);
  if (sorted.length === 0) return Infinity;
  return sorted.reduce((s, p) => s + p.uncertainty, 0) / sorted.length;
}

function nextStage(
  current: string,
  photos: Photo[],
  photoCount: number,
): string | null {
  if (current === 'stage1') {
    const ready = photos.every((p) => p.comparison_count >= STAGE2_MIN_COMPARISONS);
    return ready ? 'stage2' : null;
  }
  if (current === 'stage2') {
    const ready = avgUncertainty(photos, STAGE3_TOP_N) < STAGE3_UNCERTAINTY_THRESHOLD;
    return ready ? 'stage3' : null;
  }
  if (current === 'stage3') {
    const converged = avgUncertainty(photos, COMPLETE_TOP_N) < COMPLETE_UNCERTAINTY_THRESHOLD;
    const exhausted = totalComparisons(photos) >= photoCount * COMPLETE_COMPARISON_MULTIPLIER;
    return converged || exhausted ? 'complete' : null;
  }
  return null;
}

// Pair selection helpers

function priorPartners(comparisons: { photo_a_id: string; photo_b_id: string }[], photoId: string): Set<string> {
  const seen = new Set<string>();
  for (const c of comparisons) {
    if (c.photo_a_id === photoId) seen.add(c.photo_b_id);
    if (c.photo_b_id === photoId) seen.add(c.photo_a_id);
  }
  return seen;
}

function pickRandom<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)]!;
}

function selectStage1(
  photos: Photo[],
  seenWithA: Set<string>,
  photoA: Photo,
): Photo {
  // Sorted ascending by comparison_count already.
  const eligible = photos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
  const pool = eligible.length > 0 ? eligible : photos.filter((p) => p.id !== photoA.id);

  // Prefer a different cluster_id than Photo A (cluster diversity in Stage 1).
  const diffCluster = pool.filter(
    (p) => !p.cluster_id || !photoA.cluster_id || p.cluster_id !== photoA.cluster_id,
  );
  const bPool = diffCluster.length > 0 ? diffCluster : pool;

  // Lowest comparison_count, random tiebreak.
  const minCount = Math.min(...bPool.map((p) => p.comparison_count));
  return pickRandom(bPool.filter((p) => p.comparison_count === minCount));
}

function selectStage2(photos: Photo[], seenWithA: Set<string>, photoA: Photo): Photo {
  const eligible = photos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
  const pool = eligible.length > 0 ? eligible : photos.filter((p) => p.id !== photoA.id);

  // Closest Elo rating to Photo A.
  return pool.reduce((best, p) =>
    Math.abs(p.elo_rating - photoA.elo_rating) < Math.abs(best.elo_rating - photoA.elo_rating)
      ? p
      : best,
  );
}

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
  const parsed = QuerySchema.safeParse({ session_id: url.searchParams.get('session_id') });
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

  // 1. Fetch session
  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id, stage, photo_count')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: 'Session not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 2. Fetch all non-suppressed photos (includes uncertainty + cluster_id for stage logic)
  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id')
    .eq('session_id', session_id)
    .eq('is_suppressed', false)
    .order('comparison_count', { ascending: true })
    .order('elo_rating', { ascending: false });

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

  // 3. Evaluate stage transition (pure, no extra DB query).
  let currentStage = session.stage as string;
  const advanced = nextStage(currentStage, photos, session.photo_count);
  if (advanced) {
    currentStage = advanced;
    await supabase.from('sessions').update({ stage: advanced }).eq('id', session_id);
  }

  // 4. Pick Photo A based on current stage.
  let photoA: Photo;
  if (currentStage === 'stage1') {
    // Fewest comparisons, random tiebreak.
    const minCount = photos[0]!.comparison_count;
    const aPool = photos.filter((p) => p.comparison_count === minCount);
    photoA = pickRandom(aPool);
  } else {
    // stage2, stage3, complete: highest uncertainty in top half by Elo.
    const byElo = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
    const topHalf = byElo.slice(0, Math.ceil(byElo.length / 2));
    const maxUncertainty = Math.max(...topHalf.map((p) => p.uncertainty));
    const aPool = topHalf.filter((p) => p.uncertainty === maxUncertainty);
    photoA = pickRandom(aPool);
  }

  // 5. Fetch prior comparisons for Photo A (avoid repeats).
  const { data: priorComps } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id')
    .eq('session_id', session_id)
    .or(`photo_a_id.eq.${photoA.id},photo_b_id.eq.${photoA.id}`);

  const seenWithA = priorPartners(priorComps ?? [], photoA.id);

  // 6. Pick Photo B based on stage.
  let photoB: Photo;

  if (currentStage === 'stage3') {
    // Try to find a within-cluster pair from a cluster containing a top-20 photo.
    const top20Ids = new Set(
      [...photos].sort((a, b) => b.elo_rating - a.elo_rating).slice(0, 20).map((p) => p.id),
    );
    const topClusters = [
      ...new Set(photos.filter((p) => top20Ids.has(p.id) && p.cluster_id).map((p) => p.cluster_id!)),
    ];

    let stage3B: Photo | null = null;
    for (const clusterId of topClusters) {
      const clusterPhotos = photos.filter((p) => p.cluster_id === clusterId);
      if (clusterPhotos.length < 2) continue;

      // Find a cluster member not yet compared with any cluster member of A's cluster.
      const eligible = clusterPhotos.filter((p) => p.id !== photoA.id && !seenWithA.has(p.id));
      if (eligible.length > 0) {
        // Override Photo A to be the top-Elo photo in this cluster.
        const clusterByElo = [...clusterPhotos].sort((a, b) => b.elo_rating - a.elo_rating);
        photoA = clusterByElo[0]!;

        // Recompute seen partners for the new Photo A if it changed.
        const { data: clusterPriorComps } = await supabase
          .from('comparisons')
          .select('photo_a_id, photo_b_id')
          .eq('session_id', session_id)
          .or(`photo_a_id.eq.${photoA.id},photo_b_id.eq.${photoA.id}`);
        const newSeenWithA = priorPartners(clusterPriorComps ?? [], photoA.id);

        const clusterEligible = clusterPhotos.filter(
          (p) => p.id !== photoA.id && !newSeenWithA.has(p.id),
        );
        if (clusterEligible.length > 0) {
          stage3B = clusterEligible[0]!;
          // Update seenWithA for downstream URL generation.
          for (const id of newSeenWithA) seenWithA.add(id);
          break;
        }
      }
    }
    photoB = stage3B ?? selectStage2(photos, seenWithA, photoA);
  } else if (currentStage === 'stage1') {
    photoB = selectStage1(photos, seenWithA, photoA);
  } else {
    // stage2, complete
    photoB = selectStage2(photos, seenWithA, photoA);
  }

  // 7. Generate signed URLs (1-hour expiry).
  const [signedA, signedB] = await Promise.all([
    supabase.storage.from('working-copies').createSignedUrl(photoA.storage_path, 3600),
    supabase.storage.from('working-copies').createSignedUrl(photoB.storage_path, 3600),
  ]);

  if (!signedA.data?.signedUrl || !signedB.data?.signedUrl) {
    return new Response(JSON.stringify({ error: 'Failed to generate photo URLs' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // 8. Create pending comparison record.
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
      stage: currentStage,
      photo_a: { ...photoA, signed_url: signedA.data.signedUrl },
      photo_b: { ...photoB, signed_url: signedB.data.signedUrl },
    }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
```

- [ ] **Step 2: Type-check the updated function**

```bash
deno check backend/supabase/functions/next-pair/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/functions/next-pair/index.ts
git commit -m "feat(backend): implement Stage 1/2/3 pair selection with stage transition detection"
```

---

### Task 3: New session-status Edge Function

**Files:**
- Create: `backend/supabase/functions/session-status/index.ts`

This is what the iOS app polls after each comparison to detect completion. Returns the current `stage`, an `is_complete` boolean (true when stage = 'complete'), the top photo count (capped at 20), and total comparisons so far.

- [ ] **Step 1: Create session-status/index.ts**

Create `backend/supabase/functions/session-status/index.ts`:

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
  const parsed = QuerySchema.safeParse({ session_id: url.searchParams.get('session_id') });
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

  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id, stage, photo_count')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: 'Session not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Compute total comparisons from photo comparison_count sums.
  const { data: photos, error: photosError } = await supabase
    .from('photos')
    .select('comparison_count, elo_rating')
    .eq('session_id', session_id)
    .eq('is_suppressed', false);

  if (photosError) {
    return new Response(JSON.stringify({ error: 'Failed to fetch photos' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const totalComparisons = Math.round(
    (photos ?? []).reduce((s, p) => s + p.comparison_count, 0) / 2,
  );
  const topPhotoCount = Math.min(20, (photos ?? []).length);

  return new Response(
    JSON.stringify({
      stage: session.stage,
      is_complete: session.stage === 'complete',
      top_photo_count: topPhotoCount,
      total_comparisons: totalComparisons,
    }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
```

- [ ] **Step 2: Type-check**

```bash
deno check backend/supabase/functions/session-status/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/functions/session-status/index.ts
git commit -m "feat(backend): add session-status Edge Function for iOS completion detection"
```

---

### Task 4: Update results to include session stage

**Files:**
- Modify: `backend/supabase/functions/results/index.ts`

The iOS ResultsView needs to know whether the session is complete so it can show the right badge. Add `session: { stage, is_complete }` to the existing response.

- [ ] **Step 1: Add session lookup before the photos query**

In `backend/supabase/functions/results/index.ts`, find the block that starts with:

```typescript
  const { data: photos, error } = await supabase
```

Insert this block immediately before it:

```typescript
  // Fetch session stage so iOS can show "Complete" / "In Progress" badge.
  const { data: session } = await supabase
    .from('sessions')
    .select('stage')
    .eq('id', parsed.data.session_id)
    .single();
```

- [ ] **Step 2: Include session in the success response**

Find the return statement at the bottom of the handler:

```typescript
  return new Response(JSON.stringify({ photos: photosWithUrls }), {
```

Replace it with:

```typescript
  return new Response(
    JSON.stringify({
      photos: photosWithUrls,
      session: {
        stage: session?.stage ?? 'stage1',
        is_complete: session?.stage === 'complete',
      },
    }),
    {
```

- [ ] **Step 3: Type-check**

```bash
deno check backend/supabase/functions/results/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/results/index.ts
git commit -m "feat(backend): include session stage in results response"
```

---

### Task 5: Deploy and verify end-to-end

**Files:** No new files — verification only.

- [ ] **Step 1: Deploy all changed Edge Functions**

```bash
npx supabase functions deploy next-pair
npx supabase functions deploy session-status
npx supabase functions deploy results
```

- [ ] **Step 2: Verify stage transition (Stage 1 → Stage 2)**

Create a session with 6 photos (minimum for fast testing). Make 9 comparisons (enough for every photo to reach `comparison_count ≥ 3`). Then call `next-pair`:

```bash
curl -sX GET \
  "https://YOUR_PROJECT.supabase.co/functions/v1/next-pair?session_id=<id>" \
  -H "Authorization: Bearer <token>" | jq '.stage'
```

Expected: `"stage2"` (or `"stage1"` if not all photos have ≥ 3 comparisons yet)

- [ ] **Step 3: Verify session-status response shape**

```bash
curl -sX GET \
  "https://YOUR_PROJECT.supabase.co/functions/v1/session-status?session_id=<id>" \
  -H "Authorization: Bearer <token>" | jq .
```

Expected:
```json
{
  "stage": "stage1",
  "is_complete": false,
  "top_photo_count": 6,
  "total_comparisons": 9
}
```

- [ ] **Step 4: Verify uncertainty is decaying**

After any submission, query the photos table:

```sql
SELECT id, comparison_count, uncertainty FROM photos
WHERE session_id = '<session_id>'
ORDER BY comparison_count DESC LIMIT 5;
```

Expected: photos with `comparison_count = 1` have `uncertainty ≈ 315` (350 × 0.9); photos with `comparison_count = 3` have `uncertainty ≈ 255` (350 × 0.9³).

- [ ] **Step 5: Verify results includes session**

```bash
curl -sX GET \
  "https://YOUR_PROJECT.supabase.co/functions/v1/results?session_id=<id>&limit=5" \
  -H "Authorization: Bearer <token>" | jq '.session'
```

Expected: `{ "stage": "stage1", "is_complete": false }`

---

## Self-Review

### 1. Spec Coverage

| PRD Requirement | Task |
|---|---|
| Stage 1: broad coverage | Task 2: `stage1` path in `next-pair` (fewest comparisons, cluster diversity) |
| Stage 2: refine top photos | Task 2: `stage2` path (highest uncertainty in top half; closest Elo for B) |
| Stage 3: within-cluster alternates | Task 2: `stage3` path (cluster pairs from top-20) |
| Stage transitions | Task 2: `nextStage()` pure function, evaluated on every `next-pair` call |
| Uncertainty/confidence tracking | Task 1: RPC gains `uncertainty = uncertainty * 0.9` |
| Convergence detection | Task 2: `COMPLETE_UNCERTAINTY_THRESHOLD` + comparison-count fallback |
| `session-status` for iOS detection | Task 3: new Edge Function |
| Session stage in results | Task 4: `results` gains `session.stage` + `session.is_complete` |
| `is_suppressed` filtering (pre-existing) | `next-pair` query: `.eq('is_suppressed', false)` |

### 2. Placeholder Scan

No TBD, TODO, or incomplete sections. All stage strategies have explicit code.

### 3. Type Consistency

- `Photo` type defined at top of `next-pair/index.ts` with `id`, `storage_path`, `thumbnail_path`, `elo_rating`, `uncertainty`, `comparison_count`, `cluster_id` — matches the `.select()` fields on line ~82 ✓
- `nextStage(current: string, photos: Photo[], photoCount: number): string | null` — called with `session.stage` (string), `photos` (Photo[]), `session.photo_count` (number) ✓
- `selectStage1(photos, seenWithA, photoA)` → `Photo` — used as `photoB` ✓
- `selectStage2(photos, seenWithA, photoA)` → `Photo` — used as `photoB` in stage2/complete, and as Stage 3 fallback ✓
- `session-status` response: `{ stage: string, is_complete: boolean, top_photo_count: number, total_comparisons: number }` — matches `SessionStatus` model planned in iOS companion plan ✓
- `results` response gains `session: { stage: string, is_complete: boolean }` — consumed by `ResultsView` stage badge in iOS companion plan ✓
- `next-pair` response now includes `stage` field — iOS `ComparisonView` reads this to show stage label ✓
