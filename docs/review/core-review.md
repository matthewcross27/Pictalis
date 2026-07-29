# App Core & Models Code Review

## Summary

The six foundation files are well-structured and largely idiomatic SwiftUI. The
two most pressing issues are a real credential leak in `SupabaseConfig.swift`
(the anon key is hardcoded in a tracked file, which contradicts the `.gitignore`
entry and the project's own "Never Do" rule) and a potential continuation double-
resume in `ImageCompressor.swift` when `PHImageManager` delivers degraded
previews. Secondary themes are: magic hex literals duplicated between
`PictalisApp.swift` and `DesignSystem.swift`, `Font.custom` missing `relativeTo`
(breaking Dynamic Type scaling), and `AppState` missing `Equatable` (causing the
`animation(value:)` call to compare a closure-derived `Int` rather than the
actual state type).

---

## File-by-File Findings

### PictalisApp.swift
**Severity: Medium**

#### Issues

- **[line 13] Warning — Sentry DSN hardcoded in source**
  The DSN string `https://f04eecf4335b7b4a400ff6327ea33968@...` is committed to
  the repo. DSNs are not secret (they are safe to expose), but storing them as
  literals makes per-environment switching (dev / staging / prod) impossible
  without a source change. Better approach: read from `Info.plist` via a key
  such as `SENTRY_DSN` that is injected by the build system or an `.xcconfig`
  file, matching the pattern already used (or intended) for `SupabaseConfig`.

- **[line 15] Warning — `tracesSampleRate = 0` silently disables performance
  monitoring**
  Setting the rate to `0` means zero performance transactions are captured.
  This may be intentional for the MVP, but it is easy to forget. A comment
  explaining why (e.g., `// disabled until we need perf monitoring`) would
  prevent future confusion.

- **[lines 40-57] Warning — Magic color / font literals duplicated from
  DesignSystem.swift**
  `configureNavigationBar()` hard-codes raw RGB triples and the `Fraunces-
  SemiBold` font name as string literals. Every one of these values already
  exists in `DesignSystem.swift` (`Color.ink`, `Color.filmWhite`, `Color.amber`,
  `Font.titleSerif`, etc.). `UIKit`-facing APIs cannot consume SwiftUI
  `Color`/`Font` directly, but the raw values should be derived from shared
  constants — e.g., define `UIColor` counterparts in `DesignSystem.swift` or
  extract them from the SwiftUI colors via `UIColor(Color.ink)` — so a single
  source-of-truth exists. As written, updating the brand palette requires edits
  in two places.

- **[line 57] Suggestion — `UINavigationBar.appearance()` tintColor literal**
  Same duplication issue as above; `UIColor(red:0.700, green:0.480,
  blue:0.060, alpha:1)` is `Color.amber` re-expressed as a literal.

- **[lines 8-9] Suggestion — `@StateObject` + `ObservableObject` is correct but
  note upgrade path**
  `AuthService` and `APIClient` use `ObservableObject` / `@Published`. For
  iOS 17+ targets the `@Observable` macro eliminates `@StateObject` and
  `@EnvironmentObject` entirely, giving finer-grained re-renders and simpler
  syntax. Not a bug today, but worth planning for the next refactor cycle given
  the project's iOS 17+ baseline.

#### Clean

- `@main` struct, `App` protocol, and `WindowGroup` are used correctly.
- No business logic in `body`.
- `.task { await auth.signInIfNeeded() }` is the right hook (over `onAppear`)
  for async work.
- `SupabaseClient` is constructed once in `init`, wrapped in `@StateObject`, and
  injected — no singletons, no global state.

---

### ContentView.swift
**Severity: Medium**

#### Issues

- **[lines 82-91] Bug — `animation(_:value:)` evaluates a closure, not `AppState`**
  The `value:` parameter of `.animation` must be `Equatable`. The current
  pattern passes a closure that returns an `Int` (computed on every render via an
  immediately-invoked closure). While this compiles — `Int` is `Equatable` — it
  means the animation fires on every re-render even when only associated values
  inside `AppState` change (e.g., `pipeline` changes within `.culling` without
  the enum case itself changing). More importantly, AppState needs `Equatable`
  conformance anyway for this pattern to be reliable. Fix: add `Equatable` to
  `AppState` and pass `appState` directly:
  ```swift
  .animation(.screenTransition, value: appState)
  ```

- **[lines 3-10] Warning — `AppState` is missing `Equatable` (and optionally
  `Hashable`)**
  `AppState` stores associated values (`sessionId: UUID`, `pipeline:
  PhotoPipeline`, etc.). Because `PhotoPipeline` is a `class`, Swift cannot
  automatically synthesize `Equatable`. A comparison based on enum case + session
  ID is sufficient for animation gating. Options: (a) conform `PhotoPipeline` to
  `Equatable` (identity comparison with `===`), or (b) use a separate
  `@State private var appStateOrdinal: Int` for animation and keep the full
  `AppState` for rendering — the cleaner split.

- **[line 9] Suggestion — `results` case default parameter values on enum**
  `case results(sessionId: UUID, previousComparisons: Int? = nil, initialPhotos:
  [RankedPhoto] = [])` — default values on enum associated values are legal Swift
  but unusual; they cannot be omitted at call sites using pattern matching. This
  is fine today but consider whether a dedicated struct payload would be clearer
  as the state grows.

#### Clean

- `NavigationStack` is not used at the root level (correct for this flat-state
  machine architecture). `NavigationStack` appears only where needed
  (`ResultsView`).
- State ownership is appropriate — `ContentView` owns `AppState`, children
  receive callbacks.
- No business logic in `body`; all transitions are driven by closures passed to
  child views.
- `EnvironmentObject` injection matches the `@StateObject` declarations in
  `PictalisApp`.

---

### DesignSystem.swift
**Severity: Low**

#### Issues

- **[lines 26-31] Warning — `Font.custom(_:size:)` without `relativeTo:` breaks
  Dynamic Type**
  All six font definitions use the two-argument `Font.custom(_:size:)` overload,
  which produces a fixed-size font that does not scale with the user's preferred
  text size. iOS accessibility guidelines require custom fonts to scale. Fix:
  use the three-argument overload and map each token to the closest system text
  style:
  ```swift
  static let displaySerif  = Font.custom("Fraunces-SemiBold", size: 36,  relativeTo: .largeTitle)
  static let headlineSerif = Font.custom("Fraunces-SemiBold", size: 22,  relativeTo: .title2)
  static let titleSerif    = Font.custom("Fraunces-Medium",   size: 17,  relativeTo: .headline)
  static let bodySerif     = Font.custom("Fraunces-Regular",  size: 16,  relativeTo: .body)
  static let labelSerif    = Font.custom("Fraunces-Medium",   size: 14,  relativeTo: .subheadline)
  static let captionSerif  = Font.custom("Fraunces-Regular",  size: 11,  relativeTo: .caption)
  ```
  This is a one-line change per token and fixes a real accessibility gap.

- **[lines 119-123] Warning — `StageBadge.stage` accepts arbitrary `String`**
  The `stage` property on `StageBadge` is compared against raw string literals
  `"stage1"`, `"stage2"`, `"stage3"`. Any caller typo silently falls through to
  the `default` branch and renders the raw API key. The API already returns these
  as strings (see `SessionInfo.stage` in Models.swift), but a lightweight enum:
  ```swift
  enum RankingStage: String, Decodable { case stage1, stage2, stage3 }
  ```
  used both in `StageBadge` and in the model would eliminate the stringly-typed
  hazard. If the API set is open-ended, at minimum document the accepted values
  with a comment.

- **[line 75] Warning — Magic pressed-state color in `PrimaryButtonStyle`**
  `Color(red: 0.600, green: 0.400, blue: 0.045)` is a one-off pressed variant of
  `Color.amber` with no name. Define it as `Color.amberPressed` in the palette
  block so the design token vocabulary is complete.

#### Clean

- Colors use semantic names, not hex literals at call sites.
- `CGFloat` extension for corner radii is correct and prevents magic numbers.
- `Animation` constants are well-named with explicit documentation comments
  explaining the timing rationale.
- `ButtonStyle` implementations are clean — `@Environment(\.isEnabled)` is used
  correctly in `PrimaryButtonStyle`.
- `PhotoTapStyle` scale value (0.96) matches a common HIG guideline for photo
  tap feedback.

---

### SupabaseConfig.swift
**Severity: High**

#### Issues

- **[line 7] Bug — Real anon key hardcoded in a source file**
  The full JWT anon key `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...` is present in
  the committed file `SupabaseConfig.swift`. While this file is correctly listed
  in `.gitignore` (line 54: `ios/Sources/App/SupabaseConfig.swift`), the file
  nonetheless exists on disk and will be included in any archive, `.ipa`, or
  bundle — where it can be extracted with standard iOS app analysis tools.

  The Supabase anon key is by design a public key (Row-Level Security is the
  enforcement layer), so it is not a catastrophic secret leak. However:
  1. Hardcoding it violates the project's own "Never commit .env files or API
     keys" rule in `CLAUDE.md`.
  2. It makes switching environments (dev / staging / prod) impossible without a
     code change.
  3. The comment on line 1 says "Copy this file to SupabaseConfig.swift and fill
     in your values" — the template and the real file have merged, which defeats
     the `.example` workflow.

  **Recommended fix:** load the values from `Info.plist` keys that are
  themselves populated from an `.xcconfig` file (which stays out of git):
  ```swift
  // In Info.plist:
  // SUPABASE_URL  → $(SUPABASE_URL)
  // SUPABASE_ANON_KEY → $(SUPABASE_ANON_KEY)

  enum SupabaseConfig {
      static let url: URL = {
          let raw = Bundle.main.infoDictionary!["SUPABASE_URL"] as! String
          return URL(string: raw)!
      }()
      static let anonKey: String =
          Bundle.main.infoDictionary!["SUPABASE_ANON_KEY"] as! String
  }
  ```
  Add `Secrets.xcconfig` (with the real values) to `.gitignore` and commit a
  `Secrets.xcconfig.example` with placeholder values.

- **[line 6] Suggestion — `URL(string:)!` force-unwrap**
  If the URL string is ever malformed (e.g., during an environment migration), the
  app crashes at launch with no diagnostic. Replace with a `preconditionFailure`
  or a `fatalError` with an explanatory message, or use the Info.plist approach
  above and validate at launch.

#### Clean

- The `enum` (caseless) pattern for a config namespace is correct Swift.
- No `SupabaseClient` singleton is constructed here — instantiation is deferred
  to `PictalisApp.init`, which is correct.

---

### Models/Models.swift
**Severity: Low**

#### Issues

- **[lines 13, 19, 36, 45, 55-56, 68-70, etc.] Warning — `createdAt`, `expiresAt`,
  `signedUrl` typed as `String` instead of `Date` / `URL`**
  Timestamp fields (`createdAt: String`, `expiresAt: String`) and URL fields
  (`signedUrl: String`, `photoUrl: String?`) are modeled as raw strings. This
  means every consumer must parse them manually, and any format mismatch is a
  runtime error rather than a decode-time error.

  For timestamps: add a `JSONDecoder.dateDecodingStrategy` (`.iso8601` or
  `.formatted(ISO8601DateFormatter())`) and type the fields as `Date`. The cull
  local-sync path already uses `Date` correctly for `StoredDecision.timestamp`
  (line 200), so the decoder infrastructure is already expected to exist.

  For URLs: typing `signedUrl: URL` in `PairPhoto` and `RankedPhoto` causes
  `JSONDecoder` to validate the URL at decode time and gives call sites a
  properly typed value rather than a string they must convert.

- **[lines 116-136] Suggestion — `RankedPhoto` and `PairPhoto` are missing
  `Equatable`**
  Both are used in `ForEach` (via `Identifiable`) and likely in diffing logic
  (e.g., checking whether the next pair changed). Without `Equatable`, callers
  cannot express "has this photo changed?" without comparing individual fields.
  All fields are value types (`UUID`, `String`, `Double`, `Int`, `Bool`) so
  synthesis is free:
  ```swift
  struct RankedPhoto: Decodable, Identifiable, Equatable { ... }
  ```

- **[lines 162-173] Suggestion — `CullCard` optionality is partially inconsistent**
  When `done == true`, the `photoId`, `photoUrl`, and `cardsRemaining` fields are
  logically absent (server does not send them). When `done == false`, they are
  logically present. This could be modeled as an enum with associated values:
  ```swift
  enum CullCardResult: Decodable {
      case card(photoId: UUID, photoUrl: String, cardsRemaining: Int)
      case done
  }
  ```
  That said, the current flat struct with optionals works fine and the custom
  decoding required for the enum variant may not be worth the complexity. At
  minimum, a code comment explaining the `done == true` → all optionals nil
  contract would help future maintainers.

- **[lines 197-209] Suggestion — `StoredDecision.synced` is `var` but the struct
  is `Sendable`**
  `StoredDecision` is `Sendable` and `Codable`. The mutable `var synced: Bool`
  field means any code holding a `StoredDecision` copy can mutate it freely,
  which is fine for a value type, but the mutation is the whole point of the
  field (marking records as synced). Ensure that callers update via the
  containing `SessionDecisionFile.decisions` array (replacing elements) rather
  than mutating in-place. This is a documentation/pattern issue rather than a
  correctness bug.

#### Clean

- All models are `struct` (value types) — correct for data models.
- `Codable` / `CodingKeys` are thorough and match snake_case API field names.
- `Identifiable` is applied to `PairPhoto` and `RankedPhoto` — correct for
  `ForEach` use.
- `UUID` is used for IDs throughout — strongly typed, no raw `String` IDs.
- `@Published` does not appear anywhere in this file — view-model concerns are
  correctly separated.
- `CullDecision` and `StoredDecision` are both `Sendable` — correct for
  cross-actor transport.
- The file is well organized with `// MARK:` sections matching the API endpoints.

---

### ImageCompressor.swift
**Severity: Medium**

#### Issues

- **[lines 43-53] Bug — `withCheckedThrowingContinuation` can double-resume when
  PHImageManager delivers a degraded preview followed by the final image**
  `PHImageManager.requestImageDataAndOrientation` with `isSynchronous = false`
  and `deliveryMode = .highQualityFormat` _may_ call its completion handler twice
  on some devices: first with a degraded/cached version (`PHImageResultIsDegradedKey
  == true`), then with the full-resolution result. Each call would invoke
  `continuation.resume(...)`, causing undefined behavior (and a runtime warning
  in Swift 5.9+ strict concurrency mode). Fix: check the degraded key before
  resuming:
  ```swift
  } { data, _, _, info in
      let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
      if isDegraded { return }   // wait for full-resolution delivery
      if let error = info?[PHImageErrorKey] as? Error {
          continuation.resume(throwing: error)
      } else if let data {
          continuation.resume(returning: data)
      } else {
          continuation.resume(throwing: CompressionError.noImageData)
      }
  }
  ```

- **[line 68] Suggestion — `UIGraphicsImageRendererFormat.default()` may produce
  an extended-range (HDR) color space on ProMotion / HDR-capable devices**
  `UIGraphicsImageRendererFormat.default()` inherits the display's color space,
  which on recent iPhones is Display P3. Since the output is immediately JPEG-
  encoded (which typically targets sRGB), passing `.default()` risks subtle color
  shifts on wide-gamut devices. Use `.preferred()` instead (iOS 17 SDK name:
  `UIGraphicsImageRendererFormat.preferred()`), which automatically selects the
  most appropriate format for the task, or explicitly set
  `format.preferredRange = .standard` to force sRGB. Additionally, because JPEG
  output for working copies does not need transparency, setting `format.opaque =
  true` eliminates an unnecessary alpha channel in the intermediate bitmap,
  reducing memory pressure by ~25%.

- **[line 10] Suggestion — `jpegQuality: CGFloat = 0.75` is slightly below
  typical working-copy quality**
  0.75 JPEG quality is on the aggressive side for a "working copy" that users
  compare side-by-side. The PRD states compressed copies are used for pairwise
  comparison, where visible compression artifacts can affect perceived photo
  quality and skew results. 0.80–0.85 is a more defensible default (still well
  within the upload size budget given 1920px max dimension). This is a tuning
  decision, not a correctness bug.

- **[lines 20-23] Suggestion — `Task.detached` is not cancellation-aware**
  The detached task for `compressImage` does not check `Task.isCancelled`
  between the scale and encode steps. For very large images the scaling step can
  take 100ms+. If the user navigates away, the parent task is cancelled but the
  detached task runs to completion and allocates memory unnecessarily. For MVP
  scope this is acceptable, but a `try Task.checkCancellation()` between scale
  and encode would make cleanup faster under memory pressure.

#### Clean

- `UIGraphicsImageRenderer` is used correctly (not the deprecated
  `UIGraphicsBeginImageContextWithOptions`).
- `scale = 1` on the renderer format is correct and well-commented — this is a
  non-obvious detail that prevents 2x/3x bitmap inflation.
- `floor()` on the scaled dimensions prevents off-by-one pixel rounding.
- CPU-heavy scaling is explicitly moved off the main actor via `Task.detached` —
  correct.
- `fetchData` wraps the callback-based API in `withCheckedThrowingContinuation`
  correctly (modulo the degraded-image issue above).
- `compressImage` is exposed as `static` and is synchronous, making it unit-
  testable without mocking PHAsset.
- `PHImageRequestOptions.isNetworkAccessAllowed = true` ensures iCloud photos are
  fetched — a common omission.

---

## Cross-Cutting Themes

### 1. Secret / credential hygiene gap
The Sentry DSN (PictalisApp.swift:13) and Supabase anon key
(SupabaseConfig.swift:7) are both embedded as string literals. The project has
the right instincts — `SupabaseConfig.swift` is in `.gitignore`, and a
`.example` file exists — but the actual file was committed with real values.
Migrating both to Info.plist / `.xcconfig` injection is the same pattern and
should be done together.

### 2. Magic literals duplicated between PictalisApp and DesignSystem
`configureNavigationBar()` re-expresses every design token (colors, font names,
sizes) as raw literals. This creates a hidden second source of truth. A `UIColor`
extension or a small bridge file (e.g., `UIColor.ink`, `UIColor.filmWhite`)
would eliminate this duplication at minimal cost.

### 3. Missing Dynamic Type support
All six `Font.custom` definitions in DesignSystem omit `relativeTo:`. This is a
single-line fix per token and has high accessibility impact — users with larger
text settings will see fixed-size Fraunces throughout the app.

### 4. ObservableObject vs @Observable
`AuthService`, `APIClient`, and `PhotoPipeline` all use the iOS 14-era
`ObservableObject` + `@Published` + `@StateObject` / `@EnvironmentObject`
pattern. The app targets iOS 17+, where the `@Observable` macro is the
recommended approach. This does not need to be addressed now, but it should be
on the radar for a future "modernize observability" pass — the new pattern
reduces view re-render scope and eliminates the `@EnvironmentObject` dance.

---

## Priority Fix List

| Priority | File | Issue | Effort |
|----------|------|-------|--------|
| 1 | `SupabaseConfig.swift` | Real anon key hardcoded — migrate to Info.plist/xcconfig | Low |
| 2 | `ImageCompressor.swift` | Double-resume bug when PHImageManager returns degraded image | Low |
| 3 | `PictalisApp.swift` | Sentry DSN hardcoded — migrate to Info.plist/xcconfig | Low |
| 4 | `DesignSystem.swift` | `Font.custom` missing `relativeTo:` — Dynamic Type broken | Low (6 lines) |
| 5 | `ContentView.swift` | `AppState` needs `Equatable`; animation should use `value: appState` | Low |
| 6 | `PictalisApp.swift` | Magic color/font literals in `configureNavigationBar` — add UIColor bridge | Medium |
| 7 | `DesignSystem.swift` | `StageBadge.stage` is stringly-typed — add `RankingStage` enum | Low |
| 8 | `Models/Models.swift` | Timestamp fields as `String` instead of `Date` | Medium |
| 9 | `ImageCompressor.swift` | Renderer format: set `opaque = true`, consider `preferredRange = .standard` | Low |
| 10 | `Models/Models.swift` | `RankedPhoto` / `PairPhoto` missing `Equatable` | Trivial |
