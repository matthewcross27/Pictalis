# Pictalis iOS — Code Quality / Correctness Re-Audit

**Scope:** code quality and correctness only (App Store Connect metadata/compliance and backend/infra are separate lanes). Reviewed `origin/main` at commit `82997e4` ("iOS Observation framework migration + code review docs (#14)").

## 0. Branch note — read this first

The brief said to check out `origin/wip/observable-migration-and-review-docs`. That branch no longer exists as a remote ref — it was already squash-merged into `origin/main` as PR #14 (commit `82997e4`, merged 2026-07-29) and the remote branch was deleted after merge. **`origin/main` already contains everything the brief described**: the Observable migration, the review docs, and the "resolve build break and Swift 6 concurrency errors" fix (folded into the same squashed commit — GitHub PR squash merges discard the branch's internal commit history, so I could not bisect individual fixing commits for each finding below; where I say "fixed" it means "confirmed fixed in the current `82997e4` tree," not "fixed in a specific later commit"). I reviewed `origin/main` directly rather than a stale default branch.

## 1. Build & test — current state

```
cd ios && xcodegen generate
xcodebuild -resolvePackageDependencies -project Pictalis.xcodeproj   # all 8 SPM deps resolved from cache
xcodebuild -project Pictalis.xcodeproj -scheme Pictalis \
  -destination 'generic/platform=iOS Simulator' build
```
**BUILD SUCCEEDED.** Zero errors. 9 distinct warnings (list in §4).

One setup step was required and is expected, not a bug: `ios/Sources/App/SupabaseConfig.swift` is gitignored (root `.gitignore:54`) and not present in a fresh checkout — only the placeholder `SupabaseConfig.swift.example` is committed. I copied the example to get a compiling build (`cp SupabaseConfig.swift.example SupabaseConfig.swift`), then re-ran `xcodegen generate` so the new file entered the project. This is the correct, documented pattern (the CI workflow does the same per the `fca4989` commit message: *"SupabaseConfig stubbed from the committed example"*) — see §2 finding #1.

Tests:
```
xcodebuild -project Pictalis.xcodeproj -scheme Pictalis \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```
Ran **5 times** back-to-back (1 full + 4 more in a loop). **28/28 tests passed every time, 0 failures.** This includes both `SyncServiceFlushTests` cases (`testCoalescedDrainMissesDecisionRecordedInFlight`, `testFlushDeliversDecisionRecordedInFlight`) — the class named `SyncServiceFlushTests` in `needs-review.md` lives in `Tests/SyncPartitionTests.swift`, not a separate file.

**Flaky-test risk (needs-review.md follow-up #8): still structurally open, not fixed.** I read `Sources/App/Services/SyncService.swift:84` — `startObservers()` still constructs a real `NWPathMonitor()` with no injectable seam, exactly as needs-review.md describes. `PhotoPipeline.swift:83` does the same for its own connectivity retry, though `PhotoPipeline`'s initializer *does* accept an optional `connectivityEvents: AsyncStream<Void>?` for injection (tests use this — see `PhotoPipelineTests.testConnectivityEventRetriesParked`); `SyncService` has no equivalent seam at all. 5/5 clean runs today is consistent with needs-review's own characterization ("failed once... passed 3/3 in isolation") — rare, not fixed. Recommend adding the same `connectivityEvents`-style injection point to `SyncService` before this file changes again.

## 2. Status of the 31 MASTER-REVIEW.md findings

Excluded per `needs-review.md` and re-verified accurate on today's tree (not re-flagged): **#5** (ImageCompressor double-resume — confirmed `.highQualityFormat` is used, delivers exactly one callback), **#17** (LocalCardProvider `@Observable` — confirmed `@Observable @MainActor` at `LocalCardProvider.swift:12`), **#21** (PhotoUploadTransport `"409"` string compare — confirmed `StorageError.statusCode` is `String?` in the Supabase SDK, comparison is correct), **#31** (DecisionStore write task no handle — confirmed `deinit` still calls `continuation.finish()`, terminating the stream/task by design).

### Priority 1 — Crash / Security / Data Loss — **all resolved**

| # | File | Status | Evidence |
|---|------|--------|----------|
| 1 | SupabaseConfig.swift | **FIXED** | `git log --all` shows the real (non-`.example`) file was never committed to this repo's history under any ref. Root `.gitignore:54` excludes `ios/Sources/App/SupabaseConfig.swift`; only the placeholder `.example` (with `YOUR_ANON_KEY_HERE`) is tracked. No real key in source. |
| 2 | APIClient.swift | **FIXED** | Grepped the file for force-unwraps: none remain. `buildRequest(path:queryItems:)` (line 38) uses `guard let url = comps.url else { throw URLError(.badURL) }`. |
| 3 | DecisionStore.swift | **FIXED** | `fileURL(sessionId:)` (line 59): `guard let support = fileManager.urls(...).first else { throw PersistenceError.noAppSupportDirectory }`. |
| 4 | PhotoPipeline.swift | **FIXED** | `prepareSessionDirectory()` (line 197) now does `try? FileManager.default.removeItem(at: sessionDirectory)` where `sessionDirectory` is `.../PictalisUploads/<sessionId>` — only the session's own subdirectory, not the shared `PictalisUploads` parent. Comment confirms intent: "clear this session only". |

### Priority 2 — Correctness / Wrong Behavior — **3 of 5 resolved, 2 partially open**

| # | File | Status | Evidence |
|---|------|--------|----------|
| 6 | ContentView.swift | **FIXED** (needs-review had downgraded this to P6; it's now fully done, not just downgraded) | `AppState: Equatable` (line 12) is implemented; `.animation(.screenTransition, value: appState)` (line 96) passes the state directly — the IIFE workaround needs-review described is gone entirely. |
| 7 | CullChoiceView.swift | **FIXED** (also downgraded-then-resolved) | `beginCull()` (lines 91-102) sets `isStarting = false` before calling `onFilterThenRank()` on the success path. |
| 8 | SyncService.swift / PhotoPipeline.swift | **PARTIALLY FIXED** | `PhotoPipeline.withRetries` (line 317-332) now uses `try await Task.sleep(...)` and explicitly rethrows `CancellationError` — fully fixed. **`SyncService.performDrain()` line 147 still does `try? await Task.sleep(for: backoff[attempt])`** — cancellation is still swallowed here. Still open for this one file/site. |
| 9 | DecisionStore.swift | **FIXED** | `DecisionPersistence.load()` (lines 65-81) now does explicit `do/catch` with `print("[DecisionStore] Failed to decode session ...")` on decode failure and a separate log on file-URL resolution failure — no more silent double-`try?`. |
| 10 | All views (13 sites) | **PARTIALLY FIXED — 11/13 done** | Grepped all `accessibilityHint` call sites. 11 no longer have the "Double-tap to " prefix. **2 remain**: `SessionSetupView.swift:73` and `SessionSetupView.swift:99` still read "Double-tap to open your photo library…" / "Double-tap to begin curating…". Trivial one-line fix, same as the other 11. |

### Priority 3 — Deprecated APIs / Multi-Window Safety — **all resolved**

| # | File | Status | Evidence |
|---|------|--------|----------|
| 11 | CullView.swift, CullChoiceView.swift | **FIXED** | All corner-radius call sites now use `.clipShape(RoundedRectangle(cornerRadius: ...))`. No `.cornerRadius(_:)` left in `Sources/App`. |
| 12 | CullView.swift | **FIXED** | `body` wraps in `GeometryReader { geo in ... }` (line 24); `screenWidth` tracked via `.onChange(of: geo.size.width)` / `.onAppear`, matching the migration commit's stated intent. No `UIScreen.main` in the file. |
| 13 | DesignSystem.swift | **FIXED** | All 6 `Font.custom` definitions (lines 27-32) now pass `relativeTo:` (`.largeTitle`, `.headline`, `.body` x2, `.subheadline`, `.caption`). |

### Priority 4 — Observation Model Migration — **all resolved**

| # | File | Status | Evidence |
|---|------|--------|----------|
| 14 | AuthService.swift | **FIXED** | `@Observable @MainActor final class AuthService` — no `ObservableObject`/`@Published`/Combine. |
| 15 | PhotoPipeline.swift | **FIXED** (Observable) / **see P7 #29 for the task-handle nuance** | `@Observable @MainActor` confirmed. `start()`'s two tasks are now stored in `backgroundTasks: [Task<Void, Never>]` and cancelled from both `cancel()` and `deinit` — the specific "two fire-and-forget Task{} in start()" this finding named is fixed. (Other, different fire-and-forget tasks elsewhere in the same file are tracked separately under #29, which is still open — see below.) |
| 16 | APIClient.swift | **FIXED** | `@Observable @MainActor final class APIClient` — no `ObservableObject`. |

### Priority 5 — Type Safety Improvements — **2 of 4 resolved, 2 open**

| # | File | Status | Evidence |
|---|------|--------|----------|
| 18 | Models.swift | **STILL OPEN** | `APISession.createdAt`/`expiresAt` (line 11-12) and `RegisteredPhoto.createdAt` (line 37) are still `String`, not `Date`. |
| 19 | Models.swift | **STILL OPEN** | `PairPhoto.signedUrl` (line 71), `RankedPhoto.signedUrl` (line 124), `CullCard.photoUrl` (line 165) are still `String`, not `URL`. |
| 20 | DesignSystem.swift | **FIXED** | `StageBadge.stage` is now typed `RankingStage` (line 118), a proper `enum RankingStage: String` (line 103) with a `.label` computed property. Call sites (`ComparisonView.swift:116`, `ResultsView.swift:68`) parse the server string via `RankingStage(rawValue:)` and only render the badge when the optional unwraps successfully — no force-unwrap risk introduced. |
| 22 | Models.swift | **FIXED** | `PairPhoto` (line 65) and `RankedPhoto` (line 116) both now declare `Equatable`. |

### Priority 6 — Code Duplication & Cleanup — **2 of 5 resolved, 2 open, 1 partially open** (plus the two P2-downgraded items, both resolved — counted above under #6/#7)

| # | File | Status | Evidence |
|---|------|--------|----------|
| 23 | ResultsView.swift, CompletionView.swift | **STILL OPEN** | `ResultsView.exportPhoto`/`exportAll` (lines 168-197) and `CompletionView.exportAll` (lines 134-155) still independently implement the identical fetch-URL → `UIImage(data:)` → `PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.creationRequestForAsset(from:) }` sequence. Not extracted. |
| 24 | PictalisApp.swift | **STILL OPEN** | `configureNavigationBar()` (lines 39-63) still hand-writes `UIColor(red:green:blue:alpha:)` literals with comments pointing at the `DesignSystem` tokens they're supposed to match, instead of bridging to them. |
| 25 | CullView.swift, ResultsView.swift | **PARTIALLY FIXED — 1 of 3 sites remain** | CullView's `Group {}` wrappers are gone (the file was rewritten for the `GeometryReader` fix, #12). `ResultsView.swift:29` still has a bare `Group { if isLoading {...} else if ... }` inside a `ZStack` with no modifiers attached to the `Group` itself — still removable. |
| 26 | ComparisonView.swift | **FIXED** | Line 97 now uses `Color.photoBackground` (a `DesignSystem.swift:14` token, defined with the exact same RGB the finding flagged) instead of an inline `Color(red:green:blue:)` literal. |
| 27 | ComparisonView.swift | **FIXED** | Line 170: `photo.id == pair?.photoA.id ? "First photo" : "Second photo"` — no more "Left"/"Right". |

### Priority 7 — Structured Concurrency Hygiene — **2 of 4 resolved, 1 partially open, 1 accepted pattern (unchanged)**

| # | File | Status | Evidence |
|---|------|--------|----------|
| 28 | SyncService.swift, LocalCardProvider.swift | **FIXED** | `SyncService.deinit` (line 107-111) now calls `streamContinuation?.finish()` and `monitor?.cancel()` in addition to cancelling `observerTasks`. `LocalCardProvider` no longer has an `AsyncStream`/continuation at all in this area — it uses a plain cancellable `fillTask: Task<Void, Never>?`, cancelled in `deinit` (line 44-49). |
| 29 | PhotoPipeline.swift, SyncService.swift, LocalCardProvider.swift | **PARTIALLY FIXED** | `PhotoPipeline.start()`'s two tasks and `SyncService`'s two observer tasks are now stored and cancelled (see #15, #28). `LocalCardProvider.fillTask` is stored and cancelled. **Still fire-and-forget, no stored handle, can't be force-cancelled on "start over":** `PhotoPipeline.pumpUploads()` line 267 (`Task { await self.uploadAndMarkUploaded(id) }`), `PhotoPipeline.checkCompletion()` line 355 (`Task { try? await self.transport.markUploadComplete(...) }`), `SyncService.syncIfNeeded()` line 59 (`Task { await self.drain() }`). These are self-limiting via internal state machines (not literally dangerous), but they don't get cut off if a user backs out mid-upload — low severity, but the finding isn't fully closed. |
| 30 | CachedPhotoImage.swift | **FIXED** | `load()` line 50: `guard !Task.isCancelled else { return }` now guards both the memory-cache write and the `phase = .success(...)` assignment. |

## 3. Tally

Of the 31 original findings: **4 excluded** (false positives / accepted patterns, all re-verified still accurate — no re-flag). Of the remaining 27 actionable findings: **19 fully fixed, 4 partially fixed, 4 still fully open.**

| Priority | Fixed | Partial | Open | Excluded |
|---|---|---|---|---|
| P1 — Crash/Security/Data Loss | 4 | 0 | 0 | 1 |
| P2 — Correctness | 3 | 2 (#8, #10) | 0 | 0 |
| P3 — Deprecated APIs | 3 | 0 | 0 | 0 |
| P4 — Observation Migration | 3 | 0 | 0 | 1 |
| P5 — Type Safety | 2 | 0 | 2 (#18, #19) | 1 |
| P6 — Duplication/Cleanup | 4* | 1 (#25) | 2 (#23, #24) | 0 |
| P7 — Concurrency Hygiene | 2 | 1 (#29) | 0 | 1 |

*P6 count of 4 includes the two items (#6, #7) needs-review had downgraded here from P2, both now fully fixed.

**Bottom line: zero P1 issues remain.** All crash/security/data-loss findings from the original review are either fixed or were false positives that hold up on re-verification. The app is materially further along than the 2026-06-28 snapshot suggested — most of that gap is explained by the Observable migration and the squashed PR having landed a lot of unrelated fixes in the same commit. Nothing left open is a crash risk; the remainder is type-safety polish, duplicated export code, and concurrency-hygiene completeness.

## 4. New findings since 2026-06-28 (not in MASTER-REVIEW.md)

The Observable migration and current Xcode toolchain (Xcode 26.6, Swift 6-capable) surfaced 9 distinct compiler warnings across 3 files, all currently non-blocking (build succeeds, tests pass) but worth listing because several are explicit forward-compatibility signals:

- **`Sources/App/Services/PhotoPipeline.swift:206`** — `group.addTask { @MainActor in await self.materialize(id) }` triggers: *"pattern that the region-based isolation checker does not understand how to check. Please file a bug; **this is an error in the Swift 6 language mode**."* The project currently builds under Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY: complete` (an upcoming-feature flag, not full Swift 6 mode — see `ios/project.yml`). This line will not compile once `SWIFT_VERSION` is bumped to 6. Worth fixing proactively since it's a known, filed-bug-class pattern (likely: restructure the `TaskGroup` closure to avoid capturing `self` across the region boundary, or hop via a `nonisolated` shim).
- **`Sources/App/Views/SessionSetupView.swift:49,51,53(x2),55,59`** — six warnings: *"main actor-isolated property 'selectionCount' can not be referenced from a nonisolated context."* `selectionCount` is a plain computed property on the view struct, read inside the `PhotosPicker(...) { ... }` label closure. This looks like an isolation-inference gap around the `PhotosUI`/`SwiftUI` cross-import overlay (visible in the raw build log as multiple `-swift-module-cross-import PhotosUI ... SwiftUI.swiftoverlay` entries) rather than a real bug in this code — but like the item above, it's a Swift-6-readiness gap, not just cosmetic.
- **`Sources/App/Services/LocalCardProvider.swift:31,32`** and **`Sources/App/Services/PhotoPipeline.swift:54`** — three warnings: *"`nonisolated(unsafe)` has no effect on property '...', consider using `nonisolated`."* These are exactly the properties needs-review.md's "Acceptable Patterns" item #6 blessed (`memoryWarningObserver`, plus the newly-added `fillTask`/`backgroundTasks` handles from the #15/#29 fixes above) — the compiler is now telling us the annotation itself is stale under the current toolchain and should be `nonisolated` (no `(unsafe)`). The *pattern* (deinit needs synchronous access to actor-isolated state) is still valid per needs-review's reasoning; only the exact spelling needs updating. Low severity, trivial fix, but should be swept in one pass since it's now 3 sites instead of 1.
- **`Sources/App/Views/SessionSetupView.swift:77`** — `Text("Sign-in error: \(err)")` where `err: any Error`: *"`appendInterpolation` is deprecated: Localized string interpolation produces an unlocalized, debug description for this type of value."* Cosmetic/i18n, but worth a one-line fix (`err.localizedDescription`) since it's flagged by name.
- **Minor naming leftover:** `Tests/picHelperTests.swift` still carries the pre-rename app name — `PictalisApp.swift` was renamed from `picHelperApp.swift` back in commit `16b02f0` (2026-06-09), but the test file was never renamed to match. Purely cosmetic, zero functional impact, but odd enough to be worth a rename in the same pass as other cleanup.

No new correctness bugs (nothing crash-risk, nothing silently-wrong) were found in the Observable-migration diff itself beyond the compiler warnings above — the migration looks careful (task handles were added, not removed; `AsyncStream` continuations gained proper `deinit` cleanup; `Equatable` conformances were added alongside it). I did not find evidence the migration introduced any of the still-open findings in §2 — all of those (§2's P5/P6 opens, #8's SyncService half, #29's remaining fire-and-forget tasks) look like pre-existing gaps the migration simply didn't happen to touch, not regressions caused by it.

## 5. Unreconciled branch (flagged only, not reviewed — out of scope per task brief)

`origin/gnhf/find-ways-to-improve-a39ef0` exists as a remote branch: 56 commits of automated refactoring/cleanup (commit messages read like an automated audit tool — "gnhf 1" through "gnhf N" style), based on `d6a5a90` (the App Store readiness commit), which is **two commits behind** the current `origin/main` HEAD (`82997e4`). That means this branch predates the entire Observable migration and review-docs commit — it branched off before `@Observable`/`@Environment` existed anywhere in the iOS code. Some of its commits touch the same files this report just reviewed (e.g., I saw `APIClient.swift` refactoring commits — extracting `postSessionId`/`getSessionId` helpers, a `UUID.lowercased` extension replacing 21 call sites, dead-code removal for the old server-driven cull path) that will conflict, in spirit if not in literal diff lines, with the Observable-migration version of the same files. This branch is completely unreconciled with `main` and will need a real merge/rebase pass — likely non-trivial given the divergence point — before it can ship. Not reviewed further per task scope.

## 6. Recommendation — priority-ranked punch list before submission

**Nothing here is a P1 (crash/security/data-loss) blocker — that bucket is clean.** Ranked by what I'd fix before shipping:

1. **`SyncService.swift:147`** — change `try? await Task.sleep(...)` to `try await Task.sleep(...)` in `performDrain()`'s retry loop, matching the fix already applied to `PhotoPipeline.withRetries`. One line, closes the rest of #8.
2. **`SessionSetupView.swift:73,99`** — drop the "Double-tap to " prefix from the last 2 of 13 `accessibilityHint` strings. One line each, closes #10.
3. **`Sources/App/Services/PhotoPipeline.swift:206`** — restructure the `TaskGroup` closure to avoid the region-isolation-checker gap the compiler explicitly flags as a future hard error. Not urgent for today's build, but blocks any future Swift 6 language-mode bump, and the compiler itself is asking for it ("Please file a bug").
4. **`Models.swift`** — decode `createdAt`/`expiresAt` as `Date` (#18) and `signedUrl`/`photoUrl` as `URL` (#19) instead of `String`. Type-safety debt, not a crash risk today, but every consumer currently re-parses these ad hoc.
5. **Extract `PhotoExporter`** — de-duplicate the identical `PHPhotoLibrary` export logic in `ResultsView.swift` and `CompletionView.swift` (#23).
6. **`PictalisApp.swift:configureNavigationBar()`** — bridge to `DesignSystem` color/font tokens instead of re-deriving raw RGB/font-name literals (#24) — prevents these two color systems drifting apart silently.
7. **Cosmetic sweep** (batch together, low individual value): remove `ResultsView.swift:29`'s unnecessary `Group {}` (#25); fix the 4 stale `nonisolated(unsafe)` → `nonisolated` warnings (§4); fix `SessionSetupView.swift:77`'s `Text(err)` interpolation (§4); rename `Tests/picHelperTests.swift` (§4).
8. **Concurrency completeness** — store handles for the remaining fire-and-forget `Task {}` blocks in `PhotoPipeline.pumpUploads()`/`checkCompletion()` and `SyncService.syncIfNeeded()` (rest of #29) so "start over" can actually cut off in-flight work rather than letting it settle on its own.
9. **Test-seam gap** — add an injectable connectivity-signal abstraction to `SyncService` (mirroring `PhotoPipeline`'s existing `connectivityEvents: AsyncStream<Void>?` parameter) to close the flaky-test structural risk documented in needs-review.md #8. Not urgent (rare in practice, 5/5 clean today) but it's the one thing in this report that's a test-infrastructure risk rather than a straightforward one-line fix.
10. **Before actually shipping:** reconcile or explicitly shelve `origin/gnhf/find-ways-to-improve-a39ef0` (§5) — not a code-quality finding, but a real unresolved-state risk given how much it overlaps the files just reviewed here.

None of items 1-9 are large; a competent iOS engineer could clear the whole list in well under a day. Item 10 is the only one with unknown size (depends how cleanly the 56 commits rebase onto the Observable-migration code).
