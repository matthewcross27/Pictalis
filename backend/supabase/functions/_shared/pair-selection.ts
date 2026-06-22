import { type CompletedComparison, type Photo } from "./ranking-logic.ts";

export const BOUNDARY_ALPHA = 1;
export const WEIGHTS_POST = {
  elo: 0.40,
  overlap: 0.20,
  fresh: 0.20,
  repeat: 0.15,
  cluster: 0.05,
};
export const WEIGHTS_COVER = {
  elo: 0.30,
  overlap: 0.15,
  fresh: 0.50,
  repeat: 0.05,
  cluster: 0.00,
};

export function pairKey(a: string, b: string): string {
  return [a, b].sort().join(":");
}

export function buildPairCounts(
  comparisons: CompletedComparison[],
): Map<string, number> {
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

export function selectPhotoA(
  photos: Photo[],
  topK: number,
  minComparisons: number,
): Photo {
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
    const score = p.uncertainty *
      Math.exp(-BOUNDARY_ALPHA * Math.abs(rank - topK) / topK);
    if (score > best) {
      best = score;
      pool = [p];
    } else if (score === best) pool.push(p);
  }
  return pickRandom(pool);
}

export function selectPhotoB(
  photos: Photo[],
  photoA: Photo,
  pairCounts: Map<string, number>,
  inCoverage: boolean,
  pendingPairs: Set<string> = new Set(),
): Photo {
  const allCandidates = photos.filter((p) => p.id !== photoA.id);
  // Hard-exclude in-flight pending pairs; fall back to full pool if no eligible candidates remain.
  const candidates = allCandidates.filter((p) =>
    !pendingPairs.has(pairKey(photoA.id, p.id))
  );
  const pool = candidates.length > 0 ? candidates : allCandidates;

  const w = inCoverage ? WEIGHTS_COVER : WEIGHTS_POST;

  const maxEloDiff = pool.reduce(
    (m, c) => Math.max(m, Math.abs(c.elo_rating - photoA.elo_rating)),
    1,
  );
  const maxCount = pool.reduce((m, c) => Math.max(m, c.comparison_count), 1);

  let best = -Infinity;
  let bestB = pool[0]!;
  for (const b of pool) {
    const eloSim = 1 - Math.abs(b.elo_rating - photoA.elo_rating) / maxEloDiff;
    const overlap = (b.uncertainty + photoA.uncertainty) / 700;
    const fresh = 1 - b.comparison_count / maxCount;
    const count = pairCounts.get(pairKey(photoA.id, b.id)) ?? 0;
    const repeat = Math.exp(-count);
    const cluster =
      !b.cluster_id || !photoA.cluster_id || b.cluster_id !== photoA.cluster_id
        ? 1
        : 0;

    const score = w.elo * eloSim + w.overlap * overlap + w.fresh * fresh +
      w.repeat * repeat + w.cluster * cluster;

    if (score > best) {
      best = score;
      bestB = b;
    }
  }
  return bestB;
}

export function totalComparisons(photos: Photo[]): number {
  return photos.reduce((s, p) => s + p.comparison_count, 0) / 2;
}

export function computeProgress(photos: Photo[], topK: number): number {
  const byElo = [...photos].sort((a, b) => b.elo_rating - a.elo_rating);
  const boundary = byElo[Math.min(topK - 1, byElo.length - 1)]!;
  return Math.min(1, 1 - boundary.uncertainty / 350);
}

type IntraComparison = {
  photo_a_id: string;
  photo_b_id: string;
  completed_at: string | null;
};

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

export function isDedupComplete(
  photos: Photo[],
  comparisons: IntraComparison[],
): boolean {
  const clusterGroups = buildClusterGroups(photos);
  if (clusterGroups.size === 0) return true;

  const completedIntraCount = new Map<string, number>();
  for (const c of comparisons) {
    if (!c.completed_at) continue;
    const photoA = photos.find((p) => p.id === c.photo_a_id);
    const photoB = photos.find((p) => p.id === c.photo_b_id);
    if (!photoA?.cluster_id || photoA.cluster_id !== photoB?.cluster_id) {
      continue;
    }
    const clusterId = photoA.cluster_id;
    completedIntraCount.set(
      clusterId,
      (completedIntraCount.get(clusterId) ?? 0) + 1,
    );
  }

  for (const [clusterId, members] of clusterGroups) {
    if (members.length < 2) continue;
    const needed = members.length - 1;
    if ((completedIntraCount.get(clusterId) ?? 0) < needed) return false;
  }
  return true;
}

export function selectDedupPair(
  photos: Photo[],
  comparisons: IntraComparison[],
): [Photo, Photo] {
  const clusterGroups = buildClusterGroups(photos);

  const completedIntraCount = new Map<string, number>();
  for (const c of comparisons) {
    if (!c.completed_at) continue;
    const photoA = photos.find((p) => p.id === c.photo_a_id);
    const photoB = photos.find((p) => p.id === c.photo_b_id);
    if (!photoA?.cluster_id || photoA.cluster_id !== photoB?.cluster_id) {
      continue;
    }
    completedIntraCount.set(
      photoA.cluster_id,
      (completedIntraCount.get(photoA.cluster_id) ?? 0) + 1,
    );
  }

  // Find the unresolved cluster with the fewest completed comparisons.
  let targetCluster: Photo[] | null = null;
  let targetCount = Infinity;
  for (const [clusterId, members] of clusterGroups) {
    if (members.length < 2) continue;
    const done = completedIntraCount.get(clusterId) ?? 0;
    const needed = members.length - 1;
    if (done >= needed) continue;
    if (done < targetCount) {
      targetCount = done;
      targetCluster = members;
    }
  }

  if (!targetCluster) {
    throw new Error("selectDedupPair called when dedup is already complete");
  }

  // Build seen-pair set for this cluster.
  const clusterIds = new Set(targetCluster.map((p) => p.id));
  const seenPairs = new Set<string>();
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

  // All pairs seen (cycle) — return the lowest-index pair as tiebreak.
  return [sorted[0]!, sorted[1]!];
}
