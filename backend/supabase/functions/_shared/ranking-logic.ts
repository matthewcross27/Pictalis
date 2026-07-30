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

export function isBoundaryStable(
  photos: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
  topK: number,
): boolean {
  if (photos.length <= topK) return true;
  const byElo = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
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
export function isSessionComplete(
  photos: Pick<Photo, 'elo_rating' | 'uncertainty' | 'comparison_count'>[],
  topK: number,
  minComparisons: number,
  totalComparisons: number,
  photoCount: number,
): boolean {
  const allHaveCoverage = hasFullCoverage(photos, minComparisons);
  const stable = isBoundaryStable(photos, topK);
  const exhausted = totalComparisons >= photoCount * 4;
  return (allHaveCoverage && stable) || exhausted;
}
