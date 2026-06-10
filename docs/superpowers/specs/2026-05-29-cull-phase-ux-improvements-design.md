# Cull Phase UX Improvements — Design

**Date:** 2026-05-29  
**Status:** Approved  
**Scope:** `CullView.swift` only

---

## Problem

Three UX issues in the current cull phase:

1. After a swipe, the entire screen (including bottom buttons) is replaced by a full-screen spinner while waiting for the next card. Buttons disappear, giving the impression the app is locked.
2. Image loading time is slow because the fetch for the next card doesn't start until after the submit API call returns — two sequential network waits before anything is visible.
3. The "remaining" count in the top bar increases over time as new photos are added to the queue by the background upload, which is confusing to users.

---

## Design

### 1. Layout Restructure — Static Bottom Buttons

The `body` conditional is restructured so `bottomButtons` renders independently of `isLoading`. When a card exists, buttons are always visible. The card area becomes a fixed region that shows either:
- The `AsyncImage` (normal state)
- A contained `ProgressView` placeholder (loading state, card area only)

Full-screen takeovers are reserved for the terminal states only: `errorMessage` and `card.done`.

`isLoading` no longer gates `bottomButtons` — it only affects the card slot.

### 2. Prefetch Next Card — Eliminate API Wait Between Swipes

**New state:**
```swift
@State private var nextCard: CullCard?
```

**Prefetch trigger:** After `fetchNext()` successfully sets `card`, immediately fire a detached background task that calls `api.nextCull` and stores the result in `nextCard`. No loading indicators change — this is silent.

**On swipe (`commitDecision`):**
1. Animate current card off screen.
2. If `nextCard` is ready: set `card = nextCard`, clear `nextCard`, start a new background prefetch for the card after that.
3. Fire `api.submitCull` in the background (fire-and-forget, parallel with step 2).
4. If `nextCard` is not ready yet: show card-area loading placeholder and fall back to fetching normally.

**On submit error:** Since the user may already be viewing card N+1 when the submit for card N fails, retry automatically up to 2 times before surfacing an error. If all retries fail, show a small inline error banner above the bottom buttons ("Couldn't save last decision — tap to retry") with a retry action that re-fires the same submit call. Do not navigate away or block the UI.

**Result:** In the happy path, the gap between swipes is reduced from *(submit latency + fetch latency + image download)* to *(image download)* only.

**Ordering note:** The prefetch "peek" runs before the submit for the current card resolves. Since cull cards are pre-queued and a decision on card N does not change which card N+1 is, this is safe.

### 3. Remaining Count — Local Countdown from First Snapshot

**New state:**
```swift
@State private var remainingSnapshot: Int?
@State private var localDecisionsMade: Int = 0
```

On the first successful `fetchNext()` call, `remainingSnapshot` is set to `card.cardsRemaining` and never updated again from the API.

Each call to `commitDecision` increments `localDecisionsMade` by 1.

The top bar displays:
```
(remainingSnapshot - localDecisionsMade) remaining
```

This means the count only ever decreases, regardless of how many new photos the background upload adds to the queue.

---

## Files Changed

| File | Change |
|------|--------|
| `ios/Sources/App/Views/CullView.swift` | All changes — layout, prefetch, remaining count |

No other files change. The `APIClient` interface is unchanged; `nextCull` is already the correct call for both fetch and prefetch.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Prefetch returns `done: true` | Treat as normal done — call `onComplete()` when that card is displayed |
| Submit fails after 2 retries | Show inline error banner above buttons, allow manual retry; do not navigate away |
| User swipes faster than prefetch returns | Fall back to card-area loading placeholder |
| Upload adds photos after snapshot | Ignored — display uses local countdown only |
| `remainingSnapshot` not yet set (very first load) | Top bar shows nothing (same as current `nil` guard) |
