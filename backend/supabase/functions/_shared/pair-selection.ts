import { type Photo, type CompletedComparison } from './ranking-logic.ts';

export const BOUNDARY_ALPHA = 1;
export const WEIGHTS_POST   = { elo: 0.40, overlap: 0.20, fresh: 0.20, repeat: 0.15, cluster: 0.05 };
export const WEIGHTS_COVER  = { elo: 0.30, overlap: 0.15, fresh: 0.50, repeat: 0.05, cluster: 0.00 };

export function pairKey(a: string, b: string): string {
  return [a, b].sort().join(':');
}

export function buildPairCounts(comparisons: CompletedComparison[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const c of comparisons) {
    const key = pairKey(c.photo_a_id, c.photo_b_id);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

export function pickRandom<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)]!;
}

export function selectPhotoA(photos: Photo[], topK: number, minComparisons: number): Photo {
  // Coverage floor: under-compared photos always win
  const under = photos.filter((p) => p.comparison_count < minComparisons);
  if (under.length > 0) {
    const minCount = Math.min(...under.map((p) => p.comparison_count));
    return pickRandom(under.filter((p) => p.comparison_count === minCount));
  }

  // Priority = uncertainty × boundary weight (α=1, symmetric around topK)
  const byElo = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const rankOf = new Map(byElo.map((p, i) => [p.id, i + 1]));

  let best = -Infinity;
  let pool: Photo[] = [];
  for (const p of photos) {
    const rank = rankOf.get(p.id)!;
    const score = p.uncertainty * Math.exp(-BOUNDARY_ALPHA * Math.abs(rank - topK) / topK);
    if (score > best) { best = score; pool = [p]; }
    else if (score === best) pool.push(p);
  }
  return pickRandom(pool);
}

export function selectPhotoB(
  photos: Photo[],
  photoA: Photo,
  pairCounts: Map<string, number>,
  inCoverage: boolean,
): Photo {
  const candidates = photos.filter((p) => p.id !== photoA.id);
  const w = inCoverage ? WEIGHTS_COVER : WEIGHTS_POST;

  const maxEloDiff = Math.max(...candidates.map((c) => Math.abs(c.elo_rating - photoA.elo_rating)), 1);
  const maxCount   = Math.max(...candidates.map((c) => c.comparison_count), 1);

  let best = -Infinity;
  let bestB = candidates[0]!;
  for (const b of candidates) {
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

export function totalComparisons(photos: Photo[]): number {
  return photos.reduce((s, p) => s + p.comparison_count, 0) / 2;
}

export function computeProgress(photos: Photo[], topK: number): number {
  const byElo    = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const boundary = byElo[Math.min(topK - 1, byElo.length - 1)]!;
  return Math.min(1, 1 - boundary.uncertainty / 350);
}
