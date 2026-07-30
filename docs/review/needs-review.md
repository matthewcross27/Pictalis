# Pictalis iOS — Needs Human Review

> Generated 2026-06-28. Items here were in the MASTER-REVIEW.md but are either false positives,
> already addressed, or have context that makes the original finding questionable.

---

## False Positives (do NOT implement)

### 1. ImageCompressor — double-resume on continuation (was Priority 1 #5)

**Claim:** `PHImageManager` delivers a degraded preview callback before the full-resolution result,
causing `withCheckedThrowingContinuation` to double-resume (undefined behavior).

**Reality:** The code sets `options.deliveryMode = .highQualityFormat`. Per Apple docs, this mode
delivers **exactly one** callback — the highest-quality image available. The degraded-preview issue
only occurs with `.opportunistic` mode. There is no double-resume risk here.

**Verdict:** Remove from issue list. No fix needed.

---

### 2. PhotoUploadTransport — "409" string comparison (was Priority 5 #21)

**Claim:** Idempotency check uses string comparison `"409"` — should compare `Int` status code.

**Reality:** The Supabase Swift SDK exposes `StorageError.statusCode` as a `String?`, not an `Int`.
The comparison `storageError.statusCode == "409"` is the correct and idiomatic approach for this SDK.
The review assumed the type was `Int`, which it is not.

**Verdict:** Remove from issue list. No fix needed.

---

### 3. LocalCardProvider — @Observable migration (was Priority 4 #17)

**Claim:** Needs migration to `@Observable`.

**Reality:** `LocalCardProvider` is already annotated `@Observable @MainActor` (line 12). The migration
is complete.

**Verdict:** Migration finding is a false positive. Fire-and-forget tasks are a separate concern
tracked in the implementation plan under concurrency hygiene.

---

## Downgraded Findings

### 4. ContentView — animation fires on every re-render (was Priority 2 #6)

**Claim:** `.animation(value:)` fires on every re-render; passes a closure-derived `Int` instead of
state directly.

**Reality:** The value argument is an immediately-invoked closure (`{ ... }()`), returning a stable
`Int` (0–5) keyed to the current app state. SwiftUI compares this `Int` and only triggers animation
when it changes — animation does NOT fire on re-renders where `appState` is unchanged.

**However:** `AppState` lacks `Equatable` conformance, making it impossible to pass directly as the
`value:`. The IIFE workaround is functional but obscures intent.

**Downgraded to Priority 6.** Fix: add `Equatable` to `AppState`, then simplify to
`.animation(.screenTransition, value: appState)`.

---

### 5. CullChoiceView — `isStarting` never reset on success (was Priority 2 #7)

**Claim:** Buttons stay permanently disabled if the view is revisited after a successful cull start.

**Reality:** `ContentView` uses a direct state machine — each transition creates a new view instance
with fresh `@State`. There is no `NavigationStack`, so the view is never literally revisited without
recreation. The bug cannot be triggered in the current navigation model.

**Downgraded to Priority 6 (defensive).** Fix: add `isStarting = false` before calling
`onFilterThenRank()` on the success path. Trivial and worth doing for robustness.

---

## Acceptable Patterns (no fix needed)

### 6. LocalCardProvider — `nonisolated(unsafe)` on memory warning observer (was Priority 7)

`nonisolated(unsafe)` is the standard Swift workaround for accessing actor-isolated properties in
`deinit`. The property is written only in `init` and read only in `deinit` — no concurrent access.
This is acceptable until SE-0371 (isolated deinit) lands.

### 7. DecisionStore — persistence task has no stored handle (was Priority 7 #31)

The task iterates over an `AsyncStream`. When `DecisionStore` deallocates, `deinit` calls
`continuation.finish()`, which terminates the stream and the task. Cancellation is managed through the
stream lifecycle, not a handle. This is intentional and correct.

---

## Follow-ups (new)

### 8. SyncService / PhotoPipeline — real NWPathMonitor makes tests flaky

`SyncServiceFlushTests.testCoalescedDrainMissesDecisionRecordedInFlight` failed once in a full-suite
run (2026-07-29) but passed 3/3 when run in isolation. Both `SyncService` and `PhotoPipeline` start a
real `NWPathMonitor` with no test seam; a genuine OS-reported network path change during a longer test
run can fire the "re-drain on connectivity restore" observer mid-test, letting an extra decision reach
the mock API outside the test's `paused`/`isDraining` assumptions.

**Fix:** introduce an injectable connectivity-signal abstraction (protocol or closure) in both types so
tests can drive path updates deterministically instead of depending on the real network stack.

**Not caused by the `@Observable` migration** — the monitor already existed on `main`; the migration
only added `stop()`/`deinit` cancellation of the observer tasks, which can only reduce cross-test
bleed, not cause it.
