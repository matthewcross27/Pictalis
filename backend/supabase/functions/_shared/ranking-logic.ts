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

export function computeTopK(n: number): number {
  return Math.min(40, Math.max(5, Math.round(2.5 * Math.sqrt(n))));
}

export function computeMinComparisons(n: number, topK: number): number {
  return Math.max(1, Math.ceil(Math.log2(n / topK) + 1));
}

// Derives the effective top-K and per-photo comparison floor for a session,
// respecting an explicit session.top_k override when set.
export function resolveTopKAndMinComparisons(
  session: { top_k: number | null; photo_count: number },
): { topK: number; minComparisons: number } {
  const topK = session.top_k ?? computeTopK(session.photo_count);
  const minComparisons = computeMinComparisons(session.photo_count, topK);
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
): boolean {
  if (photos.length <= topK) return true;
  const byElo = sortByEloDesc(photos);
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
// as a safety net against never-stabilizing sessions.
//
// allHaveCoverage defaults to being derived internally, but callers that
// already computed it (e.g. next-pair, which also needs it to pick weights
// for photo B) can pass it in to avoid recomputing it a second time.
export function isSessionComplete(
  photos: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
  topK: number,
  minComparisons: number,
  totalComparisons: number,
  photoCount: number,
  allHaveCoverage: boolean = hasFullCoverage(photos, minComparisons),
): boolean {
  // Short-circuits past the boundary-stability sort once coverage isn't met,
  // since its result can't change the outcome in that case.
  const stable = allHaveCoverage && isBoundaryStable(photos, topK);
  const exhausted = totalComparisons >= photoCount * 4;
  return stable || exhausted;
}
