# Invisible Upload Pipeline for Filter-Then-Rank — Design

**Date:** 2026-06-10
**Status:** Approved
**Relates to:** `2026-05-30-cull-phase-prefetch-architecture-design.md` (replaces its server-driven card delivery for the cull phase)

---

## Problem

In the filter-then-rank flow, every selected photo is loaded at full resolution,
compressed, uploaded to Supabase Storage, registered via `register-photo`, and
then **downloaded back** by `CullPrefetchService` just to display it on a cull
card. The user waits behind a progress bar while their own photos make a full
network round trip. Observed symptoms (2026-06-10 field report):

- Upload of a full session takes minutes; the cull cannot show cards until
  photos round-trip through the server.
- ~10% of photos fail to upload. `UploadService.uploadOne` has **zero retry**
  — any transient network or HTTP error permanently marks the photo failed
  for the session.
- Photos dropped during the cull never needed to upload at all; in a typical
  cull that is roughly half the upload volume wasted.

Secondary costs: `loadTransferable` pulls full originals (including iCloud
fetches); `register-photo` performs three server operations per photo
(storage `list()` verification, session lookup, insert).

## Goals

- The cull phase shows the first card in < 1s and never touches the network
  on its hot path.
- Uploads run invisibly in the background, self-heal from transient failures,
  and skip photos dropped in the cull.
- Ranking still starts as soon as 2 photos are registered (existing gate).
- No change to ranking semantics, decision storage, or session lifecycle.

## Decisions Made

- **Approach:** local-first cull + background keeper-priority upload
  (over "harden uploads only" and "background URLSession" variants).
- **Dropped photos are never uploaded.** Drop = cancel. Undo within the
  session works from the local copy; dropped photos never exist server-side.
  (Background URLSession continuation is a possible later phase.)

## Data Flow

Each selected photo gets a **client-generated `photoId` (UUID)** and moves
through a per-photo state machine, decoupled from the UI:

```
selected → materialized → uploaded → registered
              │  (compressed JPEG on tmp disk; cull thumbnails are
              │   decoded from it on demand, only within the card
              │   provider's decode-ahead window)
              └── drop in cull ⇒ cancelled (tmp file deleted, upload skipped)
```

- **Materialize** (bounded concurrency ~3, in selection order): a single
  `loadTransferable` + decode produces the 1920px/0.75 upload JPEG, written
  to a session tmp directory; cull display images are decoded from that file
  (far cheaper than the original). Selection order = cull display order, so
  the first card is ready almost immediately.
- **Upload** (bounded concurrency 4, priority queue): kept > undecided;
  dropped photos are removed from the queue. The storage upload and the
  `register-photo` call are retried **independently** with exponential
  backoff + jitter; exhausted retries park the item until an
  `NWPathMonitor` connectivity-restore event re-queues it (same pattern
  `SyncService` already uses for decisions).
- The storage object path embeds the client `photoId` as the filename:
  `{userId}/{sessionId}/{photoId}.jpg`.

## iOS Changes

### `UploadService` → `PhotoPipeline`

Owns the state machine above. Public surface:

- `start(items:sessionId:userId:)` — assigns photoIds, begins materialization.
- `thumbnail(for: photoId)` / async card provider for the cull UI.
- `setDecision(photoId:decision:)` — keep ⇒ promote priority; drop ⇒ cancel
  upload and delete the tmp file (no-op if already registered).
- Published state: `registeredCount`, `permanentlyFailed: [UUID]`,
  `isComplete` (all non-dropped photos registered or permanently failed).
- Calls `markUploadComplete` when all **non-dropped** photos are resolved.

### `CullPrefetchService` → `LocalCardProvider`

Same `PrefetchedCard` interface `CullView` consumes, but cards come from
local thumbnails via `PhotoPipeline` — no `prefetch-cull` call, no image
download. Keeps a decode-ahead window (~10 cards) and the existing
memory-warning shrink behavior. `state` transitions (`loading`/`ready`/
`exhausted`) are preserved so `CullView` changes stay minimal; the
`error` state only occurs if a local asset fails to load.

### Decision sync (`DecisionStore` / `SyncService`)

Storage format unchanged. `drain()` filters pending decisions to photos that
are **registered**; decisions for unregistered photos stay pending until
registration. A *drop* for a never-registered (cancelled) photo is marked
synced locally — there is nothing to tell the server. (Server semantics
confirmed: `cull_decision IS NULL` photos rank normally; only synced drops
set `is_suppressed`.)

### UI

- `CullChoiceView`: upload progress banner removed; "Filter then rank" is
  available immediately.
- `CullView`: upload banner and failed-count line removed; the top bar keeps
  the remaining-count and Done button.
- `ComparisonView`: keeps the existing "waiting for first pair" state (brief,
  since keepers are prioritized). The red failure banner is replaced by one
  quiet line — "N photos couldn't be included" — tappable to retry the
  permanently-failed set.

## Backend Changes

- **`register-photo`**: accepts optional `photo_id` (UUID). Inserts with the
  explicit id; on unique violation returns the existing row with 200
  (idempotent — safe under client retry). The storage existence check stays.
  No migration: `photos.id` is already a client-suppliable PK with a
  server-side default.
- **`batch-submit-cull`**: unchanged (already idempotent via
  `cull_decision IS NULL` guard).
- **`prefetch-cull`**: no longer called by the cull UI. Left deployed;
  flagged for removal in a later cleanup.

## Failure Handling

- Transient upload/register failures retry with backoff and on connectivity
  restore — invisible to the user.
- A *kept* photo that permanently fails does not affect the cull (local) and
  surfaces only as the quiet line in `ComparisonView`, with tap-to-retry.
- A local asset that fails to materialize (corrupt data, iCloud fetch error)
  is retried once, then excluded with the same quiet-line treatment.
- Tmp files are deleted on drop/cancel and the session tmp directory is
  cleared when the session completes or a new session starts.

## Performance Expectations

| Metric | Before | After |
|---|---|---|
| First cull card | full upload round trip (tens of seconds–minutes) | < 1s (local decode) |
| Cull hot path network | download per card | none |
| Upload volume | 100% of selection | keepers only (typically ~50–70%) |
| Transient-failure photo loss | ~10% permanent | self-healing retries |

## Testing

- Swift unit tests for the `PhotoPipeline` state machine with a mocked
  transport: priority ordering (keep > undecided), cancel-on-drop deletes
  tmp file and skips upload, per-step retry/backoff, idempotent re-register,
  completion signal counts non-dropped photos only.
- Backend test for `register-photo`: explicit `photo_id` honored; duplicate
  registration returns the existing row.
- Existing cull, sync, and ranking-engine tests unchanged.

## Out of Scope

- Background `URLSession` (uploads continuing while app is backgrounded).
- Cross-device session resume (the app has no resume flow today;
  `PhotosPickerItem`s are not persistable across launches).
- Removing the `prefetch-cull` edge function.
