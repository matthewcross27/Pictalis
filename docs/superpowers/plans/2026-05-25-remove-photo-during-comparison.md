# Remove Photo During Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small red trash-icon button to each photo card in the comparison view. Tapping it marks the photo as suppressed (excluded from future comparisons) and immediately loads the next pair.

**Architecture:** A new `remove-photo` Supabase Edge Function sets `is_suppressed = true` on a photo after validating it belongs to the caller's session. The iOS `APIClient` gets a `removePhoto(sessionId:photoId:)` method. `ComparisonView.photoButton()` gains a red trash overlay button; on tap it calls the API, cancels any prefetch, and calls `fetchNextPair()`. No migration is needed — `is_suppressed` already exists on the `photos` table and `next-pair` already filters it out.

**Tech Stack:** SwiftUI (iOS), TypeScript (Deno), Supabase Edge Functions

---

## File Map

| File | Change |
|------|--------|
| `backend/supabase/functions/remove-photo/index.ts` | New edge function: set `is_suppressed = true` |
| `ios/Sources/App/Services/APIClient.swift` | Add `removePhoto(sessionId:photoId:)` method |
| `ios/Sources/App/Views/ComparisonView.swift` | Add red trash button overlay on each photo card |

---

### Task 1: Create `remove-photo` edge function

**Files:**
- Create: `backend/supabase/functions/remove-photo/index.ts`

- [ ] **Step 1: Create the function**

```ts
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const Body = z.object({
  session_id: z.string().uuid(),
  photo_id:   z.string().uuid(),
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } },
  );

  let body: unknown;
  try { body = await req.json(); }
  catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const parsed = Body.safeParse(body);
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { session_id, photo_id } = parsed.data;

  // RLS ensures the photo belongs to a session owned by the calling user.
  const { data, error } = await supabase
    .from('photos')
    .update({ is_suppressed: true })
    .eq('id', photo_id)
    .eq('session_id', session_id)
    .eq('is_suppressed', false) // idempotency guard
    .select('id')
    .single();

  if (error || !data) {
    return new Response(JSON.stringify({ error: 'Photo not found or already removed' }), {
      status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(
    JSON.stringify({ photo_id: data.id }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
  );
});
```

- [ ] **Step 2: Deploy**

```bash
supabase functions deploy remove-photo --project-ref <your-project-ref>
```

Expected: function deployed successfully.

- [ ] **Step 3: Smoke-test with curl**

```bash
# Replace TOKEN and IDs with real values from a test session.
curl -X POST https://<project-ref>.supabase.co/functions/v1/remove-photo \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"<session-uuid>","photo_id":"<photo-uuid>"}'
```

Expected: `{"photo_id":"<photo-uuid>"}` with HTTP 200. Calling again with the same photo returns 404 (already suppressed).

- [ ] **Step 4: Commit**

```bash
git add backend/supabase/functions/remove-photo/index.ts
git commit -m "feat(backend): add remove-photo edge function to suppress a photo during comparison"
```

---

### Task 2: Add `removePhoto` to `APIClient`

**Files:**
- Modify: `ios/Sources/App/Services/APIClient.swift`

- [ ] **Step 1: Add the method after `submitComparison`**

Open `ios/Sources/App/Services/APIClient.swift`. After the `submitComparison` method (currently ending around line 100), add:

```swift
// MARK: - remove-photo
// POST { session_id, photo_id } → { photo_id }

func removePhoto(sessionId: UUID, photoId: UUID) async throws {
    let url = functionsBase.appending(path: "remove-photo")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "session_id": sessionId.uuidString.lowercased(),
        "photo_id":   photoId.uuidString.lowercased(),
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    try validate(response, data: data)
}
```

- [ ] **Step 2: Build to verify no compile errors**

```bash
cd /Users/mccro/claudeProjects/Pictalis && xcodebuild -project ios/picHelper.xcodeproj -scheme picHelper build 2>&1 | grep -E "(error:|BUILD)"
```

Expected: `BUILD SUCCEEDED` with no errors.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Services/APIClient.swift
git commit -m "feat(ios): add APIClient.removePhoto for suppressing a photo during comparison"
```

---

### Task 3: Add remove button to `ComparisonView`

**Files:**
- Modify: `ios/Sources/App/Views/ComparisonView.swift`

The `photoButton(photo:)` view builder already has one overlay button (the expand/fullscreen button in the top-right). We add a second overlay button: a small red trash icon in the bottom-left corner.

- [ ] **Step 1: Add `isRemoving` state at the top of `ComparisonView`**

In `ComparisonView`, after the existing `@State` declarations (around line 19), add:

```swift
@State private var isRemoving = false
```

- [ ] **Step 2: Add the remove button overlay inside `photoButton(photo:)`**

The existing `photoButton` has an `.overlay(alignment: .topTrailing)` for the expand button (around line 165). Add a second overlay **after** the topTrailing one, **before** the closing `.clipped()` / `.clipShape`:

```swift
.overlay(alignment: .bottomLeading) {
    Button {
        Task { @MainActor in await remove(photo: photo) }
    } label: {
        Image(systemName: "trash")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.red.opacity(0.85))
            .clipShape(Capsule())
    }
    .padding(8)
}
```

The full updated `photoButton` body should look like:

```swift
@ViewBuilder
private func photoButton(photo: PairPhoto) -> some View {
    Button {
        Task { @MainActor in await choose(winner: photo) }
    } label: {
        Color.grainPaper
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(Color.secondaryText)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(Color.secondaryText)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button {
                    fullscreenPhoto = photo
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.photoOverlay)
                        .clipShape(Capsule())
                }
                .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                Button {
                    Task { @MainActor in await remove(photo: photo) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                }
                .padding(8)
            }
    }
    .buttonStyle(PhotoTapStyle())
    .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
}
```

- [ ] **Step 3: Implement `remove(photo:)` private method**

Add after the existing `choose(winner:)` method in `ComparisonView`:

```swift
private func remove(photo: PairPhoto) async {
    guard !isRemoving, !isSubmitting else { return }
    isRemoving = true
    prefetchTask?.cancel()
    prefetchedPair = nil
    do {
        try await api.removePhoto(sessionId: sessionId, photoId: photo.id)
    } catch {
        print("Remove failed: \(error)")
        isRemoving = false
        return
    }
    isRemoving = false
    self.pair = nil
    await fetchNextPair()
}
```

- [ ] **Step 4: Disable the remove buttons while submitting or removing**

The existing `VStack` containing the two photo buttons already has `.disabled(isSubmitting)`. Update it to also disable during removal:

Replace:
```swift
.opacity(isSubmitting ? 0.7 : 1.0)
.disabled(isSubmitting)
```

With:
```swift
.opacity((isSubmitting || isRemoving) ? 0.7 : 1.0)
.disabled(isSubmitting || isRemoving)
```

- [ ] **Step 5: Build to verify no compile errors**

```bash
cd /Users/mccro/claudeProjects/Pictalis && xcodebuild -project ios/picHelper.xcodeproj -scheme picHelper build 2>&1 | grep -E "(error:|BUILD)"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Manual test in simulator**

Run the app in the simulator. In the comparison view:
1. Verify a small red trash button appears in the bottom-left of each photo card.
2. Tap the trash button — the pair should disappear and a new pair loads.
3. Tap the expand button — fullscreen view still works.
4. Tap a photo to choose a winner — Elo update still works.
5. Verify the removed photo never reappears in future pairs.

- [ ] **Step 7: Commit**

```bash
git add ios/Sources/App/Views/ComparisonView.swift
git commit -m "feat(ios): add red remove button to photo cards in ComparisonView"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Small red remove button visible on each photo during comparison
- [x] Tapping remove suppresses the photo server-side and fetches a new pair
- [x] Removed photo never appears in future comparisons (is_suppressed filter in next-pair)
- [x] Button is disabled during submission or another removal to prevent double-tap
- [x] Expand / fullscreen button unaffected
- [x] No migration needed — `is_suppressed` already exists

**Placeholder scan:** No placeholders — all code is complete.

**Type consistency:** `APIClient.removePhoto(sessionId:photoId:)` takes `UUID, UUID` — matches `PairPhoto.id: UUID` used at the call site. `isRemoving: Bool` state consistent across guard, disable, and method body.
