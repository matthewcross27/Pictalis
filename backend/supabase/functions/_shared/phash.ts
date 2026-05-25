import { Jimp } from 'npm:jimp@1';

// Count differing bits between two 16-char lowercase hex strings (64-bit hashes).
export function hammingDistance(a: string, b: string): number {
  let n = BigInt('0x' + a) ^ BigInt('0x' + b);
  let count = 0;
  while (n > 0n) {
    n &= n - 1n; // Kernighan's bit-clearing trick
    count++;
  }
  return count;
}

// Compute a 64-bit difference hash (dHash) of a JPEG image buffer.
// Algorithm: resize to 9×8 grayscale, compare 8 adjacent horizontal pixel pairs per row.
// Returns a 16-char lowercase hex string. Consistent across calls for the same image.
export async function computeDHash(buf: Uint8Array): Promise<string> {
  const image = await Jimp.fromBuffer(buf.buffer as ArrayBuffer);
  image.resize({ w: 9, h: 8 });
  image.greyscale();

  const { data } = image.bitmap; // Flat RGBA Uint8Array; grayscale means R=G=B
  let bits = BigInt(0);
  for (let row = 0; row < 8; row++) {
    for (let col = 0; col < 8; col++) {
      const idx = (row * 9 + col) * 4;        // RGBA offset at (col, row)
      const nextIdx = (row * 9 + col + 1) * 4; // RGBA offset at (col+1, row)
      if (data[idx] > data[nextIdx]) {
        bits |= BigInt(1) << BigInt(row * 8 + col);
      }
    }
  }
  return bits.toString(16).padStart(16, '0');
}

// Variance of pixel intensities in a 32×32 grayscale downsample.
// Higher = more contrast = sharper. Empirical blurry threshold: score < 200.
export async function computeBlurScore(buf: Uint8Array): Promise<number> {
  const image = await Jimp.fromBuffer(buf.buffer as ArrayBuffer);
  image.resize({ w: 32, h: 32 });
  image.greyscale();

  const { data } = image.bitmap;
  const values: number[] = [];
  for (let i = 0; i < data.length; i += 4) {
    values.push(data[i]); // R channel = gray intensity (0–255)
  }
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  return values.reduce((a, b) => a + (b - mean) ** 2, 0) / values.length;
}
