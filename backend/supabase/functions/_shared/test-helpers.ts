import { type Photo } from './ranking-logic.ts';

export function makePhoto(
  id: string,
  elo: number,
  uncertainty: number,
  comparisons = 0,
  clusterId: string | null = null,
): Photo {
  return {
    id,
    storage_path: '',
    thumbnail_path: null,
    elo_rating: elo,
    uncertainty,
    comparison_count: comparisons,
    cluster_id: clusterId,
  };
}
