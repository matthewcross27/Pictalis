# Instant Comparison Transitions + Start Over Button

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the loading spinner between comparisons by prefetching the next pair in the background, and add a "Start Over" button to the completion screen.

**Architecture:** `ComparisonView` fires a background `Task` to fetch the next pair as soon as the current pair appears on screen. When the user taps a winner, the submit and session-status requests run in parallel (`async let`); as soon as the submit completes the prefetched pair is displayed immediately with no loading state. `CompletionView` gains an `onStartOver` callback that `ContentView` handles by resetting `appState = .setup`.

**Tech Stack:** Swift, SwiftUI, `async let`, `Task`, `@State`

---

## File Map

| File | Change |
|---|---|
| `ios/Sources/App/Views/ComparisonView.swift` | Parallelize submit+status; add prefetch state, `startPrefetch()`, `onChange` trigger, and updated `choose()`/`fetchNextPair()` |
| `ios/Sources/App/Views/CompletionView.swift` | Add `onStartOver: () -> Void` parameter and button |
| `ios/Sources/App/ContentView.swift` | Pass `onStartOver` callback to `CompletionView` |

---

### Task 1: Parallelize submit + session-status in `choose()`

**Why this first:** Even without prefetch, overlapping these two calls reduces per-transition latency from ~300–500 ms to ~150–250 ms. Note: because `APIClient` is `@MainActor`, both `async let` child tasks still serialize through the main actor executor — but both HTTP requests are in-flight simultaneously (both `URLSession` round-trips overlap), so the wall-clock benefit is real even though they aren't running on separate threads.

**Files:**
- Modify: `ios/Sources/App/Views/ComparisonView.swift:155-176`

- [ ] **Step 1: Read the current `choose(winner:)` method**

```
ios/Sources/App/Views/ComparisonView.swift lines 155–176
```
Confirm it looks like: `submitComparison` await → `sessionStatus` await (sequential).

- [ ] **Step 2: Replace `choose(winner:)` with the parallel version**

Replace the entire method (lines 155–176) with:

```swift
private func choose(winner: PairPhoto) async {
    guard let pair else { return }
    isSubmitting = true
    do {
        async let submitResult = api.submitComparison(
            comparisonId: pair.comparisonId,
            winnerId: winner.id
        )
        async let statusResult = api.sessionStatus(sessionId: sessionId)

        _ = try await submitResult
        comparisonCount += 1

        if let status = try? await statusResult, status.isComplete {
            isSubmitting = false
            onComplete(status.totalComparisons)
            return
        }
    } catch {
        print("Submit failed: \(error)")
    }
    isSubmitting = false
    self.pair = nil
    await fetchNextPair()
}
```

- [ ] **Step 3: Build in Xcode — confirm zero errors**

`Cmd+B` in Xcode. Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add ios/Sources/App/Views/ComparisonView.swift
git commit -m "perf(ios): parallelize submit + session-status in choose()"
```

---

### Task 2: Add prefetch state and `startPrefetch()` to `ComparisonView`

**Files:**
- Modify: `ios/Sources/App/Views/ComparisonView.swift`

- [ ] **Step 1: Add two `@State` properties after the existing state declarations (after line 16)**

```swift
@State private var prefetchedPair: NextPairResponse?
@State private var prefetchTask: Task<Void, Never>?
```

The block of `@State` properties should now end with these two lines.

- [ ] **Step 2: Add `startPrefetch()` in the `// MARK: - Private` section, before `choose(winner:)`**

```swift
private func startPrefetch() {
    prefetchTask?.cancel()
    prefetchedPair = nil
    prefetchTask = Task {
        guard let response = try? await api.nextPair(sessionId: sessionId) else { return }
        guard !Task.isCancelled else { return }
        prefetchedPair = response
    }
}
```

- [ ] **Step 3: Trigger prefetch when a pair is displayed**

In `body`, after `.task { await fetchNextPair() }` (line 81), add:

```swift
.onChange(of: pair?.comparisonId) { _, newId in
    if newId != nil { startPrefetch() }
}
```

`UUID` is `Equatable`, so `UUID?` works as the `onChange` value.

- [ ] **Step 4: Cancel the prefetch task when the view disappears**

`prefetchTask` is an unstructured `Task` — SwiftUI does not automatically cancel it when `ComparisonView` is torn down (unlike tasks created with `.task {}`). Add `.onDisappear` immediately after the `.onChange` modifier:

```swift
.onDisappear {
    prefetchTask?.cancel()
    prefetchedPair = nil
}
```

This ensures that navigating to "Skip to Results," the completion screen, or "Start Over" does not leave a dangling network request writing into deallocated state.

- [ ] **Step 5: Build in Xcode — confirm zero errors**

`Cmd+B`. Expected: Build Succeeded.

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/App/Views/ComparisonView.swift
git commit -m "feat(ios): add prefetch state and startPrefetch() to ComparisonView"
```

---

### Task 3: Use prefetched pair for zero-latency transition

**Files:**
- Modify: `ios/Sources/App/Views/ComparisonView.swift`

- [ ] **Step 1: Replace the entire `choose(winner:)` method with the final version**

This replaces the method written in Task 1 in full. Three fixes are applied here over the Task 1 version: (a) the completion branch now cancels `prefetchTask` before calling `onComplete`, (b) the catch block clears `prefetchedPair` so a failed submit never silently advances the UI, and (c) the success path uses the prefetched pair instead of calling `fetchNextPair`.

Find and replace the entire `choose(winner:)` method:

```swift
private func choose(winner: PairPhoto) async {
    guard let pair else { return }
    isSubmitting = true
    do {
        async let submitResult = api.submitComparison(
            comparisonId: pair.comparisonId,
            winnerId: winner.id
        )
        async let statusResult = api.sessionStatus(sessionId: sessionId)

        _ = try await submitResult
        comparisonCount += 1

        if let status = try? await statusResult, status.isComplete {
            prefetchTask?.cancel()
            prefetchedPair = nil
            isSubmitting = false
            onComplete(status.totalComparisons)
            return
        }
    } catch {
        print("Submit failed: \(error)")
        prefetchedPair = nil
        prefetchTask?.cancel()
        isSubmitting = false
        self.pair = nil
        await fetchNextPair()
        return
    }
    isSubmitting = false
    if let next = prefetchedPair {
        currentStage = next.stage
        self.pair = next
        prefetchedPair = nil
        startPrefetch()
    } else {
        self.pair = nil
        await fetchNextPair()
    }
}
```

- [ ] **Step 2: Cancel the prefetch when session completes inside `fetchNextPair()`**

Find `fetchNextPair()` (currently ends around line 206). Replace the entire method with:

```swift
private func fetchNextPair(retryCount: Int = 0) async {
    isLoading = true
    errorMessage = nil
    do {
        let response = try await api.nextPair(sessionId: sessionId)
        currentStage = response.stage
        pair = response
        isLoading = false
    } catch APIError.httpError(statusCode: 422, _) {
        if let status = try? await api.sessionStatus(sessionId: sessionId),
           status.isComplete {
            prefetchTask?.cancel()
            prefetchedPair = nil
            isLoading = false
            onComplete(status.totalComparisons)
            return
        }
        guard retryCount < 30 else {
            errorMessage = "Not enough photos available. Please go back and try again."
            isLoading = false
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await fetchNextPair(retryCount: retryCount + 1)
    } catch {
        errorMessage = "Failed to load next pair: \(error.localizedDescription)"
        isLoading = false
    }
}
```

- [ ] **Step 3: Build in Xcode — confirm zero errors**

`Cmd+B`. Expected: Build Succeeded.

- [ ] **Step 4: Manual smoke test**

Run app on simulator or device:
1. Pick 15–20 photos and start a session.
2. Make 10 rapid comparisons — verify no loading spinner appears between taps (after the very first pair loads).
3. Continue until session completion — verify the app navigates to the completion screen correctly and doesn't get stuck on a blank comparison screen.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Views/ComparisonView.swift
git commit -m "feat(ios): zero-latency transitions via prefetched next pair"
```

---

### Task 4: Add "Start Over" button to `CompletionView`

**Files:**
- Modify: `ios/Sources/App/Views/CompletionView.swift`
- Modify: `ios/Sources/App/ContentView.swift`

- [ ] **Step 1: Add `onStartOver` parameter to `CompletionView`**

In `CompletionView.swift`, find:

```swift
var onSeeFullRankings: () -> Void
```

Replace with:

```swift
var onSeeFullRankings: () -> Void
var onStartOver: () -> Void
```

- [ ] **Step 2: Add the "Start Over" button in `CompletionView.body`**

Find the `VStack(spacing: 12)` that contains the "See Full Rankings" button:

```swift
Button("See Full Rankings") { onSeeFullRankings() }
    .font(.subheadline)
```

Replace with:

```swift
Button("See Full Rankings") { onSeeFullRankings() }
    .font(.subheadline)

Button("Start Over") { onStartOver() }
    .font(.subheadline)
    .foregroundStyle(.secondary)
```

- [ ] **Step 3: Pass `onStartOver` in `ContentView`**

In `ContentView.swift`, find the `.complete` case:

```swift
case .complete(let sessionId, let totalComparisons):
    CompletionView(
        sessionId: sessionId,
        totalComparisons: totalComparisons,
        onSeeFullRankings: {
            appState = .results(sessionId: sessionId)
        }
    )
```

Replace with:

```swift
case .complete(let sessionId, let totalComparisons):
    CompletionView(
        sessionId: sessionId,
        totalComparisons: totalComparisons,
        onSeeFullRankings: {
            appState = .results(sessionId: sessionId)
        },
        onStartOver: {
            appState = .setup
        }
    )
```

- [ ] **Step 4: Build in Xcode — confirm zero errors**

`Cmd+B`. Expected: Build Succeeded.

- [ ] **Step 5: Manual smoke test**

1. Complete a session.
2. Tap "Start Over" — verify the app returns to the photo-picker setup screen with no leftover state.

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/App/Views/CompletionView.swift ios/Sources/App/ContentView.swift
git commit -m "feat(ios): add Start Over button to CompletionView"
```
