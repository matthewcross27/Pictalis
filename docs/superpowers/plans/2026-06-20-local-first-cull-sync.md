# Pre-Registration Local-First Cull Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate dropped-photo leaks in ranking by pre-registering all photo identities with the server before showing the first cull card, so every decision is immediately sendable with no race condition.

**Architecture:** A new `batch-pre-register` edge function bulk-inserts photo rows (identity only, `upload_status='pending'`) at session start. The existing upload pipeline then fills in bytes and sets `upload_status='uploaded'`. Ranking queries filter on both `is_suppressed=false` AND `upload_status='uploaded'`, so a photo can only enter ranking once its bytes are in storage AND it was not dropped. The `cancelledInFlight` pipeline state and `SyncService` flush timeout are both removed because every photo has a server row before any decision is possible.

**Tech Stack:** TypeScript/Deno (edge functions), Supabase JS v2, Swift 6 / SwiftUI, XCTest

---

## File Map

**New files:**
- `backend/supabase/migrations/20260620000001_add_upload_status.sql`
- `backend/supabase/functions/_shared/batch-pre-register.ts` — Zod schema
- `backend/supabase/functions/_shared/batch-pre-register.test.ts` — schema unit tests
- `backend/supabase/functions/batch-pre-register/index.ts` — edge function

**Modified files:**
- `backend/supabase/functions/register-photo/index.ts` — INSERT → UPDATE, remove unique-violation path
- `backend/supabase/functions/batch-submit-cull/index.ts` — remove existence re-query
- `backend/supabase/functions/next-pair/index.ts:86` — add `upload_status='uploaded'` filter
- `backend/supabase/functions/results/index.ts:61` — add `upload_status='uploaded'` filter
- `ios/Sources/App/Models/Models.swift` — add `BatchPreRegisterResponse`
- `ios/Sources/App/Services/APIClient.swift` — add `batchPreRegister()` method
- `ios/Sources/App/Services/PhotoUploadTransport.swift` — rename `register` → `markUploaded`
- `ios/Sources/App/Services/PhotoPipeline.swift` — remove `cancelledInFlight`/`registered` states, add `uploaded`, simplify `registrationState`, remove `onRegistered`
- `ios/Sources/App/Services/SyncService.swift` — remove `.pending` partition bucket, simplify `flush()`
- `ios/Sources/App/Views/SessionSetupView.swift` — call `batchPreRegister` before starting pipeline
- `ios/Sources/App/Views/CullView.swift` — remove `pipeline.onRegistered` line
- `ios/Tests/PhotoPipelineTests.swift` — update `MockTransport` + remove `DropDuringRegistrationRaceTests`
- `ios/Tests/SyncPartitionTests.swift` — remove impossible test, update partition test

---

### Task 1: Schema migration — add upload_status column

**Files:**
- Create: `backend/supabase/migrations/20260620000001_add_upload_status.sql`

- [ ] **Step 1: Write the migration**

```sql
-- Photos start with upload_status='pending' (identity pre-registered, bytes not yet
-- in storage). The upload worker sets 'uploaded' after bytes land in Supabase Storage.
-- Ranking queries filter on upload_status='uploaded' so rows with no bytes in storage
-- never appear in the comparison pool.
ALTER TABLE public.photos
  ADD COLUMN IF NOT EXISTS upload_status TEXT NOT NULL DEFAULT 'pending'
  CHECK (upload_status IN ('pending', 'uploaded'));
```

- [ ] **Step 2: Apply the migration locally**

Run: `supabase db reset` (or `supabase migration up` if using linked project)

Expected: no errors. Verify with `supabase db diff` showing the new column.

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/migrations/20260620000001_add_upload_status.sql
git commit -m "feat(db): add upload_status column to photos table"
```

---

### Task 2: batch-pre-register shared schema + unit tests

**Files:**
- Create: `backend/supabase/functions/_shared/batch-pre-register.ts`
- Create: `backend/supabase/functions/_shared/batch-pre-register.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// backend/supabase/functions/_shared/batch-pre-register.test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import { BatchPreRegisterBody } from './batch-pre-register.ts';

Deno.test('BatchPreRegisterBody accepts valid session_id and photo_ids', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: [
      'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'ffffffff-0000-1111-2222-333333333333',
    ],
  });
  assertEquals(result.success, true);
});

Deno.test('BatchPreRegisterBody rejects non-UUID photo_ids', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: ['not-a-uuid'],
  });
  assertEquals(result.success, false);
});

Deno.test('BatchPreRegisterBody rejects empty photo_ids array', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: [],
  });
  assertEquals(result.success, false);
});

Deno.test('BatchPreRegisterBody rejects more than 300 photo_ids', () => {
  const result = BatchPreRegisterBody.safeParse({
    session_id: '11111111-2222-3333-4444-555555555555',
    photo_ids: Array.from({ length: 301 }, () => '11111111-2222-3333-4444-555555555555'),
  });
  assertEquals(result.success, false);
});

Deno.test('BatchPreRegisterBody rejects missing session_id', () => {
  const result = BatchPreRegisterBody.safeParse({
    photo_ids: ['aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'],
  });
  assertEquals(result.success, false);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && deno test supabase/functions/_shared/batch-pre-register.test.ts`

Expected: error — `Cannot resolve module '_shared/batch-pre-register.ts'`

- [ ] **Step 3: Write the shared schema module**

```typescript
// backend/supabase/functions/_shared/batch-pre-register.ts
import { z } from 'npm:zod@3';

export const BatchPreRegisterBody = z.object({
  session_id: z.string().uuid(),
  photo_ids: z.array(z.string().uuid()).min(1).max(300),
});
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && deno test supabase/functions/_shared/batch-pre-register.test.ts`

Expected: 5 tests pass

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/functions/_shared/batch-pre-register.ts \
        backend/supabase/functions/_shared/batch-pre-register.test.ts
git commit -m "feat(backend): batch-pre-register Zod schema with unit tests"
```

---

### Task 3: batch-pre-register edge function

**Files:**
- Create: `backend/supabase/functions/batch-pre-register/index.ts`

- [ ] **Step 1: Write the edge function**

```typescript
// backend/supabase/functions/batch-pre-register/index.ts
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { BatchPreRegisterBody } from '../_shared/batch-pre-register.ts';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
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

    const parsed = BatchPreRegisterBody.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
        status: 400,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const { session_id, photo_ids } = parsed.data;

    // Verify the session belongs to the authenticated user (RLS handles this,
    // but an explicit check gives a clear 404 rather than a silent empty result).
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

    // Insert photo identity rows. ignoreDuplicates makes this idempotent:
    // a network retry after partial success won't double-insert existing rows.
    const rows = photo_ids.map((id) => ({
      id,
      session_id,
      upload_status: 'pending',
    }));

    const { error: insertError } = await supabase
      .from('photos')
      .upsert(rows, { onConflict: 'id', ignoreDuplicates: true });

    if (insertError) {
      console.error('Failed to pre-register photos:', insertError);
      return new Response(JSON.stringify({ error: 'Failed to pre-register photos' }), {
        status: 500,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
```

- [ ] **Step 2: Smoke-test locally**

Run: `supabase functions serve batch-pre-register --env-file supabase/.env.local`

In another terminal:
```bash
curl -X POST http://localhost:54321/functions/v1/batch-pre-register \
  -H "Authorization: Bearer <anon-key>" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"<valid-session-uuid>","photo_ids":["<uuid1>","<uuid2>"]}'
```

Expected: `{"ok":true}` with status 200. Verify rows appear in `photos` table with `upload_status='pending'`.

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/functions/batch-pre-register/index.ts
git commit -m "feat(backend): batch-pre-register edge function — bulk-inserts photo identity rows"
```

---

### Task 4: Modify register-photo to UPDATE existing rows

**Files:**
- Modify: `backend/supabase/functions/register-photo/index.ts`

The current function INSERTs a new photo row. After pre-registration, the row already exists. Change the INSERT to an UPDATE that sets `storage_path` and `upload_status='uploaded'`. Remove the unique-violation path.

- [ ] **Step 1: Remove the unused isUniqueViolation import**

Find:
```typescript
import { isUniqueViolation, RegisterPhotoBody } from '../_shared/photo-registration.ts';
```

Replace with:
```typescript
import { RegisterPhotoBody } from '../_shared/photo-registration.ts';
```

- [ ] **Step 2: Guard that photo_id is always provided**

Find (around line 57):
```typescript
    const { session_id, storage_path, photo_id } = parsed.data;
```

Replace with:
```typescript
    const { session_id, storage_path, photo_id } = parsed.data;
    if (!photo_id) {
      return new Response(JSON.stringify({ error: 'photo_id is required' }), {
        status: 400,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }
```

- [ ] **Step 3: Replace the INSERT block with UPDATE**

Find (around line 98):
```typescript
    const PHOTO_COLUMNS =
      'id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed';

    const insertRow: Record<string, string> = { session_id, storage_path };
    if (photo_id) insertRow.id = photo_id;

    const { data: photo, error: insertError } = await supabase
      .from('photos')
      .insert(insertRow)
      .select(PHOTO_COLUMNS)
      .single();

    if (insertError && photo_id && isUniqueViolation(insertError)) {
      // Client retry of a register that already succeeded — return the existing row.
      const { data: existing } = await supabase
        .from('photos')
        .select(PHOTO_COLUMNS)
        .eq('id', photo_id)
        .single();
      if (
        existing && existing.session_id === session_id && existing.storage_path === storage_path
      ) {
        return new Response(JSON.stringify({ photo: existing }), {
          status: 200,
          headers: { ...CORS, 'Content-Type': 'application/json' },
        });
      }
      return new Response(JSON.stringify({ error: 'photo_id conflict' }), {
        status: 409,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    if (insertError || !photo) {
      console.error('Failed to insert photo record:', insertError);
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

Replace with:
```typescript
    const PHOTO_COLUMNS =
      'id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed';

    // Row was pre-registered at session start. UPDATE sets the bytes location
    // and marks upload complete. Idempotent: a retry on an already-uploaded row
    // returns the existing data unchanged.
    const { data: photo, error: updateError } = await supabase
      .from('photos')
      .update({ storage_path, upload_status: 'uploaded' })
      .eq('id', photo_id)
      .eq('session_id', session_id)
      .select(PHOTO_COLUMNS)
      .single();

    if (updateError || !photo) {
      // Row missing: batch-pre-register wasn't called, or session/id mismatch.
      return new Response(JSON.stringify({ error: 'Photo not pre-registered or session mismatch' }), {
        status: 404,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ photo }), {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
```

- [ ] **Step 4: Smoke-test the updated endpoint**

Pre-register a photo, then call register-photo with the same ID and a valid `storage_path`. Expected: `{"photo":{...}}` with `upload_status='uploaded'` in the returned row and status 200.

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/functions/register-photo/index.ts
git commit -m "feat(backend): register-photo updates pre-registered row instead of inserting"
```

---

### Task 5: Add upload_status filter to ranking queries

**Files:**
- Modify: `backend/supabase/functions/next-pair/index.ts`
- Modify: `backend/supabase/functions/results/index.ts`

- [ ] **Step 1: Update next-pair — add upload_status filter**

Find (around line 86):
```typescript
      .eq('is_suppressed', false)
      .or('cull_decision.is.null,cull_decision.eq.keep');
```

Replace with:
```typescript
      .eq('is_suppressed', false)
      .eq('upload_status', 'uploaded')
      .or('cull_decision.is.null,cull_decision.eq.keep');
```

- [ ] **Step 2: Update results — add upload_status filter**

Find (around line 61):
```typescript
      .eq('is_suppressed', false)
      .order('elo_rating', { ascending: false })
```

Replace with:
```typescript
      .eq('is_suppressed', false)
      .eq('upload_status', 'uploaded')
      .order('elo_rating', { ascending: false })
```

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/functions/next-pair/index.ts \
        backend/supabase/functions/results/index.ts
git commit -m "feat(backend): filter ranking pool and results to upload_status=uploaded only"
```

---

### Task 6: Simplify batch-submit-cull — remove existence re-query

**Files:**
- Modify: `backend/supabase/functions/batch-submit-cull/index.ts`

- [ ] **Step 1: Remove the two-step existence check**

Find (around line 86):
```typescript
          // Zero rows: either the decision is already set (idempotent retry →
          // success) or the photo row does not exist yet (the drop raced ahead
          // of registration). Reporting the latter as success would let the
          // client mark it synced and discard it, so the photo would register
          // with cull_decision=NULL and leak into ranking. Distinguish them.
          const { data: existing } = await supabase
            .from('photos')
            .select('id')
            .eq('id', photo_id)
            .eq('session_id', session_id)
            .maybeSingle();

          if (existing) {
            return { photo_id, success: true }; // already decided — idempotent
          }
          return { photo_id, success: false, error: 'photo not yet registered' };
```

Replace with:
```typescript
          // Zero rows updated: decision already set — idempotent success.
          // With pre-registration, the photo row always exists before cull
          // starts, so zero-rows-updated means cull_decision was already written.
          return { photo_id, success: true };
```

- [ ] **Step 2: Commit**

```bash
git add backend/supabase/functions/batch-submit-cull/index.ts
git commit -m "feat(backend): simplify batch-submit-cull — remove stale existence re-query"
```

---

### Task 7: iOS Models — add BatchPreRegisterResponse

**Files:**
- Modify: `ios/Sources/App/Models/Models.swift`

- [ ] **Step 1: Add response type before the BatchSubmitResponse section**

Find:
```swift
struct BatchSubmitResponse: Decodable {
    let results: [BatchDecisionResult]
```

Add immediately before that block:
```swift
// MARK: - batch-pre-register

struct BatchPreRegisterResponse: Decodable {
    let ok: Bool
}

```

- [ ] **Step 2: Commit**

```bash
git add ios/Sources/App/Models/Models.swift
git commit -m "feat(ios): add BatchPreRegisterResponse model"
```

---

### Task 8: iOS APIClient — add batchPreRegister method

**Files:**
- Modify: `ios/Sources/App/Services/APIClient.swift`

- [ ] **Step 1: Add the method before the closing brace of APIClient**

Find the last line of `markUploadComplete`:
```swift
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
    }
}
```

Replace with:
```swift
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
    }

    // MARK: - batch-pre-register
    // POST { session_id, photo_ids } → { ok }

    func batchPreRegister(sessionId: UUID, photoIds: [UUID]) async throws {
        let url = functionsBase.appending(path: "batch-pre-register")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased(),
            "photo_ids": photoIds.map { $0.uuidString.lowercased() },
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

Run: `xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/APIClient.swift
git commit -m "feat(ios): add batchPreRegister API client method"
```

---

### Task 9: iOS SessionSetupView — call batchPreRegister before starting pipeline

**Files:**
- Modify: `ios/Sources/App/Views/SessionSetupView.swift`

- [ ] **Step 1: Update startSession() to pre-register before navigating to cull**

Find the entire `startSession()` function:
```swift
    private func startSession() {
        guard let userId = auth.userId else { return }
        let items = selectedItems
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let session = try await api.createSession(photoCount: items.count)
                let pipeline = PhotoPipeline(
                    transport: SupabaseUploadTransport(supabase: auth.storageClient, api: api),
                    sessionId: session.id,
                    userId: userId
                )
                pipeline.start(photos: items.map { PendingPhoto(loader: PickerItemLoader(item: $0)) })
                onStart(session.id, pipeline)
            } catch {
                errorMessage = "Could not start: \(error.localizedDescription)"
                isStarting = false
            }
        }
    }
```

Replace with:
```swift
    private func startSession() {
        guard let userId = auth.userId else { return }
        let items = selectedItems
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let session = try await api.createSession(photoCount: items.count)
                // Generate stable photo IDs before pre-registering so the same
                // IDs are used for both the server rows and the pipeline items.
                let pendingPhotos = items.map { PendingPhoto(loader: PickerItemLoader(item: $0)) }
                try await api.batchPreRegister(
                    sessionId: session.id,
                    photoIds: pendingPhotos.map(\.id)
                )
                let pipeline = PhotoPipeline(
                    transport: SupabaseUploadTransport(supabase: auth.storageClient, api: api),
                    sessionId: session.id,
                    userId: userId
                )
                pipeline.start(photos: pendingPhotos)
                onStart(session.id, pipeline)
            } catch {
                errorMessage = "Could not start: \(error.localizedDescription)"
                isStarting = false
            }
        }
    }
```

Note: `localizedDescription` not `localizedLength` — copy the exact original error message string.

- [ ] **Step 2: Build to confirm no compile errors**

Run: `xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Views/SessionSetupView.swift
git commit -m "feat(ios): pre-register all photo IDs before showing cull UI"
```

---

### Task 10: iOS PhotoUploadTransport — rename register to markUploaded

**Files:**
- Modify: `ios/Sources/App/Services/PhotoUploadTransport.swift`

- [ ] **Step 1: Replace the entire file with the updated protocol and conformance**

```swift
import Foundation
import Supabase

protocol PhotoUploadTransport: Sendable {
    func upload(storagePath: String, data: Data) async throws
    func markUploaded(sessionId: UUID, photoId: UUID, storagePath: String) async throws
    func markUploadComplete(sessionId: UUID) async throws
}

struct SupabaseUploadTransport: PhotoUploadTransport {
    let supabase: SupabaseClient
    let api: APIClient

    func upload(storagePath: String, data: Data) async throws {
        do {
            try await supabase.storage
                .from("working-copies")
                .upload(storagePath, data: data, options: FileOptions(contentType: "image/jpeg"))
        } catch {
            // A retry after a success whose response was lost: the object is
            // already there, which is the outcome we wanted.
            if isAlreadyExists(error) { return }
            throw error
        }
    }

    func markUploaded(sessionId: UUID, photoId: UUID, storagePath: String) async throws {
        _ = try await api.registerPhoto(sessionId: sessionId, photoId: photoId, storagePath: storagePath)
    }

    func markUploadComplete(sessionId: UUID) async throws {
        try await api.markUploadComplete(sessionId: sessionId)
    }

    private func isAlreadyExists(_ error: Error) -> Bool {
        guard let storageError = error as? StorageError else { return false }
        return storageError.statusCode == "409" || storageError.error == "Duplicate"
    }
}
```

- [ ] **Step 2: Build — expect compile errors in PhotoPipeline (updated in Task 11)**

Run: `xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep error: | head -5`

Expected: errors referencing `transport.register` in `PhotoPipeline.swift`. These are resolved in Task 11.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/PhotoUploadTransport.swift
git commit -m "refactor(ios): rename PhotoUploadTransport.register to markUploaded"
```

---

### Task 11: iOS PhotoPipeline — simplify state machine

**Files:**
- Modify: `ios/Sources/App/Services/PhotoPipeline.swift`

- [ ] **Step 1: Update PhotoRegistrationState — remove .pending**

Find:
```swift
enum PhotoRegistrationState {
    case registered   // server knows this photo
    case pending      // may still register (queued, uploading, retrying, parked)
    case unavailable  // cancelled or failed — the server will never know it
}
```

Replace with:
```swift
enum PhotoRegistrationState {
    case registered   // server row exists (guaranteed by pre-registration before cull)
    case unavailable  // local asset failed to read — no server action needed
}
```

- [ ] **Step 2: Update ItemState — remove cancelledInFlight and registered, add uploaded**

Find:
```swift
    enum ItemState: Equatable {
        case pending       // waiting to materialize
        case materialized  // compressed JPEG on disk, queued for upload
        case uploading     // an upload worker owns it
        case registered    // server row exists
        case cancelled     // dropped before any server row could exist — settle locally
        case cancelledInFlight // dropped while an upload/register worker owns it; the worker
                               // finalizes it to .cancelled (no row) or .registered (row exists)
        case parked        // retries exhausted; waits for connectivity or user retry
        case failed        // local asset could not be read — terminal
    }
```

Replace with:
```swift
    enum ItemState: Equatable {
        case pending       // waiting to materialize
        case materialized  // compressed JPEG on disk, queued for upload
        case uploading     // an upload worker owns it
        case uploaded      // bytes in storage, server row has upload_status='uploaded'
        case cancelled     // dropped — upload skipped or aborted; server has is_suppressed=true
        case parked        // retries exhausted; waits for connectivity or user retry
        case failed        // local asset could not be read — terminal
    }
```

- [ ] **Step 3: Remove the onRegistered callback property**

Find and delete:
```swift
    var onRegistered: ((UUID) -> Void)?
```

- [ ] **Step 4: Simplify registrationState(for:) — remove .pending case**

Find:
```swift
    func registrationState(for id: UUID) -> PhotoRegistrationState {
        switch items[id]?.state {
        case .registered: return .registered
        case .cancelled, .failed, nil: return .unavailable
        // .cancelledInFlight is deliberately .pending: a drop landing mid-upload
        // must be neither sent nor settled until the worker resolves the row.
        default: return .pending
        }
    }
```

Replace with:
```swift
    func registrationState(for id: UUID) -> PhotoRegistrationState {
        switch items[id]?.state {
        case .failed, nil: return .unavailable
        default: return .registered
        }
    }
```

- [ ] **Step 5: Simplify setDecision(.drop) — remove cancelledInFlight handling**

Find:
```swift
        case .drop:
            switch items[photoId]?.state {
            case .pending, .materialized, .parked:
                // No upload worker owns it yet, so no server row can exist:
                // cancel it and let the decision settle locally.
                items[photoId]?.state = .cancelled
                removeWorkingCopy(photoId)
                resumeWaiters(for: photoId, with: .failure(PipelineError.photoUnavailable))
                updateFailedIds()
                checkCompletion()
            case .uploading:
                // A worker owns it and register() may already be committing a
                // row. Hold the decision — registrationState reports .pending —
                // until uploadAndRegister resolves it to .cancelled (no row →
                // settle locally) or .registered (row exists → send the drop).
                // Settling locally now would mark the drop synced without ever
                // sending it, and the photo would leak into the ranking pool.
                items[photoId]?.state = .cancelledInFlight
                removeWorkingCopy(photoId)
                resumeWaiters(for: photoId, with: .failure(PipelineError.photoUnavailable))
                updateFailedIds()
            default:
                // registered: the row already exists; the synced drop decision
                // suppresses it server-side. cancelled/failed: already terminal.
                break
            }
```

Replace with:
```swift
        case .drop:
            switch items[photoId]?.state {
            case .pending, .materialized, .parked, .uploading:
                // The server row already exists (pre-registered). The drop decision
                // is sent to the server via SyncService — no timing dependency here.
                // Cancelling the upload saves bandwidth: a dropped photo's bytes
                // don't need to land. upload_status stays 'pending'; is_suppressed=true
                // (set by batch-submit-cull) keeps it out of the ranking pool.
                items[photoId]?.state = .cancelled
                removeWorkingCopy(photoId)
                resumeWaiters(for: photoId, with: .failure(PipelineError.photoUnavailable))
                updateFailedIds()
                checkCompletion()
            default:
                // .uploaded, .cancelled, .failed: already terminal
                break
            }
```

- [ ] **Step 6: Rename uploadAndRegister → uploadAndMarkUploaded and simplify**

Find `private func uploadAndRegister(_ id: UUID) async {` and replace the entire function:

```swift
    private func uploadAndMarkUploaded(_ id: UUID) async {
        defer {
            activeUploads -= 1
            pumpUploads()
            checkCompletion()
        }
        guard let fileURL = items[id]?.fileURL, let data = try? Data(contentsOf: fileURL) else {
            // File missing: a drop removed it or materialization failed.
            // Only flag .failed if still actively uploading (not already cancelled).
            if items[id]?.state == .uploading { items[id]?.state = .failed }
            updateFailedIds()
            return
        }
        let storagePath = "\(userId.uuidString.lowercased())/\(sessionId.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
        do {
            if items[id]?.didUpload != true {
                try await withRetries { try await self.transport.upload(storagePath: storagePath, data: data) }
                items[id]?.didUpload = true
            }
            // Photo may have been dropped while bytes were in flight. Skip
            // markUploaded — the drop is already on the server (is_suppressed=true),
            // and upload_status staying 'pending' is a second exclusion from ranking.
            guard items[id]?.state == .uploading else { return }
            try await withRetries {
                try await self.transport.markUploaded(sessionId: self.sessionId, photoId: id, storagePath: storagePath)
            }
            items[id]?.state = .uploaded
            registeredCount += 1
            updateFailedIds()
        } catch {
            if items[id]?.state == .uploading { items[id]?.state = .parked }
            updateFailedIds()
        }
    }
```

- [ ] **Step 7: Update pumpUploads to call uploadAndMarkUploaded**

Find:
```swift
            Task { await self.uploadAndRegister(id) }
```

Replace with:
```swift
            Task { await self.uploadAndMarkUploaded(id) }
```

- [ ] **Step 8: Remove cancelledInFlight from checkCompletion**

Find:
```swift
        let unresolved = order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading, .cancelledInFlight: return true
            default: return false
            }
        }
```

Replace with:
```swift
        let unresolved = order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading: return true
            default: return false
            }
        }
```

- [ ] **Step 9: Build to confirm PhotoPipeline compiles**

Run: `xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **` (test-file errors for MockTransport are fixed in Task 13)

- [ ] **Step 10: Commit**

```bash
git add ios/Sources/App/Services/PhotoPipeline.swift
git commit -m "feat(ios): simplify PhotoPipeline — remove cancelledInFlight, add uploaded state"
```

---

### Task 12: iOS SyncService + CullView — remove .pending bucket and flush timeout

**Files:**
- Modify: `ios/Sources/App/Services/SyncService.swift`
- Modify: `ios/Sources/App/Views/CullView.swift`

- [ ] **Step 1: Update partition() — remove the .pending hold bucket**

Find:
```swift
    nonisolated static func partition(
        pending: [StoredDecision],
        registrationState: (UUID) -> PhotoRegistrationState
    ) -> (send: [StoredDecision], markLocalOnly: [UUID]) {
        var send: [StoredDecision] = []
        var markLocalOnly: [UUID] = []
        for decision in pending {
            switch registrationState(decision.photoId) {
            case .registered:  send.append(decision)
            case .unavailable: markLocalOnly.append(decision.photoId)
            case .pending:     break
            }
        }
        return (send, markLocalOnly)
    }
```

Replace with:
```swift
    nonisolated static func partition(
        pending: [StoredDecision],
        registrationState: (UUID) -> PhotoRegistrationState
    ) -> (send: [StoredDecision], markLocalOnly: [UUID]) {
        var send: [StoredDecision] = []
        var markLocalOnly: [UUID] = []
        for decision in pending {
            switch registrationState(decision.photoId) {
            case .registered:  send.append(decision)
            case .unavailable: markLocalOnly.append(decision.photoId)
            }
        }
        return (send, markLocalOnly)
    }
```

- [ ] **Step 2: Simplify flush() — replace with single drain call**

Find:
```swift
    func flush() async {
        // A decision is "settled" only when its photo is .registered (its
        // decision sent) or .unavailable (settled locally). A photo still
        // mid-upload is .pending: its drop is neither sent nor settle-able yet,
        // and once we hand off to ranking this SyncService is torn down — so a
        // drop left undelivered here is lost, and a dropped photo that registers
        // afterward surfaces in comparisons (cull_decision stays NULL). So wait
        // (bounded) for every decided photo to resolve, draining as it does,
        // rather than returning the moment the sendable batch is clear.
        let deadline = ContinuousClock.now.advanced(by: Self.flushTimeout)
        while true {
            await performDrain()
            let unsettled = (store?.pendingDecisions ?? []).contains {
                registrationState($0.photoId) != .unavailable
            }
            if !unsettled { return }
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // Cap the wait so an offline/parked upload can't hang the "Done" handoff
    // indefinitely; normal in-flight uploads resolve in well under this.
    private static let flushTimeout: Duration = .seconds(5)
```

Replace with:
```swift
    func flush() async {
        // All photos have server rows from pre-registration, so every pending
        // decision is immediately sendable. One drain call is sufficient.
        await performDrain()
    }
```

- [ ] **Step 3: Remove the onRegistered trigger from CullView.initialize()**

In `CullView.swift`, find:
```swift
        // Late registrations unblock their pending keep/drop decisions.
        pipeline.onRegistered = { _ in ss.syncIfNeeded() }
```

Delete that line entirely.

- [ ] **Step 4: Build to confirm no compile errors**

Run: `xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **` (test errors from MockTransport still using `register` are expected — fixed in Task 13)

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/SyncService.swift \
        ios/Sources/App/Views/CullView.swift
git commit -m "feat(ios): simplify SyncService — remove .pending bucket and flush timeout"
```

---

### Task 13: iOS tests — update MockTransport, remove impossible race tests

**Files:**
- Modify: `ios/Tests/PhotoPipelineTests.swift`
- Modify: `ios/Tests/SyncPartitionTests.swift`

- [ ] **Step 1: Replace MockTransport in PhotoPipelineTests.swift**

Find the entire `MockTransport` class (from `@MainActor` through its closing `}`) and replace with:

```swift
@MainActor
final class MockTransport: PhotoUploadTransport {
    private(set) var uploadedPaths: [String] = []
    private(set) var markedUploadedIds: [UUID] = []
    private(set) var markCompleteCount = 0
    var uploadFailures: [UUID: Int] = [:]
    var markUploadedFailures: [UUID: Int] = [:]
    var uploadDelay: Duration = .zero

    // Gated uploads: a gated photo's upload blocks (after announcing it started)
    // until the test releases it — lets a test act while the photo is mid-upload.
    var gatedIds: Set<UUID> = []
    private(set) var startedIds: Set<UUID> = []
    var releasedIds: Set<UUID> = []

    private func photoId(fromPath path: String) -> UUID? {
        guard let filename = path.split(separator: "/").last else { return nil }
        return UUID(uuidString: String(filename.dropLast(4)))
    }

    func upload(storagePath: String, data: Data) async throws {
        if let id = photoId(fromPath: storagePath), gatedIds.contains(id) {
            startedIds.insert(id)
            while !releasedIds.contains(id) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        if uploadDelay > .zero { try? await Task.sleep(for: uploadDelay) }
        if let id = photoId(fromPath: storagePath), let n = uploadFailures[id], n > 0 {
            uploadFailures[id] = n - 1
            throw MockTransportError()
        }
        uploadedPaths.append(storagePath)
    }

    func markUploaded(sessionId: UUID, photoId: UUID, storagePath: String) async throws {
        if let n = markUploadedFailures[photoId], n > 0 {
            markUploadedFailures[photoId] = n - 1
            throw MockTransportError()
        }
        markedUploadedIds.append(photoId)
    }

    func markUploadComplete(sessionId: UUID) async throws {
        markCompleteCount += 1
    }
}
```

- [ ] **Step 2: Replace transport.registeredIds → transport.markedUploadedIds throughout PhotoPipelineTests.swift**

Run a find-and-replace in the file: `transport.registeredIds` → `transport.markedUploadedIds`

Also replace: `transport.registerFailures` → `transport.markUploadedFailures`

- [ ] **Step 3: Update testDropWhileUploadingDoesNotRegister assertions**

Find:
```swift
        XCTAssertFalse(transport.registeredIds.contains(photo.id))
        XCTAssertEqual(pipeline.registeredCount, 0)
        XCTAssertEqual(pipeline.registrationState(for: photo.id), .unavailable)
```

Replace with:
```swift
        // Drop during upload: bytes may have gone to storage, but markUploaded was
        // not called — upload_status stays 'pending'. The server excludes this photo
        // via is_suppressed=true (set by batch-submit-cull for the drop decision).
        XCTAssertFalse(transport.markedUploadedIds.contains(photo.id))
        XCTAssertEqual(pipeline.registeredCount, 0)
        // Row exists (pre-registered) — registrationState is .registered, not .unavailable.
        XCTAssertEqual(pipeline.registrationState(for: photo.id), .registered)
```

- [ ] **Step 4: Remove DropDuringRegistrationRaceTests class entirely**

Find and delete from the comment block starting with:
```swift
// Reproduces the leak that survives the .uploading-guard and flush() fixes:
```
through the final `}` that closes `DropDuringRegistrationRaceTests`.

This entire class tested the `cancelledInFlight` race — a scenario that is structurally impossible with pre-registration.

- [ ] **Step 5: Update SyncPartitionTests.testPartitionsByRegistrationState**

Find:
```swift
    func testPartitionsByRegistrationState() {
        let registered = UUID()
        let inFlight = UUID()
        let cancelled = UUID()
        let decisions = [
            StoredDecision(photoId: registered, decision: .keep, timestamp: .now, synced: false),
            StoredDecision(photoId: inFlight, decision: .keep, timestamp: .now, synced: false),
            StoredDecision(photoId: cancelled, decision: .drop, timestamp: .now, synced: false),
        ]
        let states: [UUID: PhotoRegistrationState] = [
            registered: .registered,
            inFlight: .pending,
            cancelled: .unavailable,
        ]

        let (send, markLocalOnly) = SyncService.partition(
            pending: decisions,
            registrationState: { states[$0] ?? .pending }
        )

        XCTAssertEqual(send.map(\.photoId), [registered])
        XCTAssertEqual(markLocalOnly, [cancelled])
    }
```

Replace with:
```swift
    func testPartitionsByRegistrationState() {
        let registered = UUID()
        let failed = UUID()
        let decisions = [
            StoredDecision(photoId: registered, decision: .keep, timestamp: .now, synced: false),
            StoredDecision(photoId: failed, decision: .drop, timestamp: .now, synced: false),
        ]
        let states: [UUID: PhotoRegistrationState] = [
            registered: .registered,
            failed: .unavailable,
        ]

        let (send, markLocalOnly) = SyncService.partition(
            pending: decisions,
            registrationState: { states[$0] ?? .registered }
        )

        XCTAssertEqual(send.map(\.photoId), [registered])
        XCTAssertEqual(markLocalOnly, [failed])
    }
```

- [ ] **Step 6: Remove testFlushWaitsForDropStillPendingRegistration from SyncPartitionTests**

Find and delete the entire `testFlushWaitsForDropStillPendingRegistration` function and its preceding comment block. This test verified flush() blocks on `.pending` registration state — that state no longer exists.

- [ ] **Step 7: Run the full iOS test suite**

Run: `xcodebuild test -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E 'Test Suite|PASS|FAIL|error:'`

Expected: all tests pass.

- [ ] **Step 8: Run backend shared tests**

Run: `cd backend && deno test supabase/functions/_shared/ --allow-env`

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add ios/Tests/PhotoPipelineTests.swift \
        ios/Tests/SyncPartitionTests.swift
git commit -m "test(ios): update tests for pre-registration — remove cancelledInFlight race tests"
```
