# Local-First Cull Sync — Design Spec
**Date:** 2026-06-20
**Status:** Approved

## Problem

Pictalis lets users cull photos immediately using local compressed copies while bytes upload in the background. The timing mismatch between "user makes a drop decision" and "server row exists to record it on" creates a race condition: if a photo hasn't registered with the server by the time the user taps "Done," the drop decision is discarded when `SyncService` tears down. The photo later uploads, registers with `cull_decision = NULL`, and surfaces in the ranking pool.

Multiple patches have narrowed the window (`cancelledInFlight` state, `flush()` backstop, bounded polling) but haven't eliminated the race — they've only shortened it. The root cause is structural: decisions are made against local photos before server rows exist.

## Core Invariant

> A photo row must exist in the database before the user sees the first cull card.

Separating *identity registration* (cheap, fast, batch) from *data delivery* (slow, async, per-photo) eliminates the race entirely. Once every photo has a server row, every cull decision is immediately sendable. There is no "homeless decision" case.

## Architecture

### Session Startup

Pre-registration runs in parallel with local materialization (compress to disk):

```
User selects N photos
        │
        ├─── [parallel] ──────────────────────────────────────────────┐
        │                                                              │
        ▼                                                              ▼
batch-pre-register (~100–300ms)                       PhotoPipeline.start()
Creates N rows:                                       Materializes photos
  upload_status = 'pending'                           (compress to tmp disk)
  cull_decision = NULL
  is_suppressed = false
        │                                                              │
        ▼                                                              │
   Pre-reg complete                                                    │
        │                                                              │
        └──────────────── Show first cull card ◄──────────────────────┘
                          (first materialized photo,
                           after pre-reg confirms)
```

In practice, the batch HTTP call (~100ms) completes before materialization of the first photo (~200–500ms), so there is no net latency added at session start.

### Decision Data Flow

Once pre-registration is complete, the decision path is a straight line:

```
User swipes keep/drop
        │
        ├── DecisionStore.record()      (in-memory + disk)
        ├── PhotoPipeline.setDecision() (local state)
        └── SyncService.syncIfNeeded() (fire and forget)
                │
                ▼
        All decisions immediately sendable.
        No partition into send/hold/settle-locally.
        batch-submit-cull always finds an existing row.
                │
                ▼
        UPDATE photos
          SET cull_decision = ?, is_suppressed = ?
          WHERE id = ? AND session_id = ?
          AND cull_decision IS NULL   (idempotent)
```

### Cull → Ranking Handoff

```
User taps "Done → Start comparing"
        │
        ▼
flush() — drain any unsent decisions (one network round-trip, no polling loop)
        │
        ▼
finishCull() — server marks session ranking-ready
        │
        ▼
Ranking starts with photos WHERE upload_status = 'uploaded' AND is_suppressed = false
More photos enter the pool as background uploads complete
```

## Correctness Guarantee

A photo enters the ranking pool if and only if:
1. `upload_status = 'uploaded'` — bytes are in storage, ready to display
2. `is_suppressed = false` — the user did not drop it during cull

Condition 2 is writable from the moment `batch-pre-register` returns — before the first cull card appears. There is no window where a drop decision is homeless. Condition 1 only gates display, not exclusion from ranking.

## Component Changes

### Server

#### New: `batch-pre-register` edge function

- **Input:** `{ session_id: uuid, photo_ids: uuid[] }`
- **Output:** `{ results: [{ photo_id, success }] }`
- **Behavior:**
  ```sql
  INSERT INTO photos (id, session_id, upload_status, cull_decision, is_suppressed)
  VALUES ($1, $2, 'pending', NULL, false)
  ON CONFLICT (id) DO NOTHING
  ```
  Fully idempotent — safe to retry on network failure.
- Called once per session, before showing the cull UI. Session start is blocked until this returns successfully.

#### Modified: `register-photo` → upload + mark-uploaded

Current `register-photo` both uploads bytes to storage and creates the DB row. After pre-registration, the row already exists. The endpoint splits:

- Client uploads bytes to Supabase Storage directly (unchanged mechanism)
- Client (or edge function) calls `PATCH /photos/:id` to set `upload_status = 'uploaded'` and `storage_path`

No INSERT — only UPDATE on an existing row.

#### Simplified: `batch-submit-cull`

Remove the two-step existence check. The "photo not yet registered" error path is unreachable after pre-registration:

```typescript
// Before: two queries needed to distinguish "already decided" from "row missing"
// After: zero rows updated always means "already decided" — no re-query needed
if (updated && updated.length > 0) {
  return { photo_id, success: true };
}
return { photo_id, success: true }; // already decided — idempotent
```

#### Schema migration

```sql
ALTER TABLE photos
  ADD COLUMN upload_status TEXT NOT NULL DEFAULT 'pending'
             CHECK (upload_status IN ('pending', 'uploaded'));
```

Ranking query adds: `AND upload_status = 'uploaded'`

### iOS — PhotoPipeline

#### State machine

**Before:**
```
pending → materialized → uploading → registered
                                   → cancelledInFlight → cancelled
                                                       → registered
               → parked
               → cancelled
               → failed
```

**After:**
```
pending → materialized → uploading → uploaded
               → parked
               → cancelled   (drop before bytes leave device)
               → failed      (local asset unreadable — terminal)
```

Removed states:
- **`registered`** — replaced by `uploaded`. "Registration" (row creation) is no longer a pipeline concern.
- **`cancelledInFlight`** — existed to handle "drop landed mid-upload, row may or may not exist." Since the row always exists, a drop is always sendable. Worker exits early on `cancelled`; no special in-between state needed.

`registrationState(for:)` simplifies:
- `.registered` — all states except `.failed`
- `.unavailable` — `.failed` only (local asset couldn't be read)
- `.pending` — **removed**

`onRegistered` callback — **removed**. `SyncService` no longer needs to be notified when a row appears because all rows appear before cull starts.

#### Upload worker

`uploadAndRegister()` → `uploadBytes()`:
- Upload compressed JPEG to storage (unchanged)
- If item is `cancelled` before or during upload, exit early — `is_suppressed = true` is already on the server row
- On success: call mark-uploaded endpoint to set `upload_status = 'uploaded'` on existing row
- On failure: park and retry as today

### iOS — SyncService

`partition()` simplifies from three buckets to two:
- **send** — all decisions for photos that are not `.unavailable`
- **skip** — decisions for photos whose local asset failed (`.unavailable`); mark synced locally

The `.pending` hold bucket is removed. `flush()` loses the polling loop and deadline:

```swift
func flush() async {
    await performDrain()
}
```

`flushTimeout` constant — **removed**.

### iOS — DecisionStore, LocalCardProvider

No changes. `DecisionStore` continues to persist decisions to disk and track synced state. `LocalCardProvider` continues to serve cull cards from local compressed copies.

## Error Handling

### Pre-registration failure

If `batch-pre-register` fails, the session does not start. The client retries with exponential backoff and shows a loading state. This surfaces the failure before any decisions are made — the cleanest possible recovery point. Orphaned rows from a partial batch are cleaned up by the existing 72-hour storage policy.

### Upload failure after pre-registration

A photo whose bytes never arrive stays `upload_status = 'pending'`:
- If dropped: `is_suppressed = true` — excluded from ranking by the drop filter
- If kept or undecided: excluded from ranking by the `upload_status = 'uploaded'` filter

No phantom entries. The user sees fewer photos in ranking, which is correct.

### Network down during cull

Decisions queue in `DecisionStore` as today. When connectivity restores, `SyncService` drains the queue. Because rows exist, all queued decisions are immediately sendable on reconnect — no ordering dependency on uploads.

## What Is Removed

| Current component | Reason for removal |
|---|---|
| `cancelledInFlight` pipeline state | Row always exists; drop always sendable; no race to guard |
| `SyncService.partition()` `.pending` bucket | No photo is ever awaiting row creation |
| `flush()` polling loop + 5s deadline | Nothing to wait for except the network call itself |
| `onRegistered` callback | SyncService doesn't need to know when rows appear |
| `batch-submit-cull` existence re-query | "Row missing" case is unreachable |
| `PhotoRegistrationState.pending` | All non-failed photos are immediately `.registered` |

## Out of Scope

- Ranking engine changes beyond adding `AND upload_status = 'uploaded'` to the pool query
- Duplicate suppression logic (Stage 1 — unaffected)
- Results view, comparison UI, Elo scoring
