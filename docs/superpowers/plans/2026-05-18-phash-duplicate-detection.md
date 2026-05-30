# pHash Duplicate Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect near-duplicate and blurry photos synchronously inside `register-photo`, setting `cluster_id`, `quality_flags`, and `is_suppressed` on each photo row so the ranking engine can skip redundant content from the start.

**Architecture:** After the existing DB insert in `register-photo`, the function downloads the uploaded JPEG from Storage via signed URL, computes a 64-bit difference hash (dHash) using `npm:jimp@1`, compares Hamming distances against all existing session photo hashes (queried in one DB call), assigns the photo to an existing cluster or creates a new one, scores blur via pixel-variance on a 32×32 grayscale downsample, then patches the photo row. Errors in hashing degrade gracefully — the photo is still registered, just without cluster assignment. Processing is synchronous (not fire-and-forget) so `cluster_id` is guaranteed set before `next-pair` is called.

**Tech Stack:** Deno 2, TypeScript, `npm:jimp@1`, Supabase Edge Functions, PostgreSQL migration

---

## Scope Note

This plan adds a `phash TEXT` column to `photos` and updates `register-photo` only. No iOS changes. No changes to `next-pair` — it already filters `is_suppressed = false`. The multi-stage ranking plan (separate) will use `cluster_id` to power Stage 3 within-cluster comparisons.

---

## File Map

```
backend/supabase/
├── migrations/
│   └── 20260518000001_phash_column.sql          (new: ADD COLUMN phash + index)
└── functions/
    ├── _shared/
    │   └── phash.ts                              (new: dHash, blur score, Hamming distance)
    └── register-photo/
        └── index.ts                              (modify: hash + cluster after insert)
```

---

### Task 1: Migration — add phash column

**Files:**
- Create: `backend/supabase/migrations/20260518000001_phash_column.sql`

`cluster_id` already exists on `photos` (TEXT, nullable). We only need to add `phash` for storing the computed hash so future registrations can compare against it.

- [ ] **Step 1: Create the migration**

Create `backend/supabase/migrations/20260518000001_phash_column.sql`:

```sql
-- phash stores the 16-char hex difference hash computed at register-photo time.
-- NULL until hashing completes (or if hashing fails — graceful degradation).
-- cluster_id (TEXT, nullable) already exists — no changes needed.
ALTER TABLE photos ADD COLUMN IF NOT EXISTS phash TEXT;

-- Enables fast fetch of all hashes for a session in one query.
CREATE INDEX IF NOT EXISTS idx_photos_session_phash ON photos(session_id, phash)
  WHERE phash IS NOT NULL;
```

- [ ] **Step 2: Verify line count**

```bash
grep -c "ALTER TABLE\|CREATE INDEX" backend/supabase/migrations/20260518000001_phash_column.sql
```

Expected: `2`

- [ ] **Step 3: Apply the migration via Supabase MCP**

Use the `mcp__plugin_supabase_supabase__apply_migration` tool with the SQL above. Confirm the `photos` table now has a `phash` column (`TEXT`, nullable).

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/migrations/20260518000001_phash_column.sql
git commit -m "feat(backend): add phash column for perceptual duplicate detection"
```

---

### Task 2: pHash helper module

**Files:**
- Create: `backend/supabase/functions/_shared/phash.ts`

Three pure-computation exports — no Supabase client, no network — so they can be tested with `deno test` locally:
- `hammingDistance(a: string, b: string): number` — count of differing bits between two 16-char hex strings
- `computeDHash(buf: Uint8Array): Promise<string>` — 9×8 grayscale downsample → 64-bit horizontal-diff hash, returned as 16-char lowercase hex
- `computeBlurScore(buf: Uint8Array): Promise<number>` — variance of 32×32 grayscale pixel values; higher = sharper (empirical blurry threshold: < 200)

**dHash algorithm:**
1. Resize JPEG to 9 pixels wide × 8 pixels tall
2. Convert to grayscale (R=G=B per pixel in RGBA buffer)
3. For each of the 8 rows, compare each of the 8 adjacent pixel pairs: if `pixel[col] > pixel[col+1]`, set bit `row*8 + col`
4. Return 64-bit result as 16-char hex string (padded with leading zeros)

- [ ] **Step 1: Write failing hammingDistance tests**

Create `backend/supabase/functions/_shared/phash.test.ts`:

```typescript
import { assertEquals } from 'jsr:@std/assert@1';
import { hammingDistance } from './phash.ts';

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
```

- [ ] **Step 2: Run — confirm module-not-found error**

```bash
cd backend/supabase/functions/_shared && deno test phash.test.ts 2>&1 | head -5
```

Expected: error like `Cannot resolve module './phash.ts'`

- [ ] **Step 3: Create phash.ts with hammingDistance only**

Create `backend/supabase/functions/_shared/phash.ts`:

```typescript
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
  const image = await Jimp.fromBuffer(buf);
  image.resize({ w: 9, h: 8 });
  image.greyscale();

  const { data } = image.bitmap; // Flat RGBA Uint8Array; grayscale means R=G=B
  let bits = BigInt(0);
  for (let row = 0; row < 8; row++) {
    for (let col = 0; col < 8; col++) {
      const idx = (row * 9 + col) * 4;       // RGBA offset at (col, row)
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
  const image = await Jimp.fromBuffer(buf);
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
```

- [ ] **Step 4: Run hammingDistance tests — confirm all 4 pass**

```bash
cd backend/supabase/functions/_shared && deno test phash.test.ts 2>&1
```

Expected: `4 passed`

- [ ] **Step 5: Write failing dHash and blur tests**

Add to `phash.test.ts` (append after existing tests):

```typescript
import { computeDHash, computeBlurScore } from './phash.ts';
import { Jimp } from 'npm:jimp@1';

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
  const dist = hammingDistance(await computeDHash(redBuf), await computeDHash(darkRedBuf));
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
```

- [ ] **Step 6: Run all tests — confirm all pass**

```bash
cd backend/supabase/functions/_shared && deno test phash.test.ts 2>&1
```

Expected: `9 passed` (4 hammingDistance + 5 dHash/blur tests)

- [ ] **Step 7: Type-check the module**

```bash
deno check backend/supabase/functions/_shared/phash.ts 2>&1
```

Expected: no errors

- [ ] **Step 8: Commit**

```bash
git add backend/supabase/functions/_shared/phash.ts \
        backend/supabase/functions/_shared/phash.test.ts
git commit -m "feat(backend): add pHash helper module with dHash, blur score, and Hamming distance"
```

---

### Task 3: Wire pHash into register-photo

**Files:**
- Modify: `backend/supabase/functions/register-photo/index.ts`

**What changes:** After the existing `supabase.from('photos').insert(...)` call, the function now:
1. Creates a signed URL for the just-uploaded object (60-second expiry is enough)
2. Fetches the JPEG bytes
3. Calls `computeDHash` and `computeBlurScore` (both use the same buffer)
4. Queries all existing photos in the session that have a phash set
5. Finds the closest hash by Hamming distance
6. Assigns `cluster_id`: if closest Hamming ≤ 10 → reuse that photo's cluster_id; otherwise → new UUID
7. Sets `is_suppressed = true` if closest Hamming ≤ 3 (near-identical) OR blur score < 200
8. Patches the photo row with `phash`, `cluster_id`, `quality_flags`, `is_suppressed`
9. Returns the enriched photo response

If any step from (1) onward throws, we log and continue — the photo row already exists with defaults (`is_suppressed = false`, `cluster_id = null`, `phash = null`). The caller gets a 201 with those defaults.

- [ ] **Step 1: Read the current register-photo file**

Verify the file matches what's expected — the last lines should be:

```typescript
  const { data: photo, error } = await supabase
    .from('photos')
    .insert({ session_id, storage_path })
    .select('id, session_id, storage_path, elo_rating, comparison_count, created_at')
    .single();

  if (error) {
    console.error('Failed to insert photo record:', error);
    return new Response(JSON.stringify({ error: 'Failed to register photo' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ photo }), {
    status: 201,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
```

- [ ] **Step 2: Replace the entire register-photo/index.ts**

Replace `backend/supabase/functions/register-photo/index.ts` with:

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { computeDHash, computeBlurScore, hammingDistance } from '../_shared/phash.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const UUID_RE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const STORAGE_PATH_RE = new RegExp(`^${UUID_RE}/${UUID_RE}/[^/]+$`, 'i');

const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().regex(STORAGE_PATH_RE, 'Must match {uid}/{session_id}/{filename}'),
});

// Hamming distance thresholds for duplicate/cluster decisions.
const DUPLICATE_THRESHOLD = 3;  // ≤ 3 bits differ → near-identical → suppress
const CLUSTER_THRESHOLD = 10;   // ≤ 10 bits differ → same scene → share cluster_id
const BLUR_THRESHOLD = 200;     // pixel variance below this → blurry → suppress

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const parsed = RegisterPhotoBody.safeParse(body);
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { session_id, storage_path } = parsed.data;
  const [pathUid, pathSessionId, filename] = storage_path.split('/');

  if (pathUid !== user.id) {
    return new Response(
      JSON.stringify({ error: 'storage_path UID segment must match the authenticated user' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }
  if (pathSessionId !== session_id) {
    return new Response(
      JSON.stringify({ error: 'storage_path session_id segment must match session_id field' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }

  const { data: objects, error: listError } = await supabase.storage
    .from('working-copies')
    .list(`${pathUid}/${pathSessionId}`, { search: filename });

  if (listError || !objects || !objects.some((o) => o.name === filename)) {
    return new Response(JSON.stringify({ error: 'Storage object not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: session, error: sessionError } = await supabase
    .from('sessions')
    .select('id')
    .eq('id', session_id)
    .single();

  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: 'Session not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Insert the photo row with defaults first — ensures the photo is registered
  // even if the hashing step below fails.
  const { data: photo, error: insertError } = await supabase
    .from('photos')
    .insert({ session_id, storage_path })
    .select('id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed, cluster_id, quality_flags, phash')
    .single();

  if (insertError || !photo) {
    console.error('Failed to insert photo record:', insertError);
    return new Response(JSON.stringify({ error: 'Failed to register photo' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // --- pHash computation (graceful degradation on any error) ---
  try {
    // Download the uploaded image bytes using a short-lived signed URL.
    const { data: signed, error: signedError } = await supabase.storage
      .from('working-copies')
      .createSignedUrl(storage_path, 60);

    if (signedError || !signed?.signedUrl) throw new Error('Could not create signed URL');

    const response = await fetch(signed.signedUrl);
    if (!response.ok) throw new Error(`Image fetch failed: ${response.status}`);
    const imageBytes = new Uint8Array(await response.arrayBuffer());

    // Compute hash and blur score in parallel (both read the same buffer).
    const [phash, blurScore] = await Promise.all([
      computeDHash(imageBytes),
      computeBlurScore(imageBytes),
    ]);

    // Fetch all existing hashes for this session to find cluster match.
    const { data: existingPhotos } = await supabase
      .from('photos')
      .select('id, cluster_id, phash')
      .eq('session_id', session_id)
      .not('phash', 'is', null)
      .neq('id', photo.id); // Exclude the photo we just inserted

    // Find the closest existing hash by Hamming distance.
    let closestDistance = Infinity;
    let closestClusterId: string | null = null;
    for (const existing of existingPhotos ?? []) {
      const dist = hammingDistance(phash, existing.phash);
      if (dist < closestDistance) {
        closestDistance = dist;
        closestClusterId = existing.cluster_id;
      }
    }

    const clusterId = closestDistance <= CLUSTER_THRESHOLD && closestClusterId
      ? closestClusterId
      : crypto.randomUUID(); // New cluster for this photo

    const isNearIdentical = closestDistance <= DUPLICATE_THRESHOLD;
    const isBlurry = blurScore < BLUR_THRESHOLD;
    const isSuppressed = isNearIdentical || isBlurry;

    const qualityFlags = {
      blur_score: Math.round(blurScore),
      blurry: isBlurry,
      near_identical: isNearIdentical,
    };

    // Patch the photo row with computed values.
    await supabase
      .from('photos')
      .update({ phash, cluster_id: clusterId, quality_flags: qualityFlags, is_suppressed: isSuppressed })
      .eq('id', photo.id);

    // Return the enriched photo response.
    return new Response(
      JSON.stringify({
        photo: {
          ...photo,
          phash,
          cluster_id: clusterId,
          quality_flags: qualityFlags,
          is_suppressed: isSuppressed,
        },
      }),
      { status: 201, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    // Hashing failed — return the photo with defaults. Registration succeeded.
    console.error('pHash computation failed (non-fatal):', err);
    return new Response(JSON.stringify({ photo }), {
      status: 201,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
```

- [ ] **Step 3: Type-check the updated function**

```bash
deno check backend/supabase/functions/register-photo/index.ts 2>&1 \
  || echo "Note: deno not installed locally — will be verified in CI"
```

Expected: no type errors (or Note message).

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/register-photo/index.ts
git commit -m "feat(backend): compute pHash, assign clusters, detect blur in register-photo"
```

---

### Task 4: Deploy and verify end-to-end

**Files:** No new files — verification only.

- [ ] **Step 1: Deploy the updated register-photo function**

```bash
npx supabase functions deploy register-photo
```

Or use the Supabase MCP `deploy_edge_function` tool.

- [ ] **Step 2: Test with near-duplicate photos**

Upload two nearly identical photos (e.g., two crops of the same image) to the same session. After both register-photo calls complete:

```sql
SELECT id, cluster_id, phash, is_suppressed, quality_flags
FROM photos
WHERE session_id = '<your-session-id>'
ORDER BY created_at;
```

Expected:
- Both photos share the same `cluster_id`
- Second photo has `is_suppressed = true` (Hamming ≤ 3)
- `quality_flags.near_identical = true` on the second photo

- [ ] **Step 3: Test with distinct photos**

Upload 3 clearly different photos (different scenes, different content) to the same session.

Expected:
- Each photo gets a unique `cluster_id`
- `is_suppressed = false` for all three
- `phash` is different for each

- [ ] **Step 4: Test error degradation**

Temporarily break the image download (e.g., use a session from a different user's ID) and verify the response still returns HTTP 201 with the photo row (defaults: `is_suppressed = false`, `cluster_id = null`, `phash = null`).

- [ ] **Step 5: Commit any final adjustments**

```bash
git add -A
git commit -m "fix(backend): post-deploy adjustments to pHash detection"
```

---

## Self-Review

### 1. Spec Coverage

| Requirement | Task |
|---|---|
| Near-duplicate detection (Hamming ≤ 10 → same cluster) | Task 3: `closestDistance <= CLUSTER_THRESHOLD` |
| Near-identical suppression (Hamming ≤ 3 → suppress) | Task 3: `isNearIdentical` flag |
| Blur detection (variance < 200 → suppress) | Tasks 2 + 3: `computeBlurScore`, `isBlurry` flag |
| `cluster_id` set before `next-pair` is called | Task 3: synchronous update within register-photo |
| `quality_flags.blur_score`, `quality_flags.blurry` | Task 3: `qualityFlags` object |
| Graceful degradation if hashing fails | Task 3: outer try/catch, returns 201 with defaults |
| `phash TEXT` column + index | Task 1: migration |

### 2. Placeholder Scan

No TBD, TODO, "similar to above", or incomplete sections found.

### 3. Type Consistency

- `computeDHash(buf: Uint8Array): Promise<string>` defined in Task 2 → called with `Uint8Array` in Task 3 ✓
- `computeBlurScore(buf: Uint8Array): Promise<number>` defined in Task 2 → called in Task 3 ✓
- `hammingDistance(a: string, b: string): number` defined in Task 2 → called with `phash` (string) and `existing.phash` (string) in Task 3 ✓
- `isSuppressed` (boolean) → passed as `is_suppressed` in `update({})` → matches column name ✓
- `qualityFlags` typed as `{ blur_score: number, blurry: boolean, near_identical: boolean }` → stored in JSONB `quality_flags` column ✓
- `closestClusterId` is `string | null` → only reused if `<= CLUSTER_THRESHOLD && closestClusterId` (null check) ✓
