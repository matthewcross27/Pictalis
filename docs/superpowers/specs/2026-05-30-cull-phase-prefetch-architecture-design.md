# Cull Phase Prefetch Architecture — Design

**Date:** 2026-05-30
**Status:** Approved
**Supersedes:** `2026-05-29-cull-phase-ux-improvements-design.md` (prefetch section only — layout and remaining-count fixes in that spec still apply)

---

## Problem

The current cull phase blocks every card transition on two sequential network round trips:

1. `await submitCull(...)` — writes the decision to the database (3 DB ops)
2. `await fetchNext()` — fetches the next card and generates a signed URL

Only after both complete does `AsyncImage` begin downloading the image. Total visible lag per swipe is 600–1500ms depending on network conditions.

---

## Performance Targets

| Metric | Target |
|---|---|
| P50 transition | < 100ms |
| P95 transition | < 250ms |
| Hard maximum | 500ms |

---

## Architecture Overview

Replace the pull-on-demand model (fetch on every swipe) with a push-ahead model (prefetch queue + local-first decisions).

```
┌─────────────────────────────────────────────────────┐
│  iOS                                                │
│                                                     │
│  CullView  ──read──▶  CullPrefetchService           │
│                            │                        │
│                       [img, img, img, img, img...]  │
│                            │ refill when ≤ 5 remain │
│                            ▼                        │
│                       POST /prefetch-cull ──────────┼──▶ Supabase
│                                                     │
│  CullView  ──write──▶ DecisionStore (disk)          │
│                            │                        │
│                       background sync ──────────────┼──▶ POST /batch-submit-cull
└─────────────────────────────────────────────────────┘
```

**Hot path on swipe (zero blocking):**
1. `decisionStore.record(...)` — in-memory append + async disk write (~0ms)
2. `prefetchService.advance()` — pop from in-memory queue (~0ms, image already decoded)
3. `Image(uiImage: card.image)` — instant render

**Background (never blocks UI):**
- `DecisionStore` → `batch-submit-cull` with retry
- Queue refill → `prefetch-cull` → concurrent image downloads → append to queue

---

## Backend Changes

### 1. New edge function: `prefetch-cull`

Returns a batch of upcoming cull cards with thumbnail URLs. Replaces the single-card `next-cull` for the cull phase UI flow. `next-cull` is unchanged — it remains available for other callers.

**Request:**
```
POST /prefetch-cull
Content-Type: application/json

{
    "session_id": "uuid",
    "count": 15,
    "exclude_ids": ["uuid", "uuid", ...],
    "thumbnail_width": 1179
}
```

`exclude_ids` contains all photo IDs the client already has locally: decided (synced + pending) + currently queued + actively downloading. The body avoids query-string length limits — a 300-photo session with all IDs excluded would exceed typical edge-layer URL caps (~8KB).

**Response:**
```json
{
    "cards": [
        {
            "photo_id": "uuid",
            "photo_url": "https://...",
            "cluster_id": "uuid",
            "cluster_size": 3
        }
    ],
    "has_more": true
}
```

`has_more` semantics:
- `true` — more eligible cards exist beyond this batch, or uploads are still in progress
- `false` — no more eligible cards exist **and** uploads are complete

`has_more` must never be `false` while uploads are still registering photos. The server gates it on `sessions.upload_complete`:

```typescript
const { data: session } = await supabase
    .from('sessions')
    .select('upload_complete')
    .eq('id', session_id)
    .single();

const hasMore = !session.upload_complete || eligibleClusters.length > count;
```

Thumbnail URL is generated using Supabase Storage image transform:
```typescript
supabase.storage
    .from('working-copies')
    .createSignedUrl(path, 3600, {
        transform: { width: thumbnailWidth, quality: 75 }
    })
```

All signed URLs in a batch are generated with `Promise.all` — never serially.

The cluster-grouping logic is shared with `next-cull`. `exclude_ids` filtering is applied before grouping to reduce the working set.

### 2. New edge function: `batch-submit-cull`

Syncs a local decision queue in one request. Same per-decision logic as `submit-cull` (cluster-wide update, `cull_decision IS NULL` guard) but batched.

**Request:**
```
POST /batch-submit-cull
Content-Type: application/json

{
    "session_id": "uuid",
    "decisions": [
        { "photo_id": "uuid", "decision": "keep" },
        { "photo_id": "uuid", "decision": "drop" }
    ]
}
```

**Response:**
```json
{
    "results": [
        { "photo_id": "uuid", "success": true },
        { "photo_id": "uuid", "success": false, "error": "Photo not found" }
    ]
}
```

Partial failures are reported per-entry. The iOS sync task retries only failed entries on the next cycle. Each decision is idempotent — applying the same decision twice is a no-op because the guard `WHERE cull_decision IS NULL` prevents double-writes.

### 3. Migration: `upload_complete` column

```sql
ALTER TABLE sessions
    ADD COLUMN upload_complete boolean NOT NULL DEFAULT false;
```

Set to `true` by the iOS upload service when all photos have been successfully registered. Gating `has_more: false` on this field prevents premature session exhaustion while uploads are still in flight.

---

## iOS: `DecisionStore`

The authoritative source of local session state. Owns disk persistence and the pending sync queue.

### Data model

```swift
enum CullDecision: String, Codable {
    case keep
    case drop
}

struct StoredDecision: Codable {
    let photoId: UUID
    let decision: CullDecision
    let timestamp: Date
    var synced: Bool
}

struct SessionDecisionFile: Codable {
    let sessionId: UUID
    var decisions: [StoredDecision]
}
```

Disk location: `Library/Application Support/cull_<sessionId>.json`

Using a typed `CullDecision` enum ensures non-conforming values fail at decode time rather than reaching the server as a 400.

### Public interface

```swift
@Observable @MainActor class DecisionStore {
    private(set) var decisions: [StoredDecision] = []

    func load(sessionId: UUID) async -> [UUID]   // returns allDecidedIds
    func record(photoId: UUID, decision: CullDecision)
    func markSynced(photoIds: [UUID])

    var allDecidedIds: [UUID]          { decisions.map(\.photoId) }
    var pendingDecisions: [StoredDecision] { decisions.filter { !$0.synced } }
}
```

### Persistence design

`record()` performs two operations without blocking the caller:

1. **Synchronous in-memory append** on `@MainActor` — instant, no I/O. The UI advances off this.
2. **Async snapshot** handed to a background `DecisionPersistence` actor via `AsyncStream`.

```swift
// Stream with newest-value buffering — rapid swipes coalesce into one write
private let (stream, continuation) = AsyncStream.makeStream(
    of: [StoredDecision].self,
    bufferingPolicy: .bufferingNewest(1)
)

func record(photoId: UUID, decision: CullDecision) {
    decisions.append(StoredDecision(photoId: photoId, decision: decision,
                                    timestamp: .now, synced: false))
    continuation.yield(decisions)   // synchronous enqueue — no I/O on main actor
}

deinit { continuation.finish() }
```

The `DecisionPersistence` actor consumes the stream serially. Its isolation guarantees writes never interleave:

```swift
actor DecisionPersistence {
    func run(stream: AsyncStream<[StoredDecision]>, sessionId: UUID) async {
        for await snapshot in stream {
            save(snapshot, sessionId: sessionId)
        }
    }

    private func save(_ decisions: [StoredDecision], sessionId: UUID) {
        // encode → write to .tmp → FileManager.replaceItem (atomic rename)
        // No fsync — practically durable for app crashes; hard power-off risk
        // is acceptable given the workload
    }
}
```

**Durability properties:**
- The actor is serial — writes are ordered, no partial state
- Atomic rename: a crash mid-write leaves the previous complete file intact
- On load, a JSON parse failure (corrupt file) is treated as empty — never a crash
- `allDecidedIds` covers synced + pending — server cannot resurface a decided card regardless of sync state

### Recovery on load

`load(sessionId:)` reads the file synchronously on the background actor, reconstructs `decisions[]`, and returns `allDecidedIds`. This must complete before prefetching begins.

---

## iOS: `CullPrefetchService`

Manages the in-memory card queue and image prefetch pipeline. Does not touch disk or decisions.

### State machine

```swift
enum CullQueueState: Equatable {
    case loading        // fetching or internally retrying — show spinner
    case ready          // queue has cards — show card
    case exhausted      // server has_more=false + queue drained — call onComplete()
    case error(String)  // unrecoverable after retries, queue empty — show retry banner
}
```

Retry behavior for transient empty responses (`has_more: true, cards: []`) is internal to `.loading`. The view never observes a distinct "retrying" state.

### Queue configuration

| Constant | Value | Purpose |
|---|---|---|
| `batchSize` | 15 | Cards requested per prefetch call |
| `normalQueueSize` | 20 | Target cap under normal memory conditions |
| `minQueueSize` | 5 | Floor cap under memory pressure |
| `refillThreshold` | 5 | Trigger refill when queue drops to this |
| `maxConcurrentDownloads` | 4 | Bounded download pipeline concurrency |

`currentMaxQueueSize` starts at `normalQueueSize` and adapts at runtime — see Memory Pressure below.

### Implementation

```swift
@Observable @MainActor class CullPrefetchService {

    struct PrefetchedCard: Sendable {
        let photoId: UUID
        let clusterSize: Int?
        let image: UIImage      // always preloaded — never lazy
    }

    private static let normalQueueSize = 20
    private static let minQueueSize    = 5

    private(set) var queue: [PrefetchedCard] = []
    private(set) var state: CullQueueState = .loading
    private var isFetching = false
    private var inFlightIds: Set<UUID> = []   // IDs mid-download, excluded from requests
    private var serverExhausted = false
    private var currentMaxQueueSize = Self.normalQueueSize   // adaptive — reduced on memory warning

    private let api: APIClient
    private let decisionStore: DecisionStore
    private let sessionId: UUID

    func start(excluding decidedIds: [UUID]) async {
        // decidedIds passed directly — decisionStore.load() must have completed before this
        await refill(initialExclude: decidedIds)
    }

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

            if !response.hasMore {
                serverExhausted = true
            }

            batchIds = response.cards.map(\.photoId)
            inFlightIds.formUnion(batchIds)

            // Bounded pipeline: seed N slots, replace each as it finishes
            var prefetched: [PrefetchedCard] = []
            var it = response.cards.makeIterator()

            await withTaskGroup(of: PrefetchedCard?.self) { group in
                for _ in 0..<min(maxConcurrentDownloads, response.cards.count) {
                    if let card = it.next() {
                        group.addTask { await Self.download(card) }
                    }
                }
                for await result in group {
                    if let card = result { prefetched.append(card) }
                    if let next = it.next() {
                        group.addTask { await Self.download(next) }
                    }
                }
            }

            inFlightIds.subtract(batchIds)

            queue.append(contentsOf: prefetched)
            if queue.count > currentMaxQueueSize {
                queue.removeFirst(queue.count - currentMaxQueueSize)
            }
            // Gradual recovery toward normalQueueSize after a clean cycle
            currentMaxQueueSize = min(currentMaxQueueSize + 5, normalQueueSize)

            if serverExhausted && queue.isEmpty {
                state = .exhausted
            } else if !queue.isEmpty {
                state = .ready
            }
            // If serverExhausted but queue still has cards, state stays .ready
            // until advance() drains the last card

        } catch {
            inFlightIds.subtract(batchIds)
            if queue.isEmpty {
                state = .error("Couldn't load photos — tap to retry")
            }
            // If queue has cards, failure is invisible — state remains .ready
        }

        isFetching = false
    }

    // nonisolated — runs off main actor; UIImage(data:) is thread-safe post-iOS 13
    private nonisolated static func download(_ card: CullCard) async -> PrefetchedCard? {
        guard let url = URL(string: card.photoUrl),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data)
        else { return nil }
        return PrefetchedCard(photoId: card.photoId, clusterSize: card.clusterSize, image: image)
    }
}
```

### Memory pressure

`CullPrefetchService` observes `UIApplication.didReceiveMemoryWarningNotification`. On receipt, it immediately drops `currentMaxQueueSize` to `minQueueSize` and evicts the tail of the queue (cards furthest from being seen next):

```swift
@MainActor
private func handleMemoryWarning() {
    currentMaxQueueSize = minQueueSize
    if queue.count > currentMaxQueueSize {
        queue.removeLast(queue.count - currentMaxQueueSize)
    }
}
```

Evicting from the tail preserves the cards most likely to be needed next. In-flight downloads are not cancelled — they complete and are appended, but the overflow eviction at the end of `refill()` discards the excess, so peak memory stays bounded.

Recovery is gradual. At the end of each successful `refill()` cycle that does not receive a memory warning, `currentMaxQueueSize` increments by 5 toward `normalQueueSize`:

```swift
currentMaxQueueSize = min(currentMaxQueueSize + 5, normalQueueSize)
```

This means a device that received one warning recovers to full queue depth over three clean refill cycles. A device under sustained pressure stays at `minQueueSize` indefinitely.

**Memory footprint:** A decoded 600px-wide image at a typical 4:3 ratio is approximately 1.9MB in RAM. At `normalQueueSize` (20 cards): ~38MB. At `minQueueSize` (5 cards): ~10MB.

**Exclusion invariants:**
- `inFlightIds` is registered before downloads begin and cleared after — no race between concurrent refill triggers
- `isFetching` guard serialises refill calls — only one batch in flight at a time
- `serverExhausted` persists across refill calls — once set, no further `prefetch-cull` calls are made

---

## iOS: Session Initialization

Dependency-barrier model. Sync has no dependency on `allDecidedIds` and starts concurrently. Prefetch depends on the exclusion set and waits for it:

```swift
func initialize(sessionId: UUID) async {
    async let syncReady = syncService.start(store: decisionStore)

    // Barrier: prefetch waits only on this
    let decidedIds = await decisionStore.load(sessionId: sessionId)
    await prefetchService.start(excluding: decidedIds)

    await syncReady
}
```

`decisionStore.load()` returns `allDecidedIds` directly — the coordinator uses that value, not a subsequent read of the store.

---

## iOS: `CullView` Changes

The view becomes a thin consumer of `CullPrefetchService`. No network calls in the view:

```swift
func commitDecision(_ decision: CullDecision, card: PrefetchedCard) {
    decisionStore.record(photoId: card.photoId, decision: decision)  // sync, instant
    currentCard = prefetchService.advance()                          // sync, instant
}
```

State-to-UI mapping:

| `CullQueueState` | UI |
|---|---|
| `.loading` | Full card-area spinner, buttons hidden |
| `.ready` | `Image(uiImage: card.image)` — never `AsyncImage` |
| `.exhausted` | Call `onComplete()` |
| `.error(message)` | Error message + retry button fill the card area slot; bottom buttons are hidden (no card to decide on) |

`AsyncImage` is prohibited in the cull hot path. All images are preloaded in RAM before being placed in the queue.

---

## Session Resume

The `DecisionStore` is authoritative for recovery. No server round trip is needed to resume.

**On return to an unfinished session:**
1. `decisionStore.load(sessionId:)` — reconstructs `decisions[]` from disk (synced + pending)
2. Background: `syncService.drainPending(from: decisionStore)` — sends unsynced decisions to `batch-submit-cull`
3. `prefetchService.start(excluding: decidedIds)` — `allDecidedIds` excludes all decisions (both synced and pending), so the server never resurfaces a reviewed card

**Reinstall / missing file:** If `Library/Application Support/cull_<sessionId>.json` does not exist, `load()` returns an empty array. The server fills the queue from its own database state. Any decisions that were already synced are not re-served (server-side `cull_decision IS NULL` filter). Decisions that were pending but not yet synced at time of uninstall are lost — acceptable for this edge case.

---

## Background Sync

`SyncService` drains `decisionStore.pendingDecisions` to `batch-submit-cull`:

- Sends full pending batch in one request
- On partial failure: calls `decisionStore.markSynced(photoIds:)` for successful entries only; failed entries remain pending and are retried next cycle
- Retry cadence: exponential backoff (1s, 2s, 4s)
- Retry trigger: backoff timer, app foreground event, `NWPathMonitor` connectivity-restored signal
- Idempotent: the server's `cull_decision IS NULL` guard makes duplicate submissions safe
- Ordering is irrelevant: decisions target distinct photo clusters

---

## Error Handling

| Failure | Behaviour |
|---|---|
| `prefetch-cull` transient empty (`has_more: true`) | Internal retry loop (up to 3×, 2s backoff). State stays `.loading`. Invisible to user. |
| `prefetch-cull` hard failure, queue has cards | Failure is silent. State stays `.ready`. Next refill retries when queue drops to threshold. |
| `prefetch-cull` hard failure, queue empty | State → `.error`. Non-modal banner: "Couldn't load photos — tap to retry". Manual retry re-enters `refill()`. |
| Image download failure (individual) | `download()` returns `nil`. Card silently skipped. Batch continues. |
| `batch-submit-cull` failure | Decisions remain in `pendingDecisions` on disk. Retried with backoff. UI is never blocked. |
| JSON parse failure on `DecisionStore` load | Treated as empty session — no crash. Server state fills the queue. |

---

## State Transitions

```
initialize()                              → .loading
first batch arrives, images ready         → .ready
queue.count ≤ 5, refill triggered         → .ready (queue still has cards, refill silent)
queue empty, has_more=true, retrying      → .loading (internal)
queue empty, refill succeeds              → .ready
server returns has_more=false             → serverExhausted=true
last card advance(), queue now empty      → .exhausted
fetch fails, queue empty, retries done    → .error
fetch fails, queue has cards              → .ready (invisible)
```

---

## Files to Create / Modify

| File | Action |
|---|---|
| `backend/supabase/functions/prefetch-cull/index.ts` | Create |
| `backend/supabase/functions/batch-submit-cull/index.ts` | Create |
| `backend/supabase/migrations/20260530_upload_complete.sql` | Create |
| `ios/Sources/App/Services/DecisionStore.swift` | Create |
| `ios/Sources/App/Services/CullPrefetchService.swift` | Create |
| `ios/Sources/App/Services/SyncService.swift` | Create |
| `ios/Sources/App/Services/APIClient.swift` | Add `prefetchCull()`, `batchSubmitCull()` |
| `ios/Sources/App/Views/CullView.swift` | Refactor to consume `CullPrefetchService` |

`next-cull` and `submit-cull` are unchanged.

---

## Out of Scope

- Multi-device session sync (local state is authoritative for the current device only)
- Offline-capable cull (network required for initial prefetch; subsequent cards work from queue)
- AI aesthetic scoring (PRD explicitly excluded)
- Ranking phase — separate spec required for that transition latency improvement
