# Cull Phase Prefetch Architecture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sequential-fetch cull model with a prefetch queue + local-first decision store so card transitions take < 100ms P50 instead of 600–1500ms.

**Architecture:** A `CullPrefetchService` keeps 5–20 decoded images in RAM, refilling from a new `prefetch-cull` POST endpoint before the queue runs low. `DecisionStore` records swipe decisions in-memory and persists them atomically to disk via a background actor; `SyncService` drains pending decisions to a new `batch-submit-cull` endpoint in the background. The swipe hot path is two synchronous calls — zero network waits.

**Tech Stack:** Swift 5.9+ `@Observable @MainActor`, structured concurrency (`async let`, `withTaskGroup`, `AsyncStream`), `actor` for serial file I/O; Deno/TypeScript Edge Functions with Zod validation; Supabase Postgres with new `upload_complete` column.

**Spec:** `docs/superpowers/specs/2026-05-30-cull-phase-prefetch-architecture-design.md`

---

## File Map

### Create
| File | Responsibility |
|---|---|
| `backend/supabase/migrations/20260530_upload_complete.sql` | Add `upload_complete` boolean to `sessions` table |
| `backend/supabase/functions/mark-upload-complete/index.ts` | Sets `upload_complete = true` when iOS upload finishes |
| `backend/supabase/functions/prefetch-cull/index.ts` | Returns a batch of upcoming cull cards with thumbnail URLs |
| `backend/supabase/functions/batch-submit-cull/index.ts` | Syncs a local decision queue to the DB in one request |
| `ios/Sources/App/Services/DecisionStore.swift` | In-memory + disk-persisted decision log; pending sync queue |
| `ios/Sources/App/Services/CullPrefetchService.swift` | In-memory prefetch queue with adaptive sizing + image pipeline |
| `ios/Sources/App/Services/SyncService.swift` | Background sync of pending decisions to `batch-submit-cull` |

### Modify
| File | Changes |
|---|---|
| `ios/Sources/App/Models/Models.swift` | Add `CullDecision`, `StoredDecision`, `SessionDecisionFile`, `PrefetchCullCard`, `PrefetchCullResponse`, `BatchDecisionResult`, `BatchSubmitResponse` (`CullQueueState` lives in `CullPrefetchService.swift`) |
| `ios/Sources/App/Services/APIClient.swift` | Add `prefetchCull()`, `batchSubmitCull()`, `markUploadComplete()` |
| `ios/Sources/App/Services/UploadService.swift` | Call `api.markUploadComplete(sessionId:)` after all photos registered |
| `ios/Sources/App/Views/CullView.swift` | Full refactor — consume `CullPrefetchService` + `DecisionStore`, remove `AsyncImage` and network calls |

---

## Task 1: DB migration — upload_complete column

**Files:**
- Create: `backend/supabase/migrations/20260530_upload_complete.sql`

- [ ] **Step 1: Create the migration file**

```sql
ALTER TABLE sessions
    ADD COLUMN upload_complete boolean NOT NULL DEFAULT false;
```

Save to `backend/supabase/migrations/20260530_upload_complete.sql`.

- [ ] **Step 2: Apply the migration**

```bash
cd backend && supabase db push
```

Expected output: `Applied 1 migration(s)`.

- [ ] **Step 3: Verify the column exists**

```bash
cd backend && supabase db execute --sql "SELECT column_name, data_type, column_default FROM information_schema.columns WHERE table_name = 'sessions' AND column_name = 'upload_complete';"
```

Expected: one row — `upload_complete | boolean | false`.

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/migrations/20260530_upload_complete.sql
git commit -m "feat(db): add upload_complete column to sessions"
```

---

## Task 2: mark-upload-complete edge function

**Files:**
- Create: `backend/supabase/functions/mark-upload-complete/index.ts`

- [ ] **Step 1: Create the function**

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BodySchema = z.object({ session_id: z.string().uuid() });

Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    let body: unknown;
    try { body = await req.json(); } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const parsed = BodySchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    const { error } = await supabase
      .from('sessions')
      .update({ upload_complete: true })
      .eq('id', parsed.data.session_id);

    if (error) {
      return new Response(JSON.stringify({ error: error.message }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
```

Save to `backend/supabase/functions/mark-upload-complete/index.ts`.

- [ ] **Step 2: Deploy the function**

```bash
cd backend && supabase functions deploy mark-upload-complete
```

Expected: `Deployed function mark-upload-complete`.

- [ ] **Step 3: Smoke test**

Get an auth token from the Supabase dashboard (Authentication → Users → copy a JWT) and a real `session_id`. Then:

```bash
curl -s -X POST https://<project-ref>.supabase.co/functions/v1/mark-upload-complete \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"session_id": "<valid-uuid>"}' | jq .
```

Expected: `{"ok": true}`.

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/mark-upload-complete/
git commit -m "feat(backend): add mark-upload-complete edge function"
```

---

## Task 3: prefetch-cull edge function

**Files:**
- Create: `backend/supabase/functions/prefetch-cull/index.ts`

- [ ] **Step 1: Create the function**

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BodySchema = z.object({
  session_id:      z.string().uuid(),
  count:           z.number().int().min(1).max(50),
  exclude_ids:     z.array(z.string().uuid()).default([]),
  thumbnail_width: z.number().int().min(100).max(3000),
});

type PhotoRow = {
  id: string;
  storage_path: string;
  cluster_id: string | null;
  quality_flags: Record<string, unknown> | null;
};

Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    let body: unknown;
    try { body = await req.json(); } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const parsed = BodySchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    const { session_id, count, exclude_ids, thumbnail_width } = parsed.data;

    // Gate has_more on upload completion
    const { data: session, error: sessionError } = await supabase
      .from('sessions')
      .select('upload_complete')
      .eq('id', session_id)
      .single();

    if (sessionError || !session) {
      return new Response(JSON.stringify({ error: 'Session not found' }), {
        status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // Fetch undecided, unsuppressed photos — apply exclude filter before grouping
    let query = supabase
      .from('photos')
      .select('id, storage_path, cluster_id, quality_flags')
      .eq('session_id', session_id)
      .eq('is_suppressed', false)
      .is('cull_decision', null)
      .order('cluster_id')
      .order('id');

    if (exclude_ids.length > 0) {
      query = query.not('id', 'in', `(${exclude_ids.join(',')})`);
    }

    const { data: photos, error: photosError } = await query;

    if (photosError) {
      return new Response(JSON.stringify({ error: photosError.message }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    if (!photos || photos.length === 0) {
      const hasMore = !session.upload_complete;
      return new Response(JSON.stringify({ cards: [], has_more: hasMore }), {
        status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // Group by cluster; pick highest blur_score representative per cluster
    type ClusterGroup = { representative: PhotoRow; count: number; blurScore: number };
    const clusters = new Map<string, ClusterGroup>();

    for (const p of photos as PhotoRow[]) {
      const blurScore = typeof p.quality_flags?.blur_score === 'number' ? p.quality_flags.blur_score : 0;
      const clusterKey = p.cluster_id ?? p.id;
      const existing = clusters.get(clusterKey);
      if (!existing) {
        clusters.set(clusterKey, { representative: p, count: 1, blurScore });
      } else {
        existing.count++;
        if (blurScore > existing.blurScore) {
          existing.representative = p;
          existing.blurScore = blurScore;
        }
      }
    }

    const eligibleClusters = [...clusters.values()];
    const batch = eligibleClusters.slice(0, count);
    const hasMore = !session.upload_complete || eligibleClusters.length > count;

    // Generate all signed thumbnail URLs in parallel
    const cards = await Promise.all(
      batch.map(async ({ representative: rep, count: clusterSize }) => {
        const { data: signed } = await supabase.storage
          .from('working-copies')
          .createSignedUrl(rep.storage_path, 3600, {
            transform: { width: thumbnail_width, quality: 75 },
          });
        return {
          photo_id:     rep.id,
          photo_url:    signed?.signedUrl ?? null,
          cluster_id:   rep.cluster_id,
          cluster_size: clusterSize,
        };
      })
    );

    const validCards = cards.filter(c => c.photo_url !== null);

    return new Response(JSON.stringify({ cards: validCards, has_more: hasMore }), {
      status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
```

Save to `backend/supabase/functions/prefetch-cull/index.ts`.

- [ ] **Step 2: Deploy**

```bash
cd backend && supabase functions deploy prefetch-cull
```

Expected: `Deployed function prefetch-cull`.

- [ ] **Step 3: Smoke test**

```bash
curl -s -X POST https://<project-ref>.supabase.co/functions/v1/prefetch-cull \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"<valid-uuid>","count":5,"exclude_ids":[],"thumbnail_width":375}' | jq .
```

Expected: `{"cards":[{"photo_id":"...","photo_url":"https://...","cluster_id":"...","cluster_size":1}],"has_more":false}`.

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/prefetch-cull/
git commit -m "feat(backend): add prefetch-cull edge function"
```

---

## Task 4: batch-submit-cull edge function

**Files:**
- Create: `backend/supabase/functions/batch-submit-cull/index.ts`

- [ ] **Step 1: Create the function**

```typescript
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { initSentry, Sentry } from '../_shared/sentry.ts';
initSentry();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BodySchema = z.object({
  session_id: z.string().uuid(),
  decisions:  z.array(z.object({
    photo_id: z.string().uuid(),
    decision: z.enum(['keep', 'drop']),
  })).min(1),
});

Deno.serve(async (req) => {
  try {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    let body: unknown;
    try { body = await req.json(); } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const parsed = BodySchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    const { session_id, decisions } = parsed.data;

    // Process each decision with same cluster-wide logic as submit-cull.
    // cull_decision IS NULL guard makes this idempotent — safe to retry.
    const results = await Promise.all(
      decisions.map(async ({ photo_id, decision }) => {
        try {
          const { data: photo, error: photoError } = await supabase
            .from('photos')
            .select('cluster_id')
            .eq('id', photo_id)
            .eq('session_id', session_id)
            .single();

          if (photoError || !photo) {
            return { photo_id, success: false, error: 'Photo not found' };
          }

          const update = decision === 'keep'
            ? { cull_decision: 'keep' }
            : { cull_decision: 'drop', is_suppressed: true };

          const { error: updateError } = await supabase
            .from('photos')
            .update(update)
            .eq('cluster_id', photo.cluster_id)
            .eq('session_id', session_id)
            .is('cull_decision', null);

          if (updateError) {
            return { photo_id, success: false, error: updateError.message };
          }

          return { photo_id, success: true };
        } catch (err) {
          return { photo_id, success: false, error: String(err) };
        }
      })
    );

    return new Response(JSON.stringify({ results }), {
      status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
```

Save to `backend/supabase/functions/batch-submit-cull/index.ts`.

- [ ] **Step 2: Deploy**

```bash
cd backend && supabase functions deploy batch-submit-cull
```

Expected: `Deployed function batch-submit-cull`.

- [ ] **Step 3: Smoke test**

```bash
curl -s -X POST https://<project-ref>.supabase.co/functions/v1/batch-submit-cull \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"<uuid>","decisions":[{"photo_id":"<photo-uuid>","decision":"keep"}]}' | jq .
```

Expected: `{"results":[{"photo_id":"...","success":true}]}`.

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/batch-submit-cull/
git commit -m "feat(backend): add batch-submit-cull edge function"
```

---

## Task 5: iOS Models — new response types

**Files:**
- Modify: `ios/Sources/App/Models/Models.swift`

- [ ] **Step 1: Add new types to the bottom of Models.swift**

Append after the last `// MARK:` section:

```swift
// MARK: - CullDecision

enum CullDecision: String, Codable, Sendable {
    case keep
    case drop
}

// MARK: - DecisionStore types

struct StoredDecision: Codable, Sendable {
    let photoId: UUID
    let decision: CullDecision
    let timestamp: Date
    var synced: Bool

    enum CodingKeys: String, CodingKey {
        case photoId    = "photo_id"
        case decision
        case timestamp
        case synced
    }
}

struct SessionDecisionFile: Codable {
    let sessionId: UUID
    var decisions: [StoredDecision]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case decisions
    }
}

// MARK: - prefetch-cull

struct PrefetchCullCard: Decodable {
    let photoId:     UUID
    let photoUrl:    String
    let clusterId:   String?
    let clusterSize: Int

    enum CodingKeys: String, CodingKey {
        case photoId     = "photo_id"
        case photoUrl    = "photo_url"
        case clusterId   = "cluster_id"
        case clusterSize = "cluster_size"
    }
}

struct PrefetchCullResponse: Decodable {
    let cards:   [PrefetchCullCard]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case cards
        case hasMore = "has_more"
    }
}

// MARK: - batch-submit-cull

struct BatchDecisionResult: Decodable {
    let photoId:  UUID
    let success:  Bool
    let error:    String?

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case success
        case error
    }
}

struct BatchSubmitResponse: Decodable {
    let results: [BatchDecisionResult]
}

```

- [ ] **Step 2: Build to verify no type errors**

Open Xcode or run:
```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Models/Models.swift
git commit -m "feat(ios): add prefetch and decision model types"
```

---

## Task 6: APIClient additions

**Files:**
- Modify: `ios/Sources/App/Services/APIClient.swift`

- [ ] **Step 1: Add three new methods to APIClient.swift**

Insert after the existing `// MARK: - finish-cull` block (after line 214):

```swift
// MARK: - prefetch-cull
// POST { session_id, count, exclude_ids, thumbnail_width } → { cards, has_more }

func prefetchCull(
    sessionId: UUID,
    count: Int,
    excludeIds: [UUID],
    thumbnailWidth: Int
) async throws -> PrefetchCullResponse {
    let url = functionsBase.appending(path: "prefetch-cull")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "session_id":      sessionId.uuidString.lowercased(),
        "count":           count,
        "exclude_ids":     excludeIds.map { $0.uuidString.lowercased() },
        "thumbnail_width": thumbnailWidth,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    try validate(response, data: data)
    return try decoder.decode(PrefetchCullResponse.self, from: data)
}

// MARK: - batch-submit-cull
// POST { session_id, decisions } → { results }

func batchSubmitCull(sessionId: UUID, decisions: [StoredDecision]) async throws -> BatchSubmitResponse {
    let url = functionsBase.appending(path: "batch-submit-cull")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "session_id": sessionId.uuidString.lowercased(),
        "decisions":  decisions.map { d in
            ["photo_id": d.photoId.uuidString.lowercased(), "decision": d.decision.rawValue]
        },
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    try validate(response, data: data)
    return try decoder.decode(BatchSubmitResponse.self, from: data)
}

// MARK: - mark-upload-complete
// POST { session_id } → { ok }

func markUploadComplete(sessionId: UUID) async throws {
    let url = functionsBase.appending(path: "mark-upload-complete")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "session_id": sessionId.uuidString.lowercased(),
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    try validate(response, data: data)
}
```

- [ ] **Step 2: Build to verify**

```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/APIClient.swift
git commit -m "feat(ios): add prefetchCull, batchSubmitCull, markUploadComplete to APIClient"
```

---

## Task 7: DecisionStore.swift

**Files:**
- Create: `ios/Sources/App/Services/DecisionStore.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

@Observable @MainActor
final class DecisionStore {
    private(set) var decisions: [StoredDecision] = []

    private let (stream, continuation) = AsyncStream.makeStream(
        of: [StoredDecision].self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private let persistence = DecisionPersistence()

    var allDecidedIds: [UUID]            { decisions.map(\.photoId) }
    var pendingDecisions: [StoredDecision] { decisions.filter { !$0.synced } }

    // Loads decisions from disk and starts the persistence write loop.
    // Must complete before CullPrefetchService.start() is called.
    func load(sessionId: UUID) async -> [UUID] {
        decisions = await persistence.load(sessionId: sessionId)
        // Capture stream and persistence by value to avoid retaining self in the Task.
        // The stream terminates when deinit calls continuation.finish().
        let s = stream
        let p = persistence
        Task { await p.run(stream: s, sessionId: sessionId) }
        return allDecidedIds
    }

    func record(photoId: UUID, decision: CullDecision) {
        decisions.append(StoredDecision(
            photoId: photoId,
            decision: decision,
            timestamp: .now,
            synced: false
        ))
        continuation.yield(decisions)
    }

    func markSynced(photoIds: [UUID]) {
        let idSet = Set(photoIds)
        for i in decisions.indices where idSet.contains(decisions[i].photoId) {
            decisions[i].synced = true
        }
        continuation.yield(decisions)
    }

    deinit { continuation.finish() }
}

actor DecisionPersistence {
    private let fileManager = FileManager.default
    private let decoder     = JSONDecoder()
    private let encoder     = JSONEncoder()

    private func fileURL(sessionId: UUID) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("cull_\(sessionId.uuidString.lowercased()).json")
    }

    func load(sessionId: UUID) -> [StoredDecision] {
        let url = fileURL(sessionId: sessionId)
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(SessionDecisionFile.self, from: data)
        else { return [] }
        return file.decisions
    }

    func run(stream: AsyncStream<[StoredDecision]>, sessionId: UUID) async {
        for await snapshot in stream {
            save(snapshot, sessionId: sessionId)
        }
    }

    private func save(_ decisions: [StoredDecision], sessionId: UUID) {
        let file = SessionDecisionFile(sessionId: sessionId, decisions: decisions)
        guard let data = try? encoder.encode(file) else { return }
        let dest = fileURL(sessionId: sessionId)
        let tmp  = dest.deletingLastPathComponent()
            .appendingPathComponent("cull_\(sessionId.uuidString.lowercased()).tmp.json")
        do {
            try data.write(to: tmp)
            _ = try fileManager.replaceItem(
                at: dest, withItemAt: tmp,
                backupItemName: nil, options: [], resultingItemURL: nil
            )
        } catch {
            try? fileManager.removeItem(at: tmp)
        }
    }
}
```

Save to `ios/Sources/App/Services/DecisionStore.swift`.

- [ ] **Step 2: Build to verify**

```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/DecisionStore.swift
git commit -m "feat(ios): add DecisionStore with async disk persistence"
```

---

## Task 8: CullPrefetchService.swift

**Files:**
- Create: `ios/Sources/App/Services/CullPrefetchService.swift`

- [ ] **Step 1: Create the file**

```swift
import UIKit

enum CullQueueState: Equatable {
    case loading
    case ready
    case exhausted
    case error(String)
}

@Observable @MainActor
final class CullPrefetchService {

    struct PrefetchedCard: Sendable {
        let photoId:     UUID
        let clusterSize: Int?
        let image:       UIImage
    }

    private static let normalQueueSize = 20
    private static let minQueueSize    = 5
    private let batchSize              = 15
    private let refillThreshold        = 5
    private let maxConcurrentDownloads = 4

    private(set) var queue: [PrefetchedCard]  = []
    private(set) var state: CullQueueState    = .loading
    private var isFetching                    = false
    private var inFlightIds: Set<UUID>        = []
    private var serverExhausted               = false
    private var currentMaxQueueSize           = Self.normalQueueSize

    private let api:           APIClient
    private let decisionStore: DecisionStore
    private let sessionId:     UUID
    private var memoryWarningObserver: NSObjectProtocol?

    init(sessionId: UUID, api: APIClient, decisionStore: DecisionStore) {
        self.sessionId     = sessionId
        self.api           = api
        self.decisionStore = decisionStore

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMemoryWarning() }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Call after DecisionStore.load() completes. decidedIds must be the
    // full set of already-decided photo IDs so the first request excludes them.
    func start(excluding decidedIds: [UUID]) async {
        await refill(initialExclude: decidedIds)
    }

    // Synchronous pop from queue. Triggers a background refill when queue
    // drops to refillThreshold. Returns nil only when queue is empty.
    func advance() -> PrefetchedCard? {
        guard !queue.isEmpty else {
            if serverExhausted { state = .exhausted }
            return nil
        }
        let card = queue.removeFirst()
        if queue.isEmpty && serverExhausted {
            state = .exhausted
        } else if !serverExhausted && queue.count <= refillThreshold && !isFetching {
            Task { await refill() }
        }
        return card
    }

    // Called from the error-state retry button.
    func retry() {
        Task { await refill() }
    }

    // MARK: - Private

    private func refill(initialExclude: [UUID]? = nil) async {
        guard !isFetching else { return }
        isFetching = true

        // Full exclusion: decided + queued + actively downloading
        let excludeIds = Set(initialExclude ?? decisionStore.allDecidedIds)
            .union(queue.map(\.photoId))
            .union(inFlightIds)

        let thumbnailWidth = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        var batchIds: [UUID] = []
        var attempt = 0

        do {
            var response: PrefetchCullResponse
            repeat {
                response = try await api.prefetchCull(
                    sessionId: sessionId,
                    count: batchSize,
                    excludeIds: Array(excludeIds),
                    thumbnailWidth: thumbnailWidth
                )
                if response.cards.isEmpty && response.hasMore {
                    attempt += 1
                    try await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            } while response.cards.isEmpty && response.hasMore && attempt < 3

            if !response.hasMore { serverExhausted = true }

            batchIds = response.cards.map(\.photoId)
            inFlightIds.formUnion(batchIds)

            // Bounded pipeline: 4 concurrent downloads, add next as each finishes
            var prefetched: [PrefetchedCard] = []
            var it = response.cards.makeIterator()

            await withTaskGroup(of: PrefetchedCard?.self) { group in
                for _ in 0..<min(maxConcurrentDownloads, response.cards.count) {
                    if let card = it.next() { group.addTask { await Self.download(card) } }
                }
                for await result in group {
                    if let card = result { prefetched.append(card) }
                    if let next = it.next() { group.addTask { await Self.download(next) } }
                }
            }

            inFlightIds.subtract(batchIds)
            queue.append(contentsOf: prefetched)

            // Enforce cap; evict oldest (furthest from next display)
            if queue.count > currentMaxQueueSize {
                queue.removeFirst(queue.count - currentMaxQueueSize)
            }
            // Gradual recovery toward normalQueueSize after a clean cycle
            currentMaxQueueSize = min(currentMaxQueueSize + 5, Self.normalQueueSize)

            if serverExhausted && queue.isEmpty {
                state = .exhausted
            } else if !queue.isEmpty {
                state = .ready
            }

        } catch {
            inFlightIds.subtract(batchIds)
            if queue.isEmpty {
                state = .error("Couldn't load photos — tap to retry")
            }
            // If queue has cards, failure is invisible — state stays .ready
        }

        isFetching = false
    }

    // nonisolated: runs off main actor; UIImage(data:) is thread-safe post-iOS 13
    private nonisolated static func download(_ card: PrefetchCullCard) async -> PrefetchedCard? {
        guard let url = URL(string: card.photoUrl),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data)
        else { return nil }
        return PrefetchedCard(photoId: card.photoId, clusterSize: card.clusterSize, image: image)
    }

    @MainActor
    private func handleMemoryWarning() {
        currentMaxQueueSize = Self.minQueueSize
        if queue.count > currentMaxQueueSize {
            queue.removeLast(queue.count - currentMaxQueueSize)
        }
    }
}
```

Save to `ios/Sources/App/Services/CullPrefetchService.swift`.

- [ ] **Step 2: Build to verify**

```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/CullPrefetchService.swift
git commit -m "feat(ios): add CullPrefetchService with adaptive prefetch pipeline"
```

---

## Task 9: SyncService.swift

**Files:**
- Create: `ios/Sources/App/Services/SyncService.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
import Network

@MainActor
final class SyncService {
    private let api:       APIClient
    private let sessionId: UUID
    private var store:     DecisionStore?
    private var isDraining = false
    private var monitor:   NWPathMonitor?

    init(sessionId: UUID, api: APIClient) {
        self.sessionId = sessionId
        self.api       = api
    }

    // Awaits an initial drain attempt, then sets up foreground + network triggers.
    func start(store: DecisionStore) async {
        self.store = store
        await drain()
        startObservers()
    }

    // MARK: - Private

    private func startObservers() {
        // Re-drain on app foreground
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification
            ) {
                await self?.drain()
            }
        }

        // Re-drain on connectivity restore
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { continuation.yield() }
        }
        monitor.start(queue: DispatchQueue(label: "sync.monitor", qos: .background))

        Task { @MainActor [weak self] in
            for await _ in stream { await self?.drain() }
        }
    }

    // Sends all pending decisions in one request; marks successes as synced.
    // Retries with exponential backoff (1s, 2s, 4s) before giving up.
    // Failed entries remain pending and will be retried on the next trigger.
    private func drain() async {
        guard !isDraining, let store else { return }
        let pending = store.pendingDecisions
        guard !pending.isEmpty else { return }

        isDraining = true
        defer { isDraining = false }

        let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        var attempt = 0

        while true {
            do {
                let response = try await api.batchSubmitCull(sessionId: sessionId, decisions: pending)
                let succeeded = response.results.filter(\.success).map(\.photoId)
                if !succeeded.isEmpty { store.markSynced(photoIds: succeeded) }
                return
            } catch {
                guard attempt < backoff.count else { return }
                try? await Task.sleep(for: backoff[attempt])
                attempt += 1
            }
        }
    }
}
```

Save to `ios/Sources/App/Services/SyncService.swift`.

- [ ] **Step 2: Build to verify**

```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/SyncService.swift
git commit -m "feat(ios): add SyncService for background decision sync"
```

---

## Task 10: UploadService — mark upload complete

**Files:**
- Modify: `ios/Sources/App/Services/UploadService.swift`

- [ ] **Step 1: Add markUploadComplete call in runAll**

Locate `runAll(items:sessionId:userId:)`. After the `withTaskGroup` block completes and before (or after) `isComplete = true`, add the call. The full method becomes:

```swift
private func runAll(items: [PhotosPickerItem], sessionId: UUID, userId: UUID) async {
    await withTaskGroup(of: Void.self) { group in
        var iter = items.makeIterator()

        func addNext() {
            guard let item = iter.next() else { return }
            group.addTask { @MainActor in
                await self.uploadOne(item: item, sessionId: sessionId, userId: userId)
            }
        }

        for _ in 0..<4 { addNext() }
        for await _ in group { addNext() }
    }
    isComplete = true
    try? await api.markUploadComplete(sessionId: sessionId)
}
```

The `try?` swallows the error — a failed mark is non-fatal; `has_more` will stay `true` longer than necessary but the cull will still terminate correctly when the server sees all photos as decided.

- [ ] **Step 2: Build to verify**

```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/UploadService.swift
git commit -m "feat(ios): mark upload_complete after all photos registered"
```

---

## Task 11: CullView refactor

**Files:**
- Modify: `ios/Sources/App/Views/CullView.swift`

- [ ] **Step 1: Replace the entire file**

The existing `CullView.swift` does network calls on every swipe. Replace it entirely:

```swift
import SwiftUI

struct CullView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    @ObservedObject var uploadService: UploadService
    var onComplete: () -> Void

    @State private var decisionStore  = DecisionStore()
    @State private var prefetchService: CullPrefetchService?
    @State private var syncService:     SyncService?
    @State private var currentCard:     CullPrefetchService.PrefetchedCard?
    @State private var dragOffset:      CGFloat = 0
    @State private var isFinishing      = false
    @State private var finishFailed     = false

    private var screenWidth: CGFloat  { UIScreen.main.bounds.width }
    private var dragProgress: CGFloat { dragOffset / (screenWidth * 0.4) }

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                switch prefetchService?.state ?? .loading {
                case .loading:
                    Spacer()
                    ProgressView().tint(Color.amber)
                    Spacer()

                case .ready:
                    if let card = currentCard {
                        Spacer()
                        cardStack(card: card)
                        Spacer()
                        bottomButtons(card: card)
                    }

                case .exhausted:
                    Color.clear.onAppear { onComplete() }

                case .error(let message):
                    Spacer()
                    VStack(spacing: 12) {
                        Text(message)
                            .font(.bodySerif)
                            .foregroundStyle(Color.amber)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry") { prefetchService?.retry() }
                            .font(.labelSerif)
                            .foregroundStyle(Color.filmWhite)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.amber)
                            .cornerRadius(.interactiveRadius)
                    }
                    Spacer()
                }
            }
        }
        .task { await initialize() }
    }

    // MARK: - Initialization

    private func initialize() async {
        let ps = CullPrefetchService(sessionId: sessionId, api: api, decisionStore: decisionStore)
        let ss = SyncService(sessionId: sessionId, api: api)
        prefetchService = ps
        syncService     = ss

        async let syncReady: Void = ss.start(store: decisionStore)
        let decidedIds = await decisionStore.load(sessionId: sessionId)
        await ps.start(excluding: decidedIds)
        await syncReady

        currentCard = ps.advance()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if uploadService.total > 0 {
                let remaining = max(0, uploadService.total - decisionStore.decisions.count)
                Text("\(remaining) remaining")
                    .font(.captionSerif)
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            Button(isFinishing ? "Finishing…" : "Done — start comparing") {
                guard !isFinishing else { return }
                isFinishing  = true
                finishFailed = false
                Task { await finish() }
            }
            .font(.labelSerif)
            .foregroundStyle(finishFailed ? Color.red : Color.amber)
            .disabled(isFinishing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Card stack

    @ViewBuilder
    private func cardStack(card: CullPrefetchService.PrefetchedCard) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: card.image)
                .resizable()
                .scaledToFit()
                .cornerRadius(.photoRadius)
                .overlay(
                    Group {
                        if dragOffset > 0 {
                            Color.green.opacity(min(dragProgress, 1.0) * 0.35)
                                .cornerRadius(.photoRadius)
                        } else if dragOffset < 0 {
                            Color.red.opacity(min(-dragProgress, 1.0) * 0.35)
                                .cornerRadius(.photoRadius)
                        }
                    }
                )
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in dragOffset = value.translation.width }
                        .onEnded { value in
                            let threshold = screenWidth * 0.4
                            if value.translation.width > threshold {
                                commitDecision(.keep, card: card)
                            } else if value.translation.width < -threshold {
                                commitDecision(.drop, card: card)
                            } else {
                                withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                            }
                        }
                )

            if let size = card.clusterSize, size > 1 {
                Text("1 of \(size) similar")
                    .font(.captionSerif)
                    .foregroundStyle(Color.filmWhite)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.photoOverlay)
                    .cornerRadius(4)
                    .padding(12)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Bottom buttons

    @ViewBuilder
    private func bottomButtons(card: CullPrefetchService.PrefetchedCard) -> some View {
        HStack(spacing: 20) {
            Button(action: { commitDecision(.drop, card: card) }) {
                Label("Drop", systemImage: "xmark")
                    .font(.labelSerif)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.grainPaper)
                    .foregroundStyle(Color.ink)
                    .cornerRadius(.interactiveRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: .interactiveRadius)
                            .stroke(Color.divider, lineWidth: 1)
                    )
            }
            Button(action: { commitDecision(.keep, card: card) }) {
                Label("Keep", systemImage: "checkmark")
                    .font(.labelSerif)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.amber)
                    .foregroundStyle(Color.filmWhite)
                    .cornerRadius(.interactiveRadius)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    // MARK: - Actions

    private func commitDecision(_ decision: CullDecision, card: CullPrefetchService.PrefetchedCard) {
        // Hot path: zero blocking — record in-memory, pop next card from queue
        decisionStore.record(photoId: card.photoId, decision: decision)

        let flyDirection: CGFloat = decision == .keep ? 1 : -1
        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = flyDirection * screenWidth * 1.5
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            dragOffset  = 0
            currentCard = prefetchService?.advance()
        }
    }

    private func finish() async {
        do {
            try await api.finishCull(sessionId: sessionId)
            onComplete()
        } catch {
            finishFailed = true
        }
        isFinishing = false
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd ios && xcodebuild -scheme Pictalis -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Views/CullView.swift
git commit -m "feat(ios): refactor CullView to use prefetch queue and local-first decisions"
```

---

## Task 12: End-to-end integration test

No new files — manual verification in the iOS Simulator.

- [ ] **Step 1: Run the app in Simulator**

In Xcode, select an iPhone 15 simulator and press Run (⌘R).

- [ ] **Step 2: Complete the upload and enter cull**

Upload 10+ photos. On the "How would you like to start?" screen, tap "Filter then rank". Verify the first card appears (spinner disappears) within 5 seconds.

- [ ] **Step 3: Verify fast transitions**

Swipe 5 cards in quick succession (keep or drop). Each transition should feel instant — no visible loading spinner between cards. If a spinner appears between swipes, the prefetch queue is not being used.

- [ ] **Step 4: Verify remaining count**

The "N remaining" label in the top-left should decrement by 1 with each swipe. Confirm it never shows a negative number.

- [ ] **Step 5: Verify "Done — start comparing" works**

Tap "Done — start comparing" mid-session. The app should transition to the comparison (ranking) phase.

- [ ] **Step 6: Verify session resume**

Swipe 3 cards. Force-quit the app (swipe up in app switcher). Re-launch. Navigate back to the session. Swipe a new card. The 3 already-decided cards should not reappear — the `DecisionStore` loaded them from disk and excluded them from the prefetch request.

- [ ] **Step 7: Check Supabase logs for sync**

In the Supabase dashboard → Edge Functions → `batch-submit-cull` → Logs. After completing the session or regaining network, verify POST requests appear with `results` array showing `success: true` entries.

- [ ] **Step 8: Verify exhaustion**

Swipe through all cards. Verify the app transitions to the comparison phase automatically (not stuck on spinner or error).
