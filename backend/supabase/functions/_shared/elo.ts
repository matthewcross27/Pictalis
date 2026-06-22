const K_FACTOR = 32;

export interface EloUpdate {
  winnerNew: number;
  loserNew: number;
}

export function calculateExpected(ratingA: number, ratingB: number): number {
  return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

export function updateElo(
  winnerRating: number,
  loserRating: number,
): EloUpdate {
  const expectedWinner = calculateExpected(winnerRating, loserRating);
  const expectedLoser = calculateExpected(loserRating, winnerRating);
  return {
    winnerNew: winnerRating + K_FACTOR * (1 - expectedWinner),
    loserNew: loserRating + K_FACTOR * (0 - expectedLoser),
  };
}
