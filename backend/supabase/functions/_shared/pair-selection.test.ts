import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  buildPairCounts,
  computeProgress,
  pairKey,
  selectPhotoA,
  selectPhotoB,
  totalComparisons,
} from "./pair-selection.ts";
import { type Photo } from "./ranking-logic.ts";

function makePhoto(
  id: string,
  elo: number,
  uncertainty: number,
  comparisons: number,
  clusterId: string | null = null,
): Photo {
  return {
    id,
    storage_path: "",
    thumbnail_path: null,
    elo_rating: elo,
    uncertainty,
    comparison_count: comparisons,
    cluster_id: clusterId,
  };
}

// --- pairKey ---

Deno.test("pairKey — order-invariant", () => {
  assertEquals(pairKey("a", "b"), pairKey("b", "a"));
});

Deno.test("pairKey — same id both sides", () => {
  assertEquals(pairKey("x", "x"), "x:x");
});

// --- buildPairCounts ---

Deno.test("buildPairCounts — single comparison counted once", () => {
  const counts = buildPairCounts([{ photo_a_id: "a", photo_b_id: "b" }]);
  assertEquals(counts.get(pairKey("a", "b")), 1);
});

Deno.test("buildPairCounts — same pair counted multiple times", () => {
  const counts = buildPairCounts([
    { photo_a_id: "a", photo_b_id: "b" },
    { photo_a_id: "b", photo_b_id: "a" },
    { photo_a_id: "a", photo_b_id: "b" },
  ]);
  assertEquals(counts.get(pairKey("a", "b")), 3);
});

Deno.test("buildPairCounts — empty input → empty map", () => {
  assertEquals(buildPairCounts([]).size, 0);
});

// --- selectPhotoA ---

Deno.test("selectPhotoA — coverage floor: under-compared photo always wins", () => {
  const photos = [
    makePhoto("under", 1200, 300, 0),
    makePhoto("top", 1600, 50, 10),
  ];
  const selected = selectPhotoA(photos, 2, 3);
  assertEquals(selected.id, "under");
});

Deno.test("selectPhotoA — coverage floor: lowest comparison count wins among under-compared", () => {
  const photos = [
    makePhoto("a", 1500, 200, 0),
    makePhoto("b", 1500, 200, 1),
    makePhoto("c", 1600, 200, 2),
  ];
  // minComparisons=3, all are under-compared; a has lowest count
  const selected = selectPhotoA(photos, 2, 3);
  assertEquals(selected.id, "a");
});

Deno.test("selectPhotoA — when all covered, returns a photo from the set", () => {
  const photos = [
    makePhoto("a", 1600, 50, 5),
    makePhoto("b", 1500, 300, 5),
    makePhoto("c", 1400, 150, 5),
  ];
  const selected = selectPhotoA(photos, 2, 3);
  const ids = photos.map((p) => p.id);
  assertEquals(ids.includes(selected.id), true);
});

// --- selectPhotoB ---

Deno.test("selectPhotoB — never selects photoA itself", () => {
  const photos = [
    makePhoto("a", 1500, 200, 3),
    makePhoto("b", 1480, 200, 3),
    makePhoto("c", 1460, 200, 3),
  ];
  const photoA = photos[0]!;
  const selected = selectPhotoB(photos, photoA, new Map(), false);
  assertNotEquals(selected.id, photoA.id);
});

Deno.test("selectPhotoB — cluster penalty: prefers cross-cluster over same-cluster", () => {
  // photoA in cluster X; b in cluster X (penalty), c in cluster Y (bonus)
  // Use WEIGHTS_POST where cluster weight is 0.05 and photos otherwise identical
  const photoA = makePhoto("a", 1500, 200, 3, "X");
  const sameCluster = makePhoto("b", 1500, 200, 3, "X");
  const crossCluster = makePhoto("c", 1500, 200, 3, "Y");
  const photos = [photoA, sameCluster, crossCluster];
  const selected = selectPhotoB(photos, photoA, new Map(), false);
  assertEquals(selected.id, "c");
});

Deno.test("selectPhotoB — repeat penalty: avoids pairs seen many times", () => {
  const photoA = makePhoto("a", 1500, 200, 3);
  const repeated = makePhoto("b", 1500, 200, 3);
  const fresh = makePhoto("c", 1500, 200, 3);
  const pairCounts = new Map([[pairKey("a", "b"), 5]]);
  const selected = selectPhotoB(
    [photoA, repeated, fresh],
    photoA,
    pairCounts,
    false,
  );
  assertEquals(selected.id, "c");
});

Deno.test("selectPhotoB — coverage mode uses WEIGHTS_COVER (freshness-dominant)", () => {
  // fresh photo has lowest comparison count → should win in coverage mode
  // both b and c have elo close to a, but c is fresher
  const photoA = makePhoto("a", 1500, 200, 5);
  const stale = makePhoto("b", 1490, 200, 10);
  const fresher = makePhoto("c", 1510, 200, 0);
  const selected = selectPhotoB(
    [photoA, stale, fresher],
    photoA,
    new Map(),
    true,
  );
  assertEquals(selected.id, "c");
});

Deno.test("selectPhotoB — hard-excludes pending pairs even when they score best", () => {
  // pending and eligible are identical in every scoring dimension;
  // only the pending hard-exclusion should distinguish them.
  const photoA = makePhoto("a", 1500, 200, 3);
  const pending = makePhoto("b", 1500, 200, 3);
  const eligible = makePhoto("c", 1500, 200, 3);
  const pendingPairs = new Set([pairKey("a", "b")]);
  const selected = selectPhotoB(
    [photoA, pending, eligible],
    photoA,
    new Map(),
    false,
    pendingPairs,
  );
  assertEquals(selected.id, "c");
});

Deno.test("selectPhotoB — falls back to full candidate pool when all candidates are pending", () => {
  // Only one other photo; it happens to be pending.
  // Must still return it (there's no other choice) rather than throwing.
  const photoA = makePhoto("a", 1500, 200, 3);
  const only = makePhoto("b", 1500, 200, 3);
  const pendingPairs = new Set([pairKey("a", "b")]);
  const selected = selectPhotoB(
    [photoA, only],
    photoA,
    new Map(),
    false,
    pendingPairs,
  );
  assertEquals(selected.id, "b");
});

// --- totalComparisons ---

Deno.test("totalComparisons — sums comparison_count / 2", () => {
  const photos = [makePhoto("a", 1500, 200, 4), makePhoto("b", 1500, 200, 4)];
  assertEquals(totalComparisons(photos), 4);
});

Deno.test("totalComparisons — empty array → 0", () => {
  assertEquals(totalComparisons([]), 0);
});

// --- computeProgress ---

Deno.test("computeProgress — full uncertainty (350) → 0", () => {
  const photos = [makePhoto("a", 1600, 350, 0), makePhoto("b", 1500, 350, 0)];
  assertEquals(computeProgress(photos, 1), 0);
});

Deno.test("computeProgress — zero uncertainty → clamped to 1", () => {
  const photos = [makePhoto("a", 1600, 0, 10), makePhoto("b", 1500, 0, 10)];
  assertEquals(computeProgress(photos, 1), 1);
});

Deno.test("computeProgress — partial uncertainty → between 0 and 1", () => {
  const photos = [makePhoto("a", 1600, 175, 5), makePhoto("b", 1500, 175, 5)];
  const progress = computeProgress(photos, 1);
  assertEquals(progress > 0 && progress < 1, true);
});

Deno.test("computeProgress — clamped to 1 even if uncertainty is negative (defensive)", () => {
  const photos = [makePhoto("a", 1600, -50, 10)];
  assertEquals(computeProgress(photos, 1), 1);
});

// ─── isDedupComplete ────────────────────────────────────────────────────────

import { isDedupComplete, selectDedupPair } from "./pair-selection.ts";

Deno.test("isDedupComplete — no clusters → immediately complete", () => {
  const photos = [
    makePhoto("a", 1500, 200, 0, null),
    makePhoto("b", 1500, 200, 0, null),
  ];
  assertEquals(isDedupComplete(photos, []), true);
});

Deno.test("isDedupComplete — singleton clusters count as complete", () => {
  const photos = [
    makePhoto("a", 1500, 200, 0, "X"),
    makePhoto("b", 1500, 200, 0, null),
  ];
  assertEquals(isDedupComplete(photos, []), true);
});

Deno.test("isDedupComplete — cluster of 2 needs 1 intra comparison", () => {
  const photos = [
    makePhoto("a", 1500, 200, 0, "X"),
    makePhoto("b", 1480, 200, 0, "X"),
  ];
  assertEquals(isDedupComplete(photos, []), false);
  const comps = [{
    photo_a_id: "a",
    photo_b_id: "b",
    completed_at: "2026-01-01",
  }];
  assertEquals(isDedupComplete(photos, comps), true);
});

Deno.test("isDedupComplete — cluster of 3 needs 2 intra comparisons", () => {
  const photos = [
    makePhoto("a", 1500, 200, 0, "Y"),
    makePhoto("b", 1480, 200, 0, "Y"),
    makePhoto("c", 1460, 200, 0, "Y"),
  ];
  const oneComp = [{
    photo_a_id: "a",
    photo_b_id: "b",
    completed_at: "2026-01-01",
  }];
  assertEquals(isDedupComplete(photos, oneComp), false);
  const twoComps = [
    { photo_a_id: "a", photo_b_id: "b", completed_at: "2026-01-01" },
    { photo_a_id: "b", photo_b_id: "c", completed_at: "2026-01-01" },
  ];
  assertEquals(isDedupComplete(photos, twoComps), true);
});

// ─── selectDedupPair ────────────────────────────────────────────────────────

Deno.test("selectDedupPair — returns two photos from the same cluster", () => {
  const photos = [
    makePhoto("a", 1500, 200, 0, "X"),
    makePhoto("b", 1480, 200, 0, "X"),
    makePhoto("c", 1500, 200, 0, null),
  ];
  const [p1, p2] = selectDedupPair(photos, []);
  assertEquals(p1.cluster_id, "X");
  assertEquals(p2.cluster_id, "X");
});

Deno.test("selectDedupPair — prefers unseen intra-cluster pairs", () => {
  const photos = [
    makePhoto("a", 1500, 200, 2, "X"),
    makePhoto("b", 1480, 200, 2, "X"),
    makePhoto("c", 1460, 200, 0, "X"),
  ];
  // a-b already compared; a-c and b-c are fresh
  const done = [{
    photo_a_id: "a",
    photo_b_id: "b",
    completed_at: "2026-01-01",
  }];
  const [p1, p2] = selectDedupPair(photos, done);
  const ids = [p1.id, p2.id].sort();
  // should NOT be a:b again
  assertEquals(ids.join(":") !== "a:b", true);
});
