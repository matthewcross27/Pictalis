import { assertEquals } from 'jsr:@std/assert@1';
import { computeMinComparisons, computeTopK, isBoundaryStable, isSessionComplete } from './ranking-logic.ts';

// --- computeTopK ---

Deno.test('computeTopK — n=4 → floor of 5 (formula gives 5, hits max floor)', () => {
  assertEquals(computeTopK(4), 5);
});

Deno.test('computeTopK — n=1 → floor of 5', () => {
  assertEquals(computeTopK(1), 5);
});

Deno.test('computeTopK — n=100 → 25', () => {
  assertEquals(computeTopK(100), 25);
});

Deno.test('computeTopK — n=300 → capped at 40', () => {
  assertEquals(computeTopK(300), 40);
});

Deno.test('computeTopK — n=256 → capped at 40', () => {
  assertEquals(computeTopK(256), 40);
});

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

// --- isBoundaryStable ---

function makePhoto(
  id: string,
  elo: number,
  uncertainty: number,
  comparisons = 0,
) {
  return {
    id,
    storage_path: '',
    thumbnail_path: null,
    elo_rating: elo,
    uncertainty,
    comparison_count: comparisons,
    cluster_id: null,
  };
}

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
  assertEquals(isSessionComplete(photos, 2, 1, 9, 3), false);
});

Deno.test('isSessionComplete — coverage not met but comparison budget exhausted → complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 0),
    makePhoto('b', 1000, 50, 0),
  ];
  assertEquals(isSessionComplete(photos, 2, 5, 8, 2), true);
});

Deno.test('isSessionComplete — coverage not met and budget not exhausted → not complete', () => {
  const photos = [
    makePhoto('a', 1600, 50, 0),
    makePhoto('b', 1000, 50, 0),
  ];
  assertEquals(isSessionComplete(photos, 2, 5, 0, 2), false);
});
