# Pictalis iOS — Master Code Review

> Generated 2026-06-28. Consolidated from three parallel reviews of 21 Swift source files.
> Detail reports: [views-review.md](views-review.md) · [services-review.md](services-review.md) · [core-review.md](core-review.md)

---

## Executive Summary

The codebase is structurally sound with no architectural problems. Async work consistently uses `.task`, the design system is widely adopted, and image handling is well-implemented. The main risk areas are:

1. A hardcoded Supabase key in source control
2. Three crash-risk force-unwraps in the network layer
3. Undefined behavior in the image pipeline's continuation handling
4. A data-corruption bug in session directory setup

The observation model is also mid-migration — some services still use `ObservableObject`/`@Published` while the UI has moved to `@Observable`. This creates asymmetry that will need resolving before a full Swift 6 migration.

---

## Priority 1 — Crash / Security / Data Loss

These have real consequences if hit in production.

| # | File | Issue | Fix |
|---|------|-------|-----|
| 1 | `SupabaseConfig.swift` | **Real anon key hardcoded in source** — `.example` and real file are the same file | Move URL + key to `Info.plist` injected via `.xcconfig`; add real file to `.gitignore` |
| 2 | `APIClient.swift` | **Force-unwrap `!` on `URLComponents.url`** at 3 call sites — crashes if URL construction fails | Return `throw` instead; use `guard let url = components.url else { throw ... }` |
| 3 | `DecisionStore.swift` | **Force-unwrap on `FileManager.urls`** — crashes if the documents directory can't be found | `guard let url = FileManager.default.urls(...).first else { throw ... }` |
| 4 | `PhotoPipeline.swift` | **`prepareSessionDirectory()` deletes the entire uploads parent folder** — would corrupt any concurrent sessions | Delete only the specific session subdirectory, not the parent |
| 5 | `ImageCompressor.swift` | **`withCheckedThrowingContinuation` can be double-resumed** — `PHImageManager` delivers a degraded preview callback before the full-resolution result | Guard on `PHImageResultIsDegradedKey`: `if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }` |

---

## Priority 2 — Correctness / Wrong Behavior

These don't crash but produce wrong results or broken UX.

| # | File | Issue | Fix |
|---|------|-------|-----|
| 6 | `ContentView.swift` | **`.animation(value:)` fires on every re-render** — passes a closure-derived `Int` instead of the state directly | Add `Equatable` to `AppState`; change to `.animation(.default, value: appState)` |
| 7 | `CullChoiceView.swift` | **`isStarting` never reset to `false` on the success path** — buttons stay permanently disabled if the view is revisited | Add `isStarting = false` on the happy path completion |
| 8 | `SyncService.swift` / `PhotoPipeline.swift` | **`try? Task.sleep` swallows `CancellationError`** in retry loops — tasks can't be cancelled during backoff | Replace with `try await Task.sleep(...)` and let cancellation propagate |
| 9 | `DecisionStore.swift` | **Double `try?` silently returns empty state on corrupted JSON** — user loses cull progress with no warning | At minimum log the error; ideally surface it or offer to reset |
| 10 | All views (13 sites) | **`accessibilityHint` strings all begin "Double-tap to …"** — VoiceOver already announces "double tap to activate", so every hint is read twice | Remove "Double-tap to" prefix from all 13 hints |

---

## Priority 3 — Deprecated APIs / Multi-Window Safety

Deprecated APIs will produce warnings today and break in future iOS versions.

| # | File | Issue | Fix |
|---|------|-------|-----|
| 11 | `CullView.swift`, `CullChoiceView.swift` | **`.cornerRadius(_:)` deprecated in iOS 16** — 7 call sites | Replace with `.clipShape(RoundedRectangle(cornerRadius: X))` |
| 12 | `CullView.swift` | **`UIScreen.main.bounds.width` deprecated** and not safe in multi-window / Stage Manager | Replace with `GeometryReader` or `@Environment(\.horizontalSizeClass)` |
| 13 | `DesignSystem.swift` | **`Font.custom` missing `relativeTo:` parameter** on all 6 definitions — custom fonts don't scale with Dynamic Type | Add `relativeTo: .body` (or appropriate style) to each `Font.custom` call |

---

## Priority 4 — Observation Model Migration

The app is mid-migration from `ObservableObject` to `@Observable`. These services still use the old pattern.

| # | File | Issue | Fix |
|---|------|-------|-----|
| 14 | `AuthService.swift` | Uses `ObservableObject` / `@Published` / Combine; rest of app is `@Observable` | Migrate to `@Observable @MainActor` class; remove `@Published` |
| 15 | `PhotoPipeline.swift` | Uses `ObservableObject` / `@Published`; two fire-and-forget `Task {}` in `start()` with no handles | Migrate to `@Observable`; store task handles for cancellation |
| 16 | `APIClient.swift` | Declared `ObservableObject` with no `@Published` properties — pointless conformance | Remove `ObservableObject` or add `@Observable` |
| 17 | `LocalCardProvider.swift` | `nonisolated(unsafe)` on memory warning observer; fire-and-forget fill tasks | Modernize notifications to `AsyncStream`; store task handles |

---

## Priority 5 — Type Safety Improvements

Weakly typed fields that should use stronger Swift types.

| # | File | Issue | Fix |
|---|------|-------|-----|
| 18 | `Models.swift` | `createdAt`, `expiresAt` fields are `String` instead of `Date` | Use `Date` with a custom `DateDecodingStrategy` on the decoder |
| 19 | `Models.swift` | URL fields (`signedUrl`, `photoUrl`) are `String` instead of `URL` | Use `URL`; decoder validates at parse time |
| 20 | `DesignSystem.swift` | `StageBadge.stage` accepts arbitrary `String` instead of a typed enum | Create `enum RankingStage` and switch on it |
| 21 | `PhotoUploadTransport.swift` | Idempotency check uses string comparison `"409"` | Compare against `Int` HTTP status code: `response.statusCode == 409` |
| 22 | `Models.swift` | `RankedPhoto` and `PairPhoto` missing `Equatable` (synthesizable for free) | Add `Equatable` conformance |

---

## Priority 6 — Code Duplication & Cleanup

| # | File | Issue | Fix |
|---|------|-------|-----|
| 23 | `ResultsView.swift`, `CompletionView.swift` | Identical photo export logic copy-pasted in both views | Extract to a shared `PhotoExporter` struct |
| 24 | `PictalisApp.swift` | `configureNavigationBar()` duplicates all design tokens as raw RGB / font-name strings | Bridge to `DesignSystem` constants |
| 25 | `CullView.swift`, `ResultsView.swift` | Three unnecessary `Group {}` wrappers | Remove; `Group` is only needed for modifier application |
| 26 | `ComparisonView.swift` | One hardcoded `Color(red: 0.059, green: 0.055, blue: 0.043)` in fullscreen cover (line 97) | Replace with the appropriate `DesignSystem` color token |
| 27 | `ComparisonView.swift` | Accessibility labels use positional "Left photo" / "Right photo" — wrong in RTL | Change to "First photo" / "Second photo" |

---

## Priority 7 — Structured Concurrency Hygiene

Correct today but make future cancellation and cleanup harder.

| # | File | Issue |
|---|------|-------|
| 28 | `SyncService.swift`, `LocalCardProvider.swift` | `AsyncStream` continuations never finished on dealloc — streams hang open |
| 29 | `PhotoPipeline.swift`, `SyncService.swift`, `LocalCardProvider.swift` | Fire-and-forget `Task {}` blocks with no stored handles — can't cancel on "start over" |
| 30 | `CachedPhotoImage.swift` | Missing `guard !Task.isCancelled` before writing to cache on happy path |
| 31 | `DecisionStore.swift` | Persistence write task has no stored handle — can't be cancelled on view dismissal |

---

## File Health Summary

| File | Severity | Top Issue |
|------|----------|-----------|
| `SupabaseConfig.swift` | **High** | Real credentials in source |
| `APIClient.swift` | **High** | 3× force-unwrap crash risk + no timeouts |
| `ImageCompressor.swift` | **High** | Double-resume undefined behavior |
| `PhotoPipeline.swift` | **Medium** | Session dir deletion bug + fire-and-forget tasks |
| `AuthService.swift` | **Medium** | ObservableObject not migrated |
| `ContentView.swift` | **Medium** | Animation fires on every re-render |
| `CullView.swift` | **Medium** | Deprecated APIs (cornerRadius, UIScreen) |
| `CullChoiceView.swift` | **Medium** | isStarting never reset + deprecated cornerRadius |
| `ComparisonView.swift` | **Medium** | Hardcoded color + RTL a11y labels |
| `DecisionStore.swift` | **Medium** | Silent data loss on corrupted JSON |
| `SyncService.swift` | **Low** | Cancellation swallowed in retry |
| `LocalCardProvider.swift` | **Low** | nonisolated(unsafe), fire-and-forget tasks |
| `PhotoUploadTransport.swift` | **Low** | String status code comparison |
| `DesignSystem.swift` | **Low** | Dynamic Type not supported |
| `Models.swift` | **Low** | String dates/URLs, missing Equatable |
| `PictalisApp.swift` | **Low** | Duplicated design tokens |
| `ResultsView.swift` | **Low** | Duplicate export logic |
| `CompletionView.swift` | **Low** | Duplicate export logic |
| `SessionSetupView.swift` | **Clean** | — |
| `PhotoSource.swift` | **Clean** | — |
| `CachedPhotoImage.swift` | **Clean** | Minor: missing cancellation guard |
