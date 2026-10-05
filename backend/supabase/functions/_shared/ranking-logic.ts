export type Photo = {
  id: string;
  storage_path: string;
  thumbnail_path: string | null;
  elo_rating: number;
  uncertainty: number;
  comparison_count: number;
  cluster_id: string | null;
};

export type CompletedComparison = { photo_a_id: string; photo_b_id: string };

// Size of the favorites list the engine aims at when the session didn't choose
// one. The app shows a top 10, so this stays close to that instead of scaling
// with the batch: a boundary at rank 40 is the hardest place to settle and
// costs comparisons the user never sees the benefit of.
export const DEFAULT_TOP_K = 15;

// Safety net on total effort: comparisons allowed per photo in the ranked pool.
// Boundary stability is the normal way a session ends; this bounds the cost
// when it doesn't settle.
export const COMPARISONS_PER_PHOTO_BUDGET = 3;

export function comparisonBudget(poolSize: number): number {
  return poolSize * COMPARISONS_PER_PHOTO_BUDGET;
}

export function computeMinComparisons(n: number, topK: number): number {
  return Math.max(1, Math.ceil(Math.log2(n / topK) + 1));
}

// Derives the effective top-K and per-photo comparison floor for a session.
// The target comes from session.top_k when set (DEFAULT_TOP_K otherwise); the
// floor is sized from the ranked pool (see ranked-pool.ts), not the whole batch.
export function resolveTopKAndMinComparisons(
  session: { top_k: number | null },
  poolSize: number,
): { topK: number; minComparisons: number } {
  const topK = session.top_k ?? DEFAULT_TOP_K;
  const minComparisons = computeMinComparisons(poolSize, topK);
  return { topK, minComparisons };
}

export function sortByEloDesc<T extends Pick<Photo, 'elo_rating'>>(
  photos: T[],
): T[] {
  return [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
}

export function isBoundaryStable(
  photos: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
  topK: number,
  sortedByElo?: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
): boolean {
  if (photos.length <= topK) return true;
  const byElo = sortedByElo ?? sortByEloDesc(photos);
  const boundary = byElo[topK - 1]!;
  const contenders = byElo.slice(topK, Math.min(topK + 3, byElo.length));
  return !contenders.some(
    (c) =>
      Math.abs(c.elo_rating - boundary.elo_rating) <
        (c.uncertainty + boundary.uncertainty) * 0.5,
  );
}

export function hasFullCoverage(
  photos: Pick<Photo, 'comparison_count'>[],
  minComparisons: number,
): boolean {
  return photos.length > 0 &&
    photos.every((p) => p.comparison_count >= minComparisons);
}

// Session is complete once every photo has its coverage floor met and the
// top-K boundary has stabilized, or once the comparison budget is exhausted
// as a safety net against never-stabilizing sessions. `poolSize` is the ranked
// pool's size (see ranked-pool.ts), which the budget scales with.
//
// allHaveCoverage defaults to being derived internally, but callers that
// already computed it (e.g. next-pair, which also needs it to pick weights
// for photo B) can pass it in to avoid recomputing it a second time.
// sortedByElo lets a caller that already has an elo-sorted copy (e.g.
// next-pair, which reuses it for selectPhotoA/computeProgress too) avoid
// isBoundaryStable re-sorting the same photos array.
export function isSessionComplete(
  photos: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
  topK: number,
  minComparisons: number,
  totalComparisons: number,
  poolSize: number,
  allHaveCoverage: boolean = hasFullCoverage(photos, minComparisons),
  sortedByElo?: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
): boolean {
  // Short-circuits past the boundary-stability sort once coverage isn't met,
  // since its result can't change the outcome in that case.
  const stable = allHaveCoverage && isBoundaryStable(photos, topK, sortedByElo);
  // An empty pool has a budget of 0, which would read as already spent.
  const exhausted = poolSize > 0 && totalComparisons >= comparisonBudget(poolSize);
  return stable || exhausted;
}
