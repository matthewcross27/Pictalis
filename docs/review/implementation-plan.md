# Pictalis iOS — Implementation Plan

> Generated 2026-06-28 from verified review findings.
> False positives and questionable items are in [needs-review.md](needs-review.md).
> Source of truth: [MASTER-REVIEW.md](MASTER-REVIEW.md).

All 31 original findings were verified against live source code. 3 are false positives,
2 were downgraded, 2 are acceptable patterns. The 24 confirmed findings are below,
grouped into logical change sets.

---

## Batch 1 — Secrets & Config (do first, affects all other work)

**Why first:** Credentials in source affect every developer who clones the repo. These also
need an `.xcconfig` before any other config-related cleanup.

| # | File | Fix |
|---|------|-----|
| 1a | `SupabaseConfig.swift` | Move `url` and `anonKey` to `Config.xcconfig` injected into `Info.plist`; update `SupabaseConfig` to read from `Bundle.main.infoDictionary`; add `SupabaseConfig.swift` to `.gitignore` if the real file is separate from the example |
| 1b | `PictalisApp.swift:13` | Move Sentry DSN (`options.dsn`) to `Config.xcconfig` → `Info.plist`, read via `Bundle.main.object(forInfoDictionaryKey:)` |

---

## Batch 2 — Crash Risks (two targeted guard fixes)

**Why urgent:** Both are reachable at runtime and produce uncatchable crashes.

| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|
| 2a | `APIClient.swift` | 75, 77, 124, 126, 173, 174 | 6 force-unwraps: 3x `URLComponents(url:...)!` and 3x `comps.url!` | Replace the three URL-building blocks with a private `buildURL(_:queryItems:)` helper that `throws`: `guard let comps = URLComponents(url:...), let url = comps.url else { throw APIError.badURL }` |
| 2b | `DecisionStore.swift` | 55 | `fileManager.urls(...).first!` in `DecisionPersistence.fileURL()` | `guard let support = fileManager.urls(...).first else { throw PersistenceError.noAppSupportDirectory }` — propagate throw through `load()` and `save()` |

---

## Batch 3 — Data Correctness

**Why:** Silent bugs that corrupt state or swallow cancellation in retry loops.

| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|
| 3a | `PhotoPipeline.swift` | 187–188 | `prepareSessionDirectory()` deletes entire `PictalisUploads/` parent folder, wiping all sessions | Change to `try? FileManager.default.removeItem(at: sessionDirectory)` (delete only the session subdirectory) |
| 3b | `PhotoPipeline.swift` | 317 | `try? await Task.sleep` swallows `CancellationError` in retry loop | Change to `try await Task.sleep(for: ...)` so cancellation propagates |
| 3c | `SyncService.swift` | 129 | Same `try? Task.sleep` issue in `performDrain()` backoff loop | Change to `try await Task.sleep(for: ...)` |
| 3d | `DecisionStore.swift` | 61–63 | Double `try?` returns empty `[]` silently on corrupted JSON — user loses cull progress with no warning | Log the decode error at minimum; ideally surface it to the caller |

---

## Batch 4 — Deprecated APIs (mechanical, no logic change)

All replacements are direct 1:1 substitutions.

| # | File | Sites | Old | New |
|---|------|-------|-----|-----|
| 4a | `CullView.swift` | Lines 61, 149, 157, 159, 208, 223 | `.cornerRadius(...)` | `.clipShape(RoundedRectangle(cornerRadius: ...))` |
| 4b | `CullChoiceView.swift` | Line 82 | `.cornerRadius(.interactiveRadius)` | `.clipShape(RoundedRectangle(cornerRadius: .interactiveRadius))` |
| 4c | `CullView.swift` | Line 20 | `UIScreen.main.bounds.width` | Wrap `cardStack` in `GeometryReader` and use `geo.size.width` |
| 4d | `DesignSystem.swift` | Lines 26–31 | `Font.custom("Fraunces-SemiBold", size: 36)` etc. | Add `relativeTo:` — match each font to its semantic style (e.g. display → `.largeTitle`, headline → `.headline`, caption → `.caption`) |

---

## Batch 5 — Accessibility (systematic, all views)

### 5a — Remove "Double-tap to" prefix from all 10 accessibilityHint strings

VoiceOver already announces "double tap to activate" before reading the hint, causing every hint
to be read twice. Remove the leading prefix from each site.

| File | Line | Current hint | Fixed hint |
|------|------|-------------|------------|
| `CullView.swift` | 174 | `"Double-tap to expand this photo"` | `"Expand this photo"` |
| `ComparisonView.swift` | 171 | `"Double-tap to choose this photo as your favorite"` | `"Choose this photo as your favorite"` |
| `ComparisonView.swift` | 186 | `"Double-tap to expand this photo"` | `"Expand this photo"` |
| `ResultsView.swift` | 77 | `"Double-tap to save all ranked photos to your Photos library"` | `"Save all ranked photos to your Photos library"` |
| `ResultsView.swift` | 142 | `"Double-tap to save this photo to your Photos library"` | `"Save this photo to your Photos library"` |
| `ResultsView.swift` | 151 | `"Double-tap to view full screen"` | `"View full screen"` |
| `CompletionView.swift` | 71 | `"Double-tap to view full screen"` | `"View full screen"` |
| `CompletionView.swift` | 92 | `"Double-tap to save all favorite photos to your Photos library"` | `"Save all favorite photos to your Photos library"` |
| `CompletionView.swift` | 97 | `"Double-tap to view the complete ranked list of your photos"` | `"View the complete ranked list of your photos"` |
| `CompletionView.swift` | 104 | `"Double-tap to begin a new curation session"` | `"Begin a new curation session"` |

### 5b — Fix RTL-unsafe positional accessibility labels in ComparisonView

| File | Line | Current | Fixed |
|------|------|---------|-------|
| `ComparisonView.swift` | 170 | `"Left photo"` / `"Right photo"` | `"First photo"` / `"Second photo"` |

---

## Batch 6 — @Observable Migration

These services still use `ObservableObject`/`@Published`/Combine. Migrate together because
`PictalisApp.swift` needs to change from `@StateObject` to `@State` once both services are done.

**Order:** `AuthService` → `APIClient` → `PhotoPipeline` → `PictalisApp` → `ContentView`.

| # | File | Change |
|---|------|--------|
| 6a | `AuthService.swift` | Remove `import Combine`, `ObservableObject`, `@Published`; add `@Observable @MainActor`; change `authError: String?` to `authError: Error?` |
| 6b | `APIClient.swift` | Remove `ObservableObject` conformance (no `@Published` properties exist); confirm `@MainActor` isolation is in place |
| 6c | `PhotoPipeline.swift` | Replace `ObservableObject` + `@Published` with `@Observable @MainActor`; store task handles from `start()` for cancellation |
| 6d | `PictalisApp.swift` | Change `@StateObject` to `@State` for both `auth` and `api` once 6a–6c are done |
| 6e | `ContentView.swift` | Change `@EnvironmentObject` to `@Environment` for `AuthService` and `APIClient` |

---

## Batch 7 — Type Safety in Models

Low risk — pure additive conformances or type substitutions. Verify the API date format before
implementing 7a.

| # | File | Line | Change |
|---|------|------|--------|
| 7a | `Models.swift` | 11–12, 37 | `createdAt: String`, `expiresAt: String` → `Date`; configure the decoder with the correct `dateDecodingStrategy` for the Supabase API (likely ISO 8601) |
| 7b | `Models.swift` | 71, 165 | `signedUrl: String`, `photoUrl: String` → `URL`; decoder validates at parse time; `AsyncImage` accepts `URL` directly |
| 7c | `Models.swift` | 65, 116 | Add `Equatable` to `PairPhoto` and `RankedPhoto` (all stored properties already conform; synthesized for free) |
| 7d | `DesignSystem.swift` | 103 | `StageBadge.stage: String` → `enum RankingStage: String { case stage1, stage2, stage3 }`; update the `label` switch and all call sites |

---

## Batch 8 — Code Quality & Cleanup

Small, independent changes. Any can be done in isolation.

| # | File | Change |
|---|------|--------|
| 8a | `ResultsView.swift`, `CompletionView.swift` | Extract shared photo-download + `PHPhotoLibrary` save logic into a `PhotoExporter` struct |
| 8b | `PictalisApp.swift` | `configureNavigationBar()`: replace the 6 raw RGB `UIColor` literals and 2 font-name strings with `DesignSystem` constants |
| 8c | `CullView.swift` | Line 152: Remove `Group {}` wrapper inside `.overlay()` — overlays accept `@ViewBuilder` directly |
| 8d | `ResultsView.swift` | Line 29: Remove `Group {}` wrapper inside `ZStack` — `ZStack` is already a `@ViewBuilder` container |
| 8e | `ComparisonView.swift` | Line 97: Replace `Color(red: 0.059, green: 0.055, blue: 0.043)` with an appropriate `DesignSystem` token; this very dark color has no named equivalent — consider adding `Color.photoBackground = Color(red: 0.059, green: 0.055, blue: 0.043)` to `DesignSystem.swift` |
| 8f | `ContentView.swift` | Add `Equatable` conformance to `AppState`; simplify to `.animation(.screenTransition, value: appState)` |
| 8g | `CullChoiceView.swift` | Line 96: Add `isStarting = false` before `onFilterThenRank()` on the success path |

---

## Batch 9 — Structured Concurrency Hygiene

Correct today but makes future cancellation and cleanup harder. Do after Batch 3.

| # | File | Issue | Fix |
|---|------|-------|-----|
| 9a | `SyncService.swift` | `AsyncStream` continuation in `startObservers()` is never finished | Store `continuation` and call `continuation.finish()` on teardown |
| 9b | `SyncService.swift` | Two observer tasks have no stored handles | Store as `private var tasks: [Task<Void, Never>]`; cancel on `deinit` |
| 9c | `PhotoPipeline.swift` | Fire-and-forget tasks in `start()` and `checkCompletion()` have no handles | Store handles; cancel on `deinit` or explicit stop |
| 9d | `LocalCardProvider.swift` | Fill tasks in `start()`, `advance()`, `retry()` have no handles | Low impact (guarded by `isFilling`) but storing the handle enables explicit cancellation |
| 9e | `CachedPhotoImage.swift` | Missing `guard !Task.isCancelled` before cache write | Add cancellation check before the cache-write on the happy path |

---

## Suggested Order of Attack

| Order | Batch | Why |
|-------|-------|-----|
| 1st | Batch 1 — Secrets | Security; must be done before any commit |
| 2nd | Batch 2 — Crashes | Safety; two surgical fixes |
| 3rd | Batch 3 — Data correctness | Correctness; small diffs |
| 4th | Batch 5 — Accessibility | Quick win; find-and-replace across views |
| 5th | Batch 4 — Deprecated APIs | Quick win; mechanical substitutions |
| 6th | Batch 6 — @Observable | Moderate effort; touches multiple files in concert |
| 7th | Batch 8 — Code quality | Low risk; independent changes |
| 8th | Batch 7 — Type safety | Requires verifying API date format first |
| 9th | Batch 9 — Concurrency | Lowest urgency; no correctness risk today |
