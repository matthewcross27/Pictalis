import { assertEquals } from 'jsr:@std/assert@1';
import { computeBlurScore, computeDHash, hammingDistance } from './phash.ts';
import { Jimp } from 'npm:jimp@1';

Deno.test('hammingDistance — identical hashes → 0', () => {
  assertEquals(hammingDistance('ffffffffffffffff', 'ffffffffffffffff'), 0);
});

Deno.test('hammingDistance — single bit differs → 1', () => {
  assertEquals(hammingDistance('0000000000000000', '0000000000000001'), 1);
});

Deno.test('hammingDistance — all 64 bits differ → 64', () => {
  assertEquals(hammingDistance('ffffffffffffffff', '0000000000000000'), 64);
});

Deno.test('hammingDistance — 8-bit XOR = 0xff → 8 bits set', () => {
  // 0xf0 XOR 0x0f = 0xff = 8 set bits
  assertEquals(hammingDistance('f000000000000000', '0f00000000000000'), 8);
});

// Helper: create a solid-color JPEG in memory using jimp.
// color is 0xRRGGBBAA (e.g. 0x808080ff for gray).
async function solidJpeg(color: number, size = 100): Promise<Uint8Array> {
  const img = new Jimp({ width: size, height: size, color });
  return new Uint8Array(await img.getBuffer('image/jpeg'));
}

// Helper: create a black-and-white checkerboard JPEG (high variance = sharp).
async function checkerJpeg(size = 64, blockSize = 8): Promise<Uint8Array> {
  const img = new Jimp({ width: size, height: size, color: 0x000000ff });
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const isWhite = (Math.floor(x / blockSize) + Math.floor(y / blockSize)) % 2 === 0;
      img.setPixelColor(isWhite ? 0xffffffff : 0x000000ff, x, y);
    }
  }
  return new Uint8Array(await img.getBuffer('image/jpeg'));
}

Deno.test('computeDHash — returns 16-char hex string', async () => {
  const buf = await solidJpeg(0xff0000ff); // Red
  const hash = await computeDHash(buf);
  assertEquals(hash.length, 16);
  assertEquals(/^[0-9a-f]{16}$/.test(hash), true);
});

Deno.test('computeDHash — identical images → identical hash', async () => {
  const buf = await solidJpeg(0x336699ff);
  const h1 = await computeDHash(buf);
  const h2 = await computeDHash(buf);
  assertEquals(h1, h2);
});

Deno.test('computeDHash — solid colors → very similar hashes', async () => {
  // Slight color change should not change the structure hash much
  const redBuf = await solidJpeg(0xff0000ff);
  const darkRedBuf = await solidJpeg(0xee0000ff);
  const dist = hammingDistance(
    await computeDHash(redBuf),
    await computeDHash(darkRedBuf),
  );
  assertEquals(dist <= 5, true, `Expected small distance, got ${dist}`);
});

Deno.test('computeBlurScore — solid color image → low score (blurry)', async () => {
  const buf = await solidJpeg(0x808080ff); // Gray: no edges → very low variance
  const score = await computeBlurScore(buf);
  // JPEG quantization may add slight noise, but solid colors stay well below threshold
  assertEquals(score < 200, true, `Expected score < 200, got ${score}`);
});

Deno.test('computeBlurScore — checkerboard → high score (sharp)', async () => {
  const buf = await checkerJpeg();
  const score = await computeBlurScore(buf);
  assertEquals(score > 200, true, `Expected score > 200, got ${score}`);
});
