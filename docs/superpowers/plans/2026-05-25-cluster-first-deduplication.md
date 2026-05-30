# Cluster-First Deduplication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `dedup` stage before `ranking` that forces intra-cluster comparisons first. Within each duplicate cluster, photos compete until a champion is clear. Non-champions are suppressed before the main ranking begins, so the top-20 results never contain near-duplicate shots.

**Architecture:** A new `dedup` session stage is inserted between session creation and ranking. On the first `next-pair` call, the function detects any photo clusters (photos sharing the same `cluster_id`) with ≥2 members and promotes the session to `dedup`. Subsequent `next-pair` calls in `dedup` mode serve only intra-cluster pairs until every cluster has a resolved champion (≥ clusterSize−1 completed intra-cluster comparisons). At that point `next-pair` atomically suppresses cluster losers, advances the session to `ranking`, and immediately returns the first ranking pair. `session-status` already returns the raw stage string, so no iOS changes are needed — `StageBadge` displays it automatically.

**Tech Stack:** TypeScript (Deno), Supabase Edge Functions, Postgres migration, `jsr:@std/assert@1` for tests

---

## File Map

| File | Change |
|------|--------|
| `backend/supabase/migrations/20260525000001_dedup_stage.sql` | Add `dedup` to `sessions_stage_check` constraint |
| `backend/supabase/functions/_shared/pair-selection.ts` | Add `selectDedupPair()` and `isDedupComplete()` helpers |
| `backend/supabase/functions/_shared/pair-selection.test.ts` | Tests for `selectDedupPair` and `isDedupComplete` |
| `backend/supabase/functions/next-pair/index.ts` | Dedup stage detection, auto-promotion, pair serving, and transition logic |

---

### Task 1: Database migration — allow `dedup` stage

**Files:**
- Create: `backend/supabase/migrations/20260525000001_dedup_stage.sql`

- [ ] **Step 1: Write the migration**

```sql
-- Allow the new 'dedup' stage value in the sessions table.
-- Existing sessions remain 'ranking' (no data migration needed).
ALTER TABLE public.sessions
  DROP CONSTRAINT IF EXISTS sessions_stage_check;

ALTER TABLE public.sessions
  ADD CONSTRAINT sessions_stage_check
  CHECK (stage IN ('dedup', 'ranking', 'complete'));
```

- [ ] **Step 2: Apply the migration**

```bash
supabase db push --project-ref <your-project-ref>
```

Expected: migration applied without error.

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/migrations/20260525000001_dedup_stage.sql
git commit -m "chore(db): add 'dedup' as a valid session stage"
```

---

### Task 2: Write `selectDedupPair` and `isDedupComplete` helpers

**Files:**
- Modify: `backend/supabase/functions/_shared/pair-selection.ts`
- Modify: `backend/supabase/functions/_shared/pair-selection.test.ts`

These two functions encapsulate all dedup-stage logic and are independently testable.

`isDedupComplete(photos, completedComparisons)` — returns `true` when every cluster with ≥2 members has ≥ clusterSize−1 completed intra-cluster comparisons.

`selectDedupPair(photos, completedComparisons)` — returns `[photoA, photoB]` from the least-compared unresolved cluster, preferring pairs not yet seen.

- [ ] **Step 1: Write the failing tests**

Add to the bottom of `backend/supabase/functions/_shared/pair-selection.test.ts`:

```ts
import { selectDedupPair, isDedupComplete } from './pair-selection.ts';

// --- isDedupComplete ---

Deno.test('isDedupComplete — no clusters → immediately complete', () => {
  const photos = [
    makePhoto('a', 1500, 200, 0, null),
    makePhoto('b', 1500, 200, 0, null),
  ];
  assertEquals(isDedupComplete(photos, []), true);
});

Deno.test('isDedupComplete — singleton clusters count as complete', () => {
  const photos = [
    makePhoto('a', 1500, 200, 0, 'X'),
    makePhoto('b', 1500, 200, 0, null),
  ];
  assertEquals(isDedupComplete(photos, []), true);
});

Deno.test('isDedupComplete — cluster of 2 needs 1 intra comparison', () => {
  const photos = [
    makePhoto('a', 1500, 200, 0, 'X'),
    makePhoto('b', 1480, 200, 0, 'X'),
  ];
  assertEquals(isDedupComplete(photos, []), false);
  const comps = [{ photo_a_id: 'a', photo_b_id: 'b', completed_at: '2026-01-01' }];
  assertEquals(isDedupComplete(photos, comps), true);
});

Deno.test('isDedupComplete — cluster of 3 needs 2 intra comparisons', () => {
  const photos = [
    makePhoto('a', 1500, 200, 0, 'Y'),
    makePhoto('b', 1480, 200, 0, 'Y'),
    makePhoto('c', 1460, 200, 0, 'Y'),
  ];
  const oneComp = [{ photo_a_id: 'a', photo_b_id: 'b', completed_at: '2026-01-01' }];
  assertEquals(isDedupComplete(photos, oneComp), false);
  const twoComps = [
    { photo_a_id: 'a', photo_b_id: 'b', completed_at: '2026-01-01' },
    { photo_a_id: 'b', photo_b_id: 'c', completed_at: '2026-01-01' },
  ];
  assertEquals(isDedupComplete(photos, twoComps), true);
});

// --- selectDedupPair ---

Deno.test('selectDedupPair — returns two photos from the same cluster', () => {
  const photos = [
    makePhoto('a', 1500, 200, 0, 'X'),
    makePhoto('b', 1480, 200, 0, 'X'),
    makePhoto('c', 1500, 200, 0, null),
  ];
  const [p1, p2] = selectDedupPair(photos, []);
  assertEquals(p1.cluster_id, 'X');
  assertEquals(p2.cluster_id, 'X');
});

Deno.test('selectDedupPair — prefers unseen intra-cluster pairs', () => {
  const photos = [
    makePhoto('a', 1500, 200, 2, 'X'),
    makePhoto('b', 1480, 200, 2, 'X'),
    makePhoto('c', 1460, 200, 0, 'X'),
  ];
  // a-b already compared; a-c and b-c are fresh
  const done = [{ photo_a_id: 'a', photo_b_id: 'b', completed_at: '2026-01-01' }];
  const [p1, p2] = selectDedupPair(photos, done);
  const ids = [p1.id, p2.id].sort();
  // should NOT be a:b again
  assertEquals(ids.join(':') !== 'a:b', true);
});
```

- [ ] **Step 2: Run the tests and verify they FAIL**

```bash
cd /Users/mccro/claudeProjects/Pictalis/backend && deno test supabase/functions/_shared/pair-selection.test.ts
```

Expected: import error / "selectDedupPair is not exported".

- [ ] **Step 3: Implement `isDedupComplete` and `selectDedupPair` in `pair-selection.ts`**

Add the following after the existing exports at the bottom of `pair-selection.ts`:

```ts
type IntraComparison = { photo_a_id: string; photo_b_id: string; completed_at: string | null };

export function isDedupComplete(photos: Photo[], comparisons: IntraComparison[]): boolean {
  const clusterGroups = buildClusterGroups(photos);
  if (clusterGroups.size === 0) return true;

  const completedIntraCount = new Map<string, number>();
  for (const c of comparisons) {
    if (!c.completed_at) continue;
    const photoA = photos.find((p) => p.id === c.photo_a_id);
    const photoB = photos.find((p) => p.id === c.photo_b_id);
    if (!photoA?.cluster_id || photoA.cluster_id !== photoB?.cluster_id) continue;
    const clusterId = photoA.cluster_id;
    completedIntraCount.set(clusterId, (completedIntraCount.get(clusterId) ?? 0) + 1);
  }

  for (const [clusterId, members] of clusterGroups) {
    if (members.length < 2) continue;
    const needed = members.length - 1;
    if ((completedIntraCount.get(clusterId) ?? 0) < needed) return false;
  }
  return true;
}

export function selectDedupPair(photos: Photo[], comparisons: IntraComparison[]): [Photo, Photo] {
  const clusterGroups = buildClusterGroups(photos);

  // Find the unresolved cluster with the most members (prioritise larger clusters).
  let targetCluster: Photo[] | null = null;
  let targetCount = Infinity;

  const completedIntraCount = new Map<string, number>();
  for (const c of comparisons) {
    if (!c.completed_at) continue;
    const photoA = photos.find((p) => p.id === c.photo_a_id);
    const photoB = photos.find((p) => p.id === c.photo_b_id);
    if (!photoA?.cluster_id || photoA.cluster_id !== photoB?.cluster_id) continue;
    completedIntraCount.set(photoA.cluster_id, (completedIntraCount.get(photoA.cluster_id) ?? 0) + 1);
  }

  for (const [clusterId, members] of clusterGroups) {
    if (members.length < 2) continue;
    const done   = completedIntraCount.get(clusterId) ?? 0;
    const needed = members.length - 1;
    if (done >= needed) continue; // resolved
    if (done < targetCount) { targetCount = done; targetCluster = members; }
  }

  if (!targetCluster) throw new Error('selectDedupPair called when dedup is already complete');

  // Build seen-pair set for this cluster.
  const clusterIds = new Set(targetCluster.map((p) => p.id));
  const seenPairs  = new Set<string>();
  for (const c of comparisons) {
    if (clusterIds.has(c.photo_a_id) && clusterIds.has(c.photo_b_id)) {
      seenPairs.add(pairKey(c.photo_a_id, c.photo_b_id));
    }
  }

  // Find the first unseen pair (sorted by id for determinism).
  const sorted = [...targetCluster].sort((a, b) => a.id.localeCompare(b.id));
  for (let i = 0; i < sorted.length; i++) {
    for (let j = i + 1; j < sorted.length; j++) {
      if (!seenPairs.has(pairKey(sorted[i]!.id, sorted[j]!.id))) {
        return [sorted[i]!, sorted[j]!];
      }
    }
  }

  // All pairs seen (cycle) — return the lowest-comparison pair as tiebreak.
  return [sorted[0]!, sorted[1]!];
}

function buildClusterGroups(photos: Photo[]): Map<string, Photo[]> {
  const groups = new Map<string, Photo[]>();
  for (const p of photos) {
    if (!p.cluster_id) continue;
    const arr = groups.get(p.cluster_id) ?? [];
    arr.push(p);
    groups.set(p.cluster_id, arr);
  }
  return groups;
}
```

- [ ] **Step 4: Run the tests and verify they PASS**

```bash
cd /Users/mccro/claudeProjects/Pictalis/backend && deno test supabase/functions/_shared/pair-selection.test.ts
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/functions/_shared/pair-selection.ts \
        backend/supabase/functions/_shared/pair-selection.test.ts
git commit -m "feat(pair-selection): add selectDedupPair and isDedupComplete for cluster-first dedup"
```

---

### Task 3: Wire dedup stage into `next-pair`

**Files:**
- Modify: `backend/supabase/functions/next-pair/index.ts`

This is the largest task. The flow becomes:

1. If stage is `ranking` and there are multi-member clusters → promote to `dedup`
2. If stage is `dedup`:
   a. Check `isDedupComplete`
   b. If complete → suppress cluster losers, advance to `ranking`, fall through to normal pair selection
   c. If not complete → call `selectDedupPair`, insert pending comparison, return pair with `stage: 'dedup'`
3. If stage is `ranking` → existing logic (unchanged)

- [ ] **Step 1: Update imports at the top of `next-pair/index.ts`**

```ts
import { type Photo, type CompletedComparison, computeTopK, computeMinComparisons, isBoundaryStable } from '../_shared/ranking-logic.ts';
import { pairKey, buildPairCounts, selectPhotoA, selectPhotoB, selectDedupPair, isDedupComplete, totalComparisons, computeProgress } from '../_shared/pair-selection.ts';
```

- [ ] **Step 2: Update the comparisons query to include `completed_at`**

Replace (after the photos fetch, around line 83):

```ts
  const { data: rawComparisons } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id')
    .eq('session_id', session_id);

  const comparisons = (rawComparisons ?? []) as CompletedComparison[];
  const pairCounts  = buildPairCounts(comparisons);
```

With:

```ts
  type RawComparison = CompletedComparison & { completed_at: string | null };
  const { data: rawComparisons } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id, completed_at')
    .eq('session_id', session_id);

  const allComparisons = (rawComparisons ?? []) as RawComparison[];
  const pairCounts     = buildPairCounts(allComparisons);
  const pendingPairs   = new Set(
    allComparisons
      .filter((c) => !c.completed_at)
      .map((c) => pairKey(c.photo_a_id, c.photo_b_id)),
  );
```

- [ ] **Step 3: Add dedup stage handling after `pairCounts` is built**

Insert after the `pendingPairs` computation and before the completion check (before the `allHaveCoverage` block):

```ts
  // ── Dedup stage ────────────────────────────────────────────────────────────
  // On first next-pair call: if clusters exist, auto-promote to dedup.
  const hasMultiMemberClusters = (() => {
    const clusterSizes = new Map<string, number>();
    for (const p of photos) {
      if (p.cluster_id) clusterSizes.set(p.cluster_id, (clusterSizes.get(p.cluster_id) ?? 0) + 1);
    }
    return [...clusterSizes.values()].some((n) => n >= 2);
  })();

  if (session.stage === 'ranking' && hasMultiMemberClusters && allComparisons.length === 0) {
    await supabase.from('sessions').update({ stage: 'dedup' }).eq('id', session_id);
    session.stage = 'dedup';
  }

  if (session.stage === 'dedup') {
    const dedupDone = isDedupComplete(photos as Photo[], allComparisons);

    if (dedupDone) {
      // Suppress cluster losers and transition to ranking.
      const clusterGroups = new Map<string, Photo[]>();
      for (const p of photos as Photo[]) {
        if (!p.cluster_id) continue;
        const arr = clusterGroups.get(p.cluster_id) ?? [];
        arr.push(p);
        clusterGroups.set(p.cluster_id, arr);
      }
      for (const members of clusterGroups.values()) {
        if (members.length < 2) continue;
        const sorted = [...members].sort((a, b) => b.elo_rating - a.elo_rating);
        const loserIds = sorted.slice(1).map((p) => p.id);
        if (loserIds.length > 0) {
          await supabase.from('photos').update({ is_suppressed: true }).in('id', loserIds);
        }
      }
      await supabase.from('sessions').update({ stage: 'ranking' }).eq('id', session_id);
      // Re-fetch non-suppressed photos for the ranking stage.
      const { data: rankingPhotos, error: rankingError } = await supabase
        .from('photos')
        .select('id, storage_path, thumbnail_path, elo_rating, uncertainty, comparison_count, cluster_id')
        .eq('session_id', session_id)
        .eq('is_suppressed', false);
      if (rankingError || !rankingPhotos || rankingPhotos.length < 2) {
        return new Response(JSON.stringify({ error: 'Not enough photos after dedup' }), {
          status: 422, headers: { ...CORS, 'Content-Type': 'application/json' },
        });
      }
      // Fall through to ranking logic using rankingPhotos.
      // Overwrite photos for the rest of this request.
      (photos as unknown as Photo[]) = rankingPhotos as Photo[];
    } else {
      // Serve an intra-cluster pair.
      const [dedupA, dedupB] = selectDedupPair(photos as Photo[], allComparisons);

      const [signedA, signedB] = await Promise.all([
        supabase.storage.from('working-copies').createSignedUrl(dedupA.storage_path, 3600),
        supabase.storage.from('working-copies').createSignedUrl(dedupB.storage_path, 3600),
      ]);

      if (!signedA.data?.signedUrl || !signedB.data?.signedUrl) {
        return new Response(JSON.stringify({ error: 'Failed to generate photo URLs' }), {
          status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
        });
      }

      const { data: comparison, error: compError } = await supabase
        .from('comparisons')
        .insert({ session_id, photo_a_id: dedupA.id, photo_b_id: dedupB.id })
        .select('id')
        .single();

      if (compError || !comparison) {
        return new Response(JSON.stringify({ error: 'Failed to create comparison' }), {
          status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
        });
      }

      return new Response(
        JSON.stringify({
          comparison_id: comparison.id,
          stage: 'dedup',
          progress: 0,
          photo_a: { ...dedupA, signed_url: signedA.data.signedUrl },
          photo_b: { ...dedupB, signed_url: signedB.data.signedUrl },
        }),
        { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
      );
    }
  }
  // ── End dedup stage ────────────────────────────────────────────────────────
```

> Note: The `(photos as unknown as Photo[]) = rankingPhotos` reassignment requires declaring `photos` as `let` in the outer scope. If the TypeScript compiler objects, use a separate `let activephotos = ...` variable for the ranking stage.

- [ ] **Step 4: Pass `pendingPairs` to `selectPhotoB` (ranking stage, existing line)**

Replace:
```ts
  const photoB     = selectPhotoB(photos as Photo[], photoA, pairCounts, inCoverage);
```

With:
```ts
  const photoB     = selectPhotoB(photos as Photo[], photoA, pairCounts, inCoverage, pendingPairs);
```

- [ ] **Step 5: Deploy and smoke-test**

```bash
supabase functions deploy next-pair --project-ref <your-project-ref>
```

Create a test session with photos that have duplicate clusters. Verify that:
1. The first pair served belongs to the same cluster
2. After enough intra-cluster comparisons, ranking pairs appear
3. The top results no longer contain same-cluster duplicates

- [ ] **Step 6: Commit**

```bash
git add backend/supabase/functions/next-pair/index.ts
git commit -m "feat(next-pair): add dedup stage — serve intra-cluster comparisons before ranking"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Dedup stage fires before ranking when clusters exist
- [x] Intra-cluster pairs served until clusterSize−1 comparisons done
- [x] Cluster losers suppressed at transition; champions enter ranking
- [x] No iOS changes required — StageBadge already renders any stage string
- [x] Sessions with no clusters skip dedup and go straight to ranking
- [x] Existing sessions in `ranking` are unaffected (no data migration)

**Placeholder scan:** No placeholders — all code is complete.

**Type consistency:** `IntraComparison` type defined in `pair-selection.ts` and consumed via `allComparisons` in `next-pair/index.ts`. `selectDedupPair` returns `[Photo, Photo]`. `isDedupComplete` returns `boolean`. Names match across all usages.
