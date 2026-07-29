# Views Code Review

## Summary

The seven view files are well-structured overall: async work is consistently driven by `.task`, state is `private`, and the design system (colour tokens, type tokens, corner-radius tokens) is used correctly in most places. The two dominant themes worth addressing are (1) a mixed observation model — `PhotoPipeline` and the environment services still use the legacy `ObservableObject` / `@ObservedObject` / `@EnvironmentObject` stack while newer owned objects (`DecisionStore`, `LocalCardProvider`) already use the Swift 5.9 `@Observable` macro, which creates asymmetric patterns that will become friction when iOS 16 support is eventually dropped; and (2) accessibility hints that begin with "Double-tap", which VoiceOver already announces automatically, making the phrase redundant and potentially confusing.

---

## File-by-File Findings

### ComparisonView.swift

**Severity: Medium**

#### Issues

- **[line 7] Warning — `@ObservedObject var pipeline` is not `private`.**
  `@ObservedObject` properties passed in from a parent should still be declared `private` unless the parent reaches in to mutate them (it doesn't here). Without `private`, callers see the property as part of the view's surface area. Change to `@ObservedObject private var pipeline: PhotoPipeline`.

- **[line 7] Warning — mixed observation model: `@ObservedObject` for `PhotoPipeline` (an `ObservableObject`) alongside the `@Observable` macro used on `DecisionStore` / `LocalCardProvider`.**
  Both work today but they live on different SwiftUI tracking paths. If `PhotoPipeline` is ever migrated to `@Observable`, `@ObservedObject` becomes a no-op without triggering a compiler error, silently breaking reactivity. Annotate the migration intention and consider a single-pass migration to `@Observable` across all service objects when iOS 16 is dropped.

- **[line 20] Suggestion — `@State private var prefetchTask: Task<Void, Never>?` is a valid pattern but Task is not `Equatable` / `Identifiable`.**
  SwiftUI doesn't diff the value of Task, so this is safe. However, since the task is cancelled and replaced imperatively rather than using a `task(id:)` modifier, the lifecycle is slightly less transparent. This is fine as-is; just worth documenting the intent (done in `startPrefetch()`). No change required.

- **[line 97] Warning — hardcoded raw colour `Color(red: 0.059, green: 0.055, blue: 0.043)` in the fullscreen cover background.**
  All other views use the design-system token (e.g. `Color.ink`). The raw value matches the dark ink/near-black used elsewhere. Replace with the appropriate token (likely `Color.ink`) so the colour adapts if the palette changes and keeps a single source of truth.

- **[lines 171] Warning — `accessibilityLabel` reads "Left photo" / "Right photo".**
  These labels are derived from position (`photo.id == pair?.photoA.id`), not from any semantic content. Spatial descriptions like "left" and "right" are not meaningful to VoiceOver users who rely on element order, and they're also wrong in right-to-left locales. A more meaningful label might be "First photo" / "Second photo" or, if photos have filenames, the filename. The hint on line 171 also violates the guideline below.

- **[lines 171, 186] Warning — `accessibilityHint` values start with "Double-tap".**
  Apple's HIG and VoiceOver documentation state that hints should not begin with the word "tap", "double-tap", "swipe", or similar gesture words because VoiceOver automatically prepends the appropriate gesture instruction. Starting with "Double-tap to …" causes VoiceOver to say "Double-tap to choose… double tap to activate" — the phrase is read twice. Rewrite hints as plain action phrases: "Choose this photo as your favorite" and "Expand this photo".

- **[line 214–217] Suggestion — bare `Task {}` (non-`@MainActor`) used to reset `hasDragged` after a delay.**
  The mutation `hasDragged.wrappedValue = false` happens on an unspecified actor inside a plain `Task`. Since `hasDragged` is a `Binding<Bool>` backed by `@State`, writes must happen on the `MainActor`. This works in practice only because bindings into `@MainActor`-isolated state hop back automatically, but the intent is obscured. Use `Task { @MainActor in … }` for clarity.

---

### CullView.swift

**Severity: Medium**

#### Issues

- **[line 7] Warning — `@ObservedObject var pipeline: PhotoPipeline` not `private`.**
  Same as `ComparisonView`. Mark `private`.

- **[line 10] Suggestion — `@State private var decisionStore = DecisionStore()` is correct for an `@Observable` owned instance.**
  `@State` is the right wrapper for owned `@Observable` class instances (not `@StateObject`, which is for `ObservableObject`). This is already correct. Noted here positively to confirm no change needed.

- **[lines 11–12] Warning — `@State private var cardProvider: LocalCardProvider?` and `@State private var syncService: SyncService?` stored as Optional `@State`.**
  `LocalCardProvider` is `@Observable`. Storing it as `Optional<LocalCardProvider>` in `@State` means SwiftUI's observation tracking starts only once the optional is non-nil. The body switch at line 30 (`cardProvider?.state ?? .loading`) accesses a property on a potentially nil optional — this means SwiftUI cannot establish a tracking dependency until `cardProvider` is set, so the first render with `cardProvider == nil` correctly shows `.loading`, but any render before `initialize()` completes is not observation-driven. This is safe here because `.loading` is the fallback, but the pattern should be documented. An alternative is to introduce a `@State private var isInitialized = false` guard (already present) and keep the pattern as-is with a comment explaining the intentional nil-Optional tracking.

- **[line 20] Warning — `UIScreen.main.bounds.width` is deprecated on iOS 16+ (flagged in Xcode 16 warnings).**
  `UIScreen.main` produces a deprecation warning in Xcode 15+ and is not multi-window safe. Replace with a `GeometryReader`-derived width. The `cardStack()` method already uses `GeometryReader` at line 139 — pass `geo.size.width` into `commitDecision` or compute `dragProgress` inside `cardStack` rather than at the struct level.

- **[lines 153–162] Suggestion — `Group {}` wrapper for the conditional drag-overlay could be replaced with `@ViewBuilder` or a direct `if/else` inside `.overlay(_:)`.**
  `.overlay` accepts a `@ViewBuilder` closure directly in iOS 15+, so the `Group` is unnecessary: `.overlay { if dragOffset > 0 { … } else if dragOffset < 0 { … } }`. The refactored form is more idiomatic.

- **[lines 149, 156, 159] Warning — `.cornerRadius(_:)` used on `Image` and `Color` views.**
  `.cornerRadius` is deprecated since iOS 16; use `.clipShape(RoundedRectangle(cornerRadius:))` instead. Applies to four call sites in this file (lines 61, 149, 156, 159, 208, 223).

- **[line 174] Warning — accessibilityHint starts with "Double-tap".**
  Same issue as `ComparisonView`. Rewrite as "Expand this photo".

- **[line 188] Suggestion — `.spring(response:)` used without `dampingFraction`.**
  `spring(response:)` works but will use the default damping. The sibling call on line 208 in `commitDecision` uses `.easeOut`. For consistent feel, pick a single spring definition and apply it from a shared constant.

---

### CullChoiceView.swift

**Severity: Low**

#### Issues

- **[line 82] Warning — `.cornerRadius(.interactiveRadius)` is deprecated since iOS 16.**
  Use `.clipShape(RoundedRectangle(cornerRadius: .interactiveRadius))` instead.

- **[lines 91–101] Warning — `isStarting` is never reset to `false` on the success path.**
  When `beginCull()` succeeds it calls `onFilterThenRank()` and returns. `isStarting` remains `true`, leaving both buttons disabled. If navigation is handled by replacing this view, that's fine — but if the view can be presented again (e.g. back-navigation), it will appear stuck. Defensively add `isStarting = false` before calling `onFilterThenRank()`, or rely on the view being removed from the hierarchy on success (which should be documented).

- **[line 88] Suggestion — the `"Rank only"` card passes `isLoading: false` as a literal.**
  This is correct and intentional, but it means `choiceCard` carries an `isLoading` parameter that's always `false` for one call-site. Consider removing the parameter from the button card view if the caller always knows whether to show a spinner, or add a spinner to the `onRankOnly` path as well for consistency.

---

### ResultsView.swift

**Severity: Low**

#### Issues

- **[lines 29–56] Suggestion — unnecessary `Group {}` wrapping the content states.**
  `Group` is needed when you need to apply a single modifier to multiple view types that share no common supertype. Here the `Group` wraps an `if/else if/else if/else` inside a `ZStack`. The `ZStack` body is already `@ViewBuilder` and accepts conditional branches natively. Removing the `Group` makes the structure flatter and reduces nesting.

- **[line 49] Suggestion — `ForEach(Array(photos.enumerated()), id: \.element.id)` is the correct pattern for an indexed `ForEach` on stable identifiable items.**
  This is correct and avoids `.indices` instability. No change needed — noted positively.

- **[lines 91–98] Suggestion — manual `Binding(get:set:)` construction for the alert dismissal.**
  A cleaner SwiftUI idiom for "alert driven by optional message" is `.alert("Title", isPresented: $exportAlertMessage.isNotNil) { … }` using a small `Optional` extension, or simply store a `Bool` alongside the message and bind to the `Bool`. The current manual `Binding` works but is harder to read.

- **[lines 77, 142, 151] Warning — all `accessibilityHint` strings begin with "Double-tap".**
  Same as other files; remove "Double-tap to" prefix.

- **[line 128] Suggestion — `Group {}` used as the button label for the download button.**
  A `Group` in a Button label is valid (it lets you apply `.font` / `.padding` to multiple children uniformly). This is an acceptable use of `Group`. No change required.

---

### CompletionView.swift

**Severity: Low**

#### Issues

- **[lines 71, 92, 97, 104] Warning — all `accessibilityHint` strings begin with "Double-tap".**
  Same issue as other files. Rewrite as plain action descriptions.

- **[lines 114–121] Suggestion — manual `Binding(get:set:)` for alert.**
  Same pattern as `ResultsView`. Consolidate into a helper or use a `Bool` flag.

- **[line 81] Suggestion — `Task { @MainActor in await exportAll() }` inside a button action.**
  Since `exportAll()` is already an `async` function and the enclosing view is on the `MainActor` (all `@State` writes happen on main), the `@MainActor` annotation is redundant inside the Task closure — the view's isolation already guarantees it. Replace with `Task { await exportAll() }`. This is cosmetic but reduces noise.

- **[line 50] Suggestion — `ForEach(Array(photos.prefix(10).enumerated()), id: \.element.id)` is correct.**
  Noted positively — the `.prefix(10)` before `enumerated()` avoids an O(n) buffer on every re-render. No change needed.

---

### SessionSetupView.swift

**Severity: Low**

#### Issues

- **[lines 73, 99] Warning — `accessibilityHint` values begin with "Double-tap".**
  Same issue as other files.

- **[line 109–137] Suggestion — `startSession()` is a synchronous function that creates a detached `Task { @MainActor in … }` internally.**
  This hides the async nature of the operation from the call site. A more transparent pattern is to mark the function `async` (or `@MainActor`) and call it from `.task` / an `async` button handler. However, because `startSession()` is called from a `Button(action:)` closure (which is synchronous), the current `Task` wrapping is the appropriate mechanism and is handled correctly. Minor concern: `isStarting` is never reset on the success path because `onStart` is called (which presumably replaces the view), but if the caller keeps `SessionSetupView` in the hierarchy after `onStart`, `isStarting` will remain `true`. Consider a defensive reset similar to the `CullChoiceView` note.

---

### CachedPhotoImage.swift

**Severity: Low / Clean**

#### Issues

- **[line 7] Suggestion — `PhotoMemoryCache: @unchecked Sendable`.**
  `@unchecked Sendable` bypasses Swift Concurrency safety checks. The underlying `NSCache` is documented as thread-safe, so this is functionally correct, but the unchecked annotation should have a comment explaining why it's safe. Consider adding `// NSCache is thread-safe; @unchecked is safe here.`

- **[line 51] Suggestion — `phase = .success(Image(uiImage: uiImage))` is called after a successful network fetch. There is no check that the `Task` was not cancelled between the network response arriving and the store/assign steps.**
  The `catch` block at line 52 checks `Task.isCancelled`, but the happy path does not. If the task is cancelled just after decoding but before the assignment, `phase` is updated in a cancelled task context. In practice SwiftUI's `task(id:)` cancels the old task before starting a new one, so the next task will overwrite the phase anyway — but adding a `guard !Task.isCancelled else { return }` before the `store` and `phase` assignment would be more defensive.

- **[lines 59–80] Clean — `PhotoExpandedView` is well-structured: small, single-responsibility, uses `CachedPhotoImage` for cache hits, correct tap dismiss pattern.**

---

## Cross-Cutting Themes

1. **Mixed observation model.** Three environment objects (`APIClient`, `AuthService`) and two prop-injected objects (`PhotoPipeline` in `ComparisonView` / `CullView`) use the legacy `ObservableObject` / `@EnvironmentObject` / `@ObservedObject` stack. Newer owned objects (`DecisionStore`, `LocalCardProvider`) correctly use `@Observable`. The app targets iOS 17+, so the entire codebase could migrate to `@Observable` + `@Environment`. Until then, the split model works correctly but requires developers to remember which wrapper applies to which class.

2. **Deprecated `.cornerRadius(_:)` modifier.** Seven call sites across `CullView` (6) and `CullChoiceView` (1) use the deprecated `.cornerRadius` modifier instead of `.clipShape(RoundedRectangle(cornerRadius:))`. This was deprecated in iOS 16 / Xcode 15 and will generate warnings. The rest of the codebase already uses `.clipShape(RoundedRectangle(cornerRadius:))` correctly.

3. **Accessibility hints prefixed with "Double-tap".** All 13 `accessibilityHint` strings across the 7 files begin with "Double-tap to …". Apple's VoiceOver already announces "double tap to activate" after the label and hint — the prefix causes duplication. Rewrite all hints as plain action descriptions (e.g. "Choose this photo as your favorite" instead of "Double-tap to choose this photo as your favorite"). This is a systemic fix requiring a single find-and-replace pass.

4. **`UIScreen.main` deprecation.** Used once in `CullView` for drag threshold calculations. Should be replaced with `GeometryReader`-derived width to be multi-window safe and to silence Xcode deprecation warnings.

5. **`isStarting` / `isLoading` not reset on success before navigation.** Both `CullChoiceView` and `SessionSetupView` leave their loading flags `true` when the success callback fires. This is only a problem if the parent can navigate back to these views without reinitialising them, but defensive resets cost nothing.

6. **Duplicated export logic.** The photo export implementation (download data → decode `UIImage` → `PHPhotoLibrary.performChanges`) is copy-pasted identically between `ResultsView.exportPhoto()` and `CompletionView.exportAll()`. This should be extracted to a shared utility (e.g. `PhotoExporter.swift`) to keep the two screens in sync as error handling evolves.

---

## Priority Fix List

### Fix First (Warnings — correctness or deprecated API)

1. **Replace `.cornerRadius(_:)` with `.clipShape(RoundedRectangle(cornerRadius:))`** across `CullView` (6 sites) and `CullChoiceView` (1 site). Deprecated API, generates Xcode warnings.

2. **Replace `UIScreen.main.bounds.width` in `CullView` line 20** with `GeometryReader`-derived width. Deprecated in Xcode 15, not multi-window safe.

3. **Mark `@ObservedObject var pipeline` as `private`** in `ComparisonView` (line 7) and `CullView` (line 7). Minor encapsulation fix, prevents unintended surface-area exposure.

4. **Replace hardcoded `Color(red: 0.059, green: 0.055, blue: 0.043)` in `ComparisonView` line 97** with the appropriate design-system colour token.

### Fix Second (Warnings — accessibility and UX)

5. **Strip "Double-tap to" / "Double-tap" prefix from all 13 `accessibilityHint` strings** across all 7 files. VoiceOver doubles the phrase. Single find-and-replace pass.

6. **Rewrite `accessibilityLabel` for photo cards in `ComparisonView` (line 170)** from positional "Left photo" / "Right photo" to "First photo" / "Second photo" or similar non-spatial description.

### Fix Third (Suggestions — polish and maintainability)

7. **Extract photo export to a shared `PhotoExporter` utility** to de-duplicate identical logic in `ResultsView` and `CompletionView`.

8. **Remove unnecessary `Group {}` wrappers** in `ResultsView` (line 29) and `CullView` drag overlay (line 153). Use direct `@ViewBuilder` conditionals.

9. **Add `guard !Task.isCancelled` on the happy path in `CachedPhotoImage.load()`** (after decoding, before storing) for defensive cancellation hygiene.

10. **Add `// NSCache is thread-safe; @unchecked Sendable is safe here.` comment** to `PhotoMemoryCache` declaration.

11. **Add defensive `isStarting = false` / `isLoading = false` reset before calling success callbacks** in `CullChoiceView.beginCull()` and `SessionSetupView.startSession()`.

12. **Simplify manual `Binding(get:set:)` alert patterns** in `ResultsView` and `CompletionView` into an `Optional` extension or a separate `Bool` flag for clarity.
