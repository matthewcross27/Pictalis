// Higher K = faster convergence (good for short sessions); lower = more stable long-term ratings
const K_FACTOR = 32;
const DEFAULT_RATING = 1500;

export function initialRating(): number {
  return DEFAULT_RATING;
}

export function calculateExpected(ratingA: number, ratingB: number): number {
  return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

export function updateElo(
  winnerRating: number,
  loserRating: number,
): { winnerNew: number; loserNew: number } {
  const expectedWinner = calculateExpected(winnerRating, loserRating);
  const expectedLoser = 1 - expectedWinner;
  return {
    winnerNew: winnerRating + K_FACTOR * (1 - expectedWinner),
    loserNew: loserRating + K_FACTOR * (0 - expectedLoser),
  };
}
