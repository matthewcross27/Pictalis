# Fix Duplicate Comparisons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hard-exclude pending (unsubmitted) comparisons from pair re-selection so users never see the same two photos twice in a row.

**Architecture:** The root cause is in `selectPhotoB` — it applies only a soft exponential penalty (`Math.exp(-count)`) to repeated pairs, which is insufficient to prevent re-selection when the same pair scores well on Elo and freshness. The fix adds a `pendingPairs: Set<string>` parameter that hard-filters any candidate that already has an in-flight comparison with photoA. The `next-pair` function already fetches all comparisons; we just need to also fetch `completed_at` and split pending from completed.

**Tech Stack:** TypeScript (Deno), Supabase Edge Functions, `jsr:@std/assert@1` for tests

---

## File Map

| File | Change |
|------|--------|
| `backend/supabase/functions/_shared/pair-selection.ts` | Add `pendingPairs` param to `selectPhotoB`; hard-filter candidates |
| `backend/supabase/functions/next-pair/index.ts` | Fetch `completed_at`, build `pendingPairs` set, pass to `selectPhotoB` |
| `backend/supabase/functions/_shared/pair-selection.test.ts` | Add test for pending pair hard-exclusion |

---

### Task 1: Update `selectPhotoB` to accept and respect `pendingPairs`

**Files:**
- Modify: `backend/supabase/functions/_shared/pair-selection.ts:47-75`

- [ ] **Step 1: Write the failing test first**

Add to `backend/supabase/functions/_shared/pair-selection.test.ts`, after the existing `selectPhotoB` tests:

```ts
Deno.test('selectPhotoB — hard-excludes pending pairs even when they score best', () => {
  // pending and eligible are identical in every scoring dimension;
  // only the pending hard-exclusion should distinguish them.
  const photoA   = makePhoto('a', 1500, 200, 3);
  const pending  = makePhoto('b', 1500, 200, 3);
  const eligible = makePhoto('c', 1500, 200, 3);
  const pendingPairs = new Set([pairKey('a', 'b')]);
  const selected = selectPhotoB([photoA, pending, eligible], photoA, new Map(), false, pendingPairs);
  assertEquals(selected.id, 'c');
});

Deno.test('selectPhotoB — falls back to full candidate pool when all candidates are pending', () => {
  // Only one other photo; it happens to be pending.
  // Must still return it (there's no other choice) rather than throwing.
  const photoA  = makePhoto('a', 1500, 200, 3);
  const only    = makePhoto('b', 1500, 200, 3);
  const pendingPairs = new Set([pairKey('a', 'b')]);
  const selected = selectPhotoB([photoA, only], photoA, new Map(), false, pendingPairs);
  assertEquals(selected.id, 'b');
});
```

- [ ] **Step 2: Run the tests and verify they FAIL**

```bash
cd /Users/mccro/claudeProjects/Pictalis/backend && deno test supabase/functions/_shared/pair-selection.test.ts
```

Expected output: two failing tests with "Argument of type" or similar TypeError (wrong arity).

- [ ] **Step 3: Update `selectPhotoB` in `pair-selection.ts`**

Replace the entire `selectPhotoB` function (lines 47–75) with:

```ts
export function selectPhotoB(
  photos: Photo[],
  photoA: Photo,
  pairCounts: Map<string, number>,
  inCoverage: boolean,
  pendingPairs: Set<string> = new Set(),
): Photo {
  const allCandidates = photos.filter((p) => p.id !== photoA.id);
  // Hard-exclude pending pairs; fall back to full pool if no eligible candidates remain.
  const candidates = allCandidates.filter(
    (p) => !pendingPairs.has(pairKey(photoA.id, p.id)),
  );
  const pool = candidates.length > 0 ? candidates : allCandidates;

  const w = inCoverage ? WEIGHTS_COVER : WEIGHTS_POST;

  const maxEloDiff = Math.max(...pool.map((c) => Math.abs(c.elo_rating - photoA.elo_rating)), 1);
  const maxCount   = Math.max(...pool.map((c) => c.comparison_count), 1);

  let best = -Infinity;
  let bestB = pool[0]!;
  for (const b of pool) {
    const eloSim  = 1 - Math.abs(b.elo_rating - photoA.elo_rating) / maxEloDiff;
    const overlap = (b.uncertainty + photoA.uncertainty) / 700;
    const fresh   = 1 - b.comparison_count / maxCount;
    const count   = pairCounts.get(pairKey(photoA.id, b.id)) ?? 0;
    const repeat  = Math.exp(-count);
    const cluster = !b.cluster_id || !photoA.cluster_id || b.cluster_id !== photoA.cluster_id ? 1 : 0;

    const score = w.elo * eloSim + w.overlap * overlap + w.fresh * fresh
                + w.repeat * repeat + w.cluster * cluster;

    if (score > best) { best = score; bestB = b; }
  }
  return bestB;
}
```

- [ ] **Step 4: Run the tests and verify they PASS**

```bash
cd /Users/mccro/claudeProjects/Pictalis/backend && deno test supabase/functions/_shared/pair-selection.test.ts
```

Expected output: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/functions/_shared/pair-selection.ts \
        backend/supabase/functions/_shared/pair-selection.test.ts
git commit -m "feat(pair-selection): hard-exclude in-flight pending pairs from selectPhotoB"
```

---

### Task 2: Feed `pendingPairs` from `next-pair`

**Files:**
- Modify: `backend/supabase/functions/next-pair/index.ts:83-108`

The comparisons query currently fetches only `photo_a_id, photo_b_id`. We need `completed_at` to identify pending entries.

- [ ] **Step 1: Update the comparisons query (line 83)**

Replace:
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
  const { data: rawComparisons } = await supabase
    .from('comparisons')
    .select('photo_a_id, photo_b_id, completed_at')
    .eq('session_id', session_id);

  type RawComparison = CompletedComparison & { completed_at: string | null };
  const allComparisons = (rawComparisons ?? []) as RawComparison[];
  const pairCounts     = buildPairCounts(allComparisons);
  const pendingPairs   = new Set(
    allComparisons
      .filter((c) => !c.completed_at)
      .map((c) => pairKey(c.photo_a_id, c.photo_b_id)),
  );
```

- [ ] **Step 2: Pass `pendingPairs` to `selectPhotoB` (line 107)**

Replace:
```ts
  const photoB     = selectPhotoB(photos as Photo[], photoA, pairCounts, inCoverage);
```

With:
```ts
  const photoB     = selectPhotoB(photos as Photo[], photoA, pairCounts, inCoverage, pendingPairs);
```

- [ ] **Step 3: Verify `pairKey` is already imported**

Check the import at the top of `next-pair/index.ts`. It currently imports from `pair-selection.ts`:

```ts
import { buildPairCounts, selectPhotoA, selectPhotoB, totalComparisons, computeProgress } from '../_shared/pair-selection.ts';
```

Add `pairKey` to that import:

```ts
import { pairKey, buildPairCounts, selectPhotoA, selectPhotoB, totalComparisons, computeProgress } from '../_shared/pair-selection.ts';
```

- [ ] **Step 4: Deploy and smoke-test**

```bash
supabase functions deploy next-pair --project-ref <your-project-ref>
```

Then run a session and verify that after choosing a photo, the next pair is never the same two photos again.

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/functions/next-pair/index.ts
git commit -m "fix(next-pair): pass pending pairs to selectPhotoB to prevent same-pair re-selection"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Same pair no longer appears twice in a row (pending pair hard-excluded)
- [x] Fallback: n=2 sessions still work (all-pending fallback to full pool)
- [x] pairCounts still uses all comparisons (completed + pending) for the soft repeat penalty — this is correct and unchanged

**Placeholder scan:** No placeholders — all code is complete.

**Type consistency:** `pendingPairs: Set<string>` consistent between `pair-selection.ts` and `next-pair/index.ts`. Default `= new Set()` keeps all existing callers passing tests without changes.
