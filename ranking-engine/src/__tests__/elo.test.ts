import { initialRating, calculateExpected, updateElo } from '../elo';

describe('initialRating', () => {
  it('returns 1500', () => {
    expect(initialRating()).toBe(1500);
  });
});

describe('calculateExpected', () => {
  it('returns 0.5 for equal ratings', () => {
    expect(calculateExpected(1500, 1500)).toBeCloseTo(0.5);
  });

  it('returns > 0.5 when ratingA > ratingB', () => {
    expect(calculateExpected(1600, 1500)).toBeGreaterThan(0.5);
  });

  it('returns < 0.5 when ratingA < ratingB', () => {
    expect(calculateExpected(1400, 1500)).toBeLessThan(0.5);
  });
});

describe('updateElo', () => {
  it('winner gains rating, loser loses rating', () => {
    const { winnerNew, loserNew } = updateElo(1500, 1500);
    expect(winnerNew).toBeGreaterThan(1500);
    expect(loserNew).toBeLessThan(1500);
  });

  it('sum of ratings is conserved', () => {
    const { winnerNew, loserNew } = updateElo(1500, 1500);
    expect(winnerNew + loserNew).toBeCloseTo(3000);
  });

  it('sum is conserved for asymmetric ratings', () => {
    const { winnerNew, loserNew } = updateElo(1300, 1700);
    expect(winnerNew + loserNew).toBeCloseTo(3000);
  });

  it('upset win (low beats high) yields larger gain than expected win', () => {
    const upset = updateElo(1300, 1700);
    const expected = updateElo(1700, 1300);
    expect(upset.winnerNew - 1300).toBeGreaterThan(expected.winnerNew - 1700);
  });

  it('1000 updates complete in < 200ms (throughput for batch re-ranking)', () => {
    const start = performance.now();
    for (let i = 0; i < 1000; i++) updateElo(1500, 1500);
    const ms = performance.now() - start;
    expect(ms).toBeLessThan(200);
  });
});
