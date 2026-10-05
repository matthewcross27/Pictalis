import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  comparisonBudget,
  COMPARISONS_PER_PHOTO_BUDGET,
  computeMinComparisons,
  DEFAULT_TOP_K,
  hasFullCoverage,
  isBoundaryStable,
  isSessionComplete,
  resolveTopKAndMinComparisons,
} from './ranking-logic.ts';
import { makePhoto } from './test-helpers.ts';

// --- computeMinComparisons ---

Deno.test('computeMinComparisons — floor of 1 when n equals topK', () => {
  assertEquals(computeMinComparisons(5, 5), 1);
});

Deno.test('computeMinComparisons — n=100, topK=25 → ceil(log2(4)+1) = 3', () => {
  assertEquals(computeMinComparisons(100, 25), 3);
});

Deno.test('computeMinComparisons — n=200, topK=35 → correct ceil', () => {
  const expected = Math.max(1, Math.ceil(Math.log2(200 / 35) + 1));
  assertEquals(computeMinComparisons(200, 35), expected);
});

// --- resolveTopKAndMinComparisons ---

Deno.test('resolveTopKAndMinComparisons — no top_k → default of 15, not scaled to the batch', () => {
  assertEquals(DEFAULT_TOP_K, 15);
  const result = resolveTopKAndMinComparisons({ top_k: null }, 253);
  assertEquals(result, { topK: 15, minComparisons: computeMinComparisons(253, 15) });
});

Deno.test('resolveTopKAndMinComparisons — explicit top_k → used as-is', () => {
  const result = resolveTopKAndMinComparisons({ top_k: 10 }, 100);
  assertEquals(result, { topK: 10, minComparisons: computeMinComparisons(100, 10) });
});

Deno.test('resolveTopKAndMinComparisons — floor follows the pool, not the batch (F1)', () => {
  // 253-photo batch culled to 76 kept photos. The old engine sized the floor from the
  // batch: topK 40, ceil(log2(253/40)+1) = 4 comparisons per photo.
  const culled = resolveTopKAndMinComparisons({ top_k: null }, 76);
  assertEquals(culled.topK, 15);
  assertEquals(culled.minComparisons, 4);
  // A pool that already fits the shortlist needs only a token pass.
  assertEquals(resolveTopKAndMinComparisons({ top_k: null }, 15).minComparisons, 1);
  assertEquals(resolveTopKAndMinComparisons({ top_k: null }, 10).minComparisons, 1);
});

// --- isBoundaryStable ---

Deno.test('isBoundaryStable — empty array returns true (vacuous truth guard)', () => {
  assertEquals(isBoundaryStable([], 5), true);
});

Deno.test('isBoundaryStable — photos.length <= topK → always stable', () => {
  const photos = [makePhoto('a', 1600, 100), makePhoto('b', 1500, 150)];
  assertEquals(isBoundaryStable(photos, 5), true);
});

Deno.test('isBoundaryStable — contenders clearly separated → stable', () => {
  // topK=2: boundary is rank 2 (elo=1400, uncertainty=50)
  // contender at rank 3 (elo=1000, uncertainty=50): gap=400 >> (50+50)*0.5=50 → stable
  const photos = [
    makePhoto('a', 1600, 50),
    makePhoto('b', 1400, 50),
    makePhoto('c', 1000, 50),
  ];
  assertEquals(isBoundaryStable(photos, 2), true);
});

Deno.test('isBoundaryStable — contender overlaps boundary uncertainty → unstable', () => {
  // topK=2: boundary is rank 2 (elo=1490, uncertainty=200)
  // contender at rank 3 (elo=1480, uncertainty=200): gap=10 < (200+200)*0.5=200 → unstable
  const photos = [
    makePhoto('a', 1600, 50),
    makePhoto('b', 1490, 200),
    makePhoto('c', 1480, 200),
  ];
  assertEquals(isBoundaryStable(photos, 2), false);
});

Deno.test('isBoundaryStable — only checks up to 3 contenders beyond boundary', () => {
  // topK=1: boundary=rank1 (elo=1600, u=50); contenders at ranks 2-4
  // rank2 (elo=1590, u=200): gap=10 < (50+200)*0.5=125 → unstable on first contender
  const photos = [
    makePhoto('a', 1600, 50),
    makePhoto('b', 1590, 200),
    makePhoto('c', 1000, 50),
    makePhoto('d', 900, 50),
    makePhoto('e', 800, 50),
  ];
  assertEquals(isBoundaryStable(photos, 1), false);
});

// --- isSessionComplete ---

Deno.test('isSessionComplete — empty photos → not complete (vacuous truth guard)', () => {
  assertEquals(isSessionComplete([], 5, 1, 0, 10), false);
});

Deno.test('isSessionComplete — coverage met and boundary stable → complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 3),
    makePhoto('b', 1000, 50, 3),
  ];
  assertEquals(isSessionComplete(photos, 2, 1, 3, 2), true);
});

Deno.test('isSessionComplete — coverage met but boundary unstable → not complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 3),
    makePhoto('b', 1490, 200, 3),
    makePhoto('c', 1480, 200, 3),
  ];
  assertEquals(isSessionComplete(photos, 2, 1, 8, 3), false);
});

Deno.test('isSessionComplete — coverage not met but comparison budget exhausted → complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 0),
    makePhoto('b', 1000, 50, 0),
  ];
  assertEquals(isSessionComplete(photos, 2, 5, 6, 2), true);
});

Deno.test('isSessionComplete — one comparison short of the budget → not complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 0),
    makePhoto('b', 1000, 50, 0),
  ];
  assertEquals(isSessionComplete(photos, 2, 5, 5, 2), false);
});

Deno.test('isSessionComplete — empty pool never reads as budget-exhausted', () => {
  assertEquals(isSessionComplete([], 15, 1, 0, 0), false);
});

Deno.test('isSessionComplete — coverage not met and budget not exhausted → not complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 0),
    makePhoto('b', 1000, 50, 0),
  ];
  assertEquals(isSessionComplete(photos, 2, 5, 0, 2), false);
});

// --- hasFullCoverage ---

Deno.test('hasFullCoverage — empty photos → false (vacuous truth guard)', () => {
  assertEquals(hasFullCoverage([], 1), false);
});

Deno.test('hasFullCoverage — every photo meets the floor → true', () => {
  const photos = [makePhoto('a', 1600, 50, 3), makePhoto('b', 1000, 50, 3)];
  assertEquals(hasFullCoverage(photos, 3), true);
});

Deno.test('hasFullCoverage — one photo below the floor → false', () => {
  const photos = [makePhoto('a', 1600, 50, 3), makePhoto('b', 1000, 50, 2)];
  assertEquals(hasFullCoverage(photos, 3), false);
});

// --- comparisonBudget / culled pool (F1, F2) ---

Deno.test('comparisonBudget — about 3 comparisons per ranked photo', () => {
  assertEquals(COMPARISONS_PER_PHOTO_BUDGET, 3);
  assertEquals(comparisonBudget(76), 228);
  assertEquals(comparisonBudget(0), 0);
});

// A 253-photo batch culled to the 76 photos the user kept. Boundary never stabilizes
// (every photo has the same rating and uncertainty), so the budget is what ends it.
function unsettledPool(size: number, comparisonsEach: number) {
  return Array.from({ length: size }, (_, i) => makePhoto(`p${i}`, 1500, 300, comparisonsEach));
}

Deno.test('isSessionComplete — culled pool ends on 3 per kept photo, not 4 per batch photo', () => {
  const pool = unsettledPool(76, 4);
  const { topK, minComparisons } = resolveTopKAndMinComparisons({ top_k: null }, pool.length);
  const budget = comparisonBudget(pool.length); // 228
  assertEquals(
    isSessionComplete(pool, topK, minComparisons, budget - 1, pool.length),
    false,
  );
  assertEquals(isSessionComplete(pool, topK, minComparisons, budget, pool.length), true);
  // The old rule was 4 x the whole 253-photo batch = 1,012 comparisons.
  assert(budget < 253 * 4);
});

Deno.test('isSessionComplete — a settled boundary still ends the session before the budget', () => {
  const pool = [
    ...Array.from({ length: 15 }, (_, i) => makePhoto(`top${i}`, 1900 - i, 50, 5)),
    ...Array.from({ length: 61 }, (_, i) => makePhoto(`rest${i}`, 1000 - i, 50, 5)),
  ];
  const { topK, minComparisons } = resolveTopKAndMinComparisons({ top_k: null }, pool.length);
  assertEquals(isSessionComplete(pool, topK, minComparisons, 100, pool.length), true);
});

Deno.test('isSessionComplete — pool sizing, not the stored batch size, drives the budget', () => {
  // Ranked pool of 10, all compared enough but unsettled; budget is 30 comparisons.
  const pool = unsettledPool(10, 1);
  assertEquals(isSessionComplete(pool, 5, 5, 29, pool.length), false);
  assertEquals(isSessionComplete(pool, 5, 5, 30, pool.length), true);
});
