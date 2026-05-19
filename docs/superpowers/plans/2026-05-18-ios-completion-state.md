# iOS Completion State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS app detects when the backend marks a session complete (stage = 'complete') and automatically navigates to a "Your favorites are ready!" screen, replacing the need to manually tap "See Results."

**Architecture:** `ComparisonView` polls the new `session-status` Edge Function after each comparison. When `isComplete == true`, it calls an `onComplete` callback that drives `ContentView`'s state machine to a new `.complete` case, showing a `CompletionView` with the top-10 ranked photos and an export-all CTA. A "Skip to Results" escape hatch replaces the old "See Results" button for mid-session manual exit. `ResultsView` gains a stage badge from the updated `results` response. Tests cover new model decoding only — UI is verified manually on simulator.

**Tech Stack:** SwiftUI, async/await, URLSession

---

## Scope Note

This plan depends on the backend changes from `2026-05-18-multi-stage-ranking.md`:
- `next-pair` returns `stage` field
- `results` returns `session: { stage, is_complete }`
- `session-status` Edge Function exists and returns `{ stage, is_complete, top_photo_count, total_comparisons }`

Build and deploy that plan before running this one. The iOS changes are backward-compatible if the backend isn't updated yet — optional model fields default to nil/false.

---

## File Map

```
ios/Sources/App/
├── Models/
│   └── Models.swift                    (modify: add SessionStatus, SessionInfo; update NextPairResponse, ResultsResponse; fix RankedPhoto.qualityFlags)
├── Services/
│   └── APIClient.swift                 (modify: add sessionStatus(); update results() return type)
├── Views/
│   ├── ComparisonView.swift            (modify: poll status after submit, onComplete callback, stage label, rename button)
│   ├── CompletionView.swift            (new: celebration screen with top-10 grid + export-all)
│   └── ResultsView.swift              (modify: stage badge from session info)
├── ContentView.swift                   (modify: add .complete AppState, wire CompletionView)
└── Tests/
    └── picHelperTests.swift            (modify: add SessionStatus decode test; existing tests still pass)
```

---

### Task 1: Update models

**Files:**
- Modify: `ios/Sources/App/Models/Models.swift`

Four changes:
1. Add `SessionStatus` — decoded from the new `session-status` Edge Function response
2. Add `SessionInfo` — nested in the updated `results` response
3. Update `ResultsResponse` to include `session: SessionInfo?`
4. Update `NextPairResponse` to include `stage: String?`
5. Fix `RankedPhoto.qualityFlags` — the field type `[String]?` fails to decode JSONB objects from Postgres. Since quality flags are never displayed in the UI, remove the property entirely (the JSON key is silently ignored by `JSONDecoder`).

- [ ] **Step 1: Write failing model test for SessionStatus**

Append to `ios/Tests/picHelperTests.swift` (inside the `ModelsTests` class, after the last test):

```swift
func testSessionStatusDecodes() throws {
    let json = """
    {"stage":"stage2","is_complete":false,"top_photo_count":20,"total_comparisons":47}
    """.data(using: .utf8)!
    let status = try decoder.decode(SessionStatus.self, from: json)
    XCTAssertEqual(status.stage, "stage2")
    XCTAssertFalse(status.isComplete)
    XCTAssertEqual(status.topPhotoCount, 20)
    XCTAssertEqual(status.totalComparisons, 47)
}

func testResultsResponseDecodesWithSession() throws {
    let json = """
    {"photos":[{"id":"11112222-e29b-41d4-a716-446655440000","storage_path":"uid/sid/a.jpg","thumbnail_path":null,"elo_rating":1350.0,"uncertainty":null,"comparison_count":5,"is_suppressed":false,"cluster_id":null,"signed_url":"https://example.com/a.jpg"}],"session":{"stage":"complete","is_complete":true}}
    """.data(using: .utf8)!
    let response = try decoder.decode(ResultsResponse.self, from: json)
    XCTAssertEqual(response.photos.count, 1)
    XCTAssertEqual(response.session?.stage, "complete")
    XCTAssertEqual(response.session?.isComplete, true)
}

func testNextPairResponseDecodesWithStage() throws {
    let json = """
    {"comparison_id":"aaaabbbb-e29b-41d4-a716-446655440000","stage":"stage2","photo_a":{"id":"11112222-e29b-41d4-a716-446655440000","storage_path":"uid/sid/a.jpg","thumbnail_path":null,"elo_rating":1200.0,"comparison_count":0,"signed_url":"https://example.com/a.jpg"},"photo_b":{"id":"33334444-e29b-41d4-a716-446655440000","storage_path":"uid/sid/b.jpg","thumbnail_path":null,"elo_rating":1200.0,"comparison_count":0,"signed_url":"https://example.com/b.jpg"}}
    """.data(using: .utf8)!
    let response = try decoder.decode(NextPairResponse.self, from: json)
    XCTAssertEqual(response.stage, "stage2")
}
```

- [ ] **Step 2: Run tests in Xcode — confirm 3 new failures**

`⌘U`. Expected: 3 new failures — `SessionStatus`, `ResultsResponse`, `NextPairResponse` types missing or wrong.

- [ ] **Step 3: Replace Models.swift**

Replace `ios/Sources/App/Models/Models.swift` with:

```swift
import Foundation

// MARK: - create-session

struct CreateSessionResponse: Decodable {
    let session: APISession
}

struct APISession: Decodable {
    let id: UUID
    let createdAt: String
    let expiresAt: String
    let status: String
    let photoCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case status
        case photoCount = "photo_count"
    }
}

// MARK: - register-photo

struct RegisterPhotoResponse: Decodable {
    let photo: RegisteredPhoto
}

struct RegisteredPhoto: Decodable {
    let id: UUID
    let sessionId: UUID
    let storagePath: String
    let eloRating: Double
    let comparisonCount: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case storagePath = "storage_path"
        case eloRating = "elo_rating"
        case comparisonCount = "comparison_count"
        case createdAt = "created_at"
    }
}

// MARK: - next-pair

struct NextPairResponse: Decodable {
    let comparisonId: UUID
    let photoA: PairPhoto
    let photoB: PairPhoto
    let stage: String?  // nil when backend hasn't been updated yet

    enum CodingKeys: String, CodingKey {
        case comparisonId = "comparison_id"
        case photoA = "photo_a"
        case photoB = "photo_b"
        case stage
    }
}

struct PairPhoto: Decodable, Identifiable {
    let id: UUID
    let storagePath: String
    let thumbnailPath: String?
    let eloRating: Double
    let comparisonCount: Int
    let signedUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case thumbnailPath = "thumbnail_path"
        case eloRating = "elo_rating"
        case comparisonCount = "comparison_count"
        case signedUrl = "signed_url"
    }
}

// MARK: - submit-comparison

struct SubmitComparisonResponse: Decodable {
    let winnerId: UUID
    let loserId: UUID
    let winnerNewRating: Double
    let loserNewRating: Double

    enum CodingKeys: String, CodingKey {
        case winnerId = "winner_id"
        case loserId = "loser_id"
        case winnerNewRating = "winner_new_rating"
        case loserNewRating = "loser_new_rating"
    }
}

// MARK: - results

struct ResultsResponse: Decodable {
    let photos: [RankedPhoto]
    let session: SessionInfo?
}

struct SessionInfo: Decodable {
    let stage: String
    let isComplete: Bool

    enum CodingKeys: String, CodingKey {
        case stage
        case isComplete = "is_complete"
    }
}

struct RankedPhoto: Decodable, Identifiable {
    let id: UUID
    let storagePath: String
    let thumbnailPath: String?
    let eloRating: Double
    let uncertainty: Double?
    let comparisonCount: Int
    let isSuppressed: Bool
    let clusterId: String?
    let signedUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case thumbnailPath = "thumbnail_path"
        case eloRating = "elo_rating"
        case uncertainty
        case comparisonCount = "comparison_count"
        case isSuppressed = "is_suppressed"
        case clusterId = "cluster_id"
        case signedUrl = "signed_url"
        // quality_flags omitted: JSONB object type not displayed in UI;
        // JSONDecoder silently skips JSON keys not present in the struct.
    }
}

// MARK: - session-status

struct SessionStatus: Decodable {
    let stage: String
    let isComplete: Bool
    let topPhotoCount: Int
    let totalComparisons: Int

    enum CodingKeys: String, CodingKey {
        case stage
        case isComplete = "is_complete"
        case topPhotoCount = "top_photo_count"
        case totalComparisons = "total_comparisons"
    }
}

// MARK: - Errors

struct APIErrorResponse: Decodable {
    let error: String
}
```

- [ ] **Step 4: Run all tests — confirm all pass**

`⌘U`. Expected: all existing tests pass + 3 new tests pass (total increases by 3).

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Models/Models.swift ios/Tests/picHelperTests.swift
git commit -m "feat(ios): add SessionStatus and SessionInfo models; add stage to NextPairResponse and ResultsResponse"
```

---

### Task 2: Update APIClient

**Files:**
- Modify: `ios/Sources/App/Services/APIClient.swift`

Two changes:
1. Add `sessionStatus(sessionId:) async throws -> SessionStatus`
2. Change `results()` return type from `[RankedPhoto]` to `ResultsResponse`

- [ ] **Step 1: Add sessionStatus method**

In `APIClient.swift`, find the `// MARK: - results` comment. Insert this block immediately before it:

```swift
    // MARK: - session-status
    // GET ?session_id=... → { stage, is_complete, top_photo_count, total_comparisons }

    func sessionStatus(sessionId: UUID) async throws -> SessionStatus {
        var comps = URLComponents(url: functionsBase.appending(path: "session-status"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "session_id", value: sessionId.uuidString.lowercased())]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(SessionStatus.self, from: data)
    }

```

- [ ] **Step 2: Update results() return type**

Find the `results` method signature and its return line:

```swift
    func results(sessionId: UUID, limit: Int = 20) async throws -> [RankedPhoto] {
```

Replace with:

```swift
    func results(sessionId: UUID, limit: Int = 20) async throws -> ResultsResponse {
```

Then find the return line inside the method:

```swift
        return try decoder.decode(ResultsResponse.self, from: data).photos
```

Replace with:

```swift
        return try decoder.decode(ResultsResponse.self, from: data)
```

- [ ] **Step 3: Build — expect compile errors in ResultsView**

`⌘B`. Expected: build fails because `ResultsView.fetchResults()` assigns `api.results(...)` (now `ResultsResponse`) directly to `photos` (`[RankedPhoto]`). The next task fixes this.

- [ ] **Step 4: Commit (with build error note)**

```bash
git add ios/Sources/App/Services/APIClient.swift
git commit -m "feat(ios): add sessionStatus() and update results() to return ResultsResponse"
```

---

### Task 3: Update ComparisonView

**Files:**
- Modify: `ios/Sources/App/Views/ComparisonView.swift`

Changes:
- Replace `var onFinish: () -> Void` with two named callbacks: `var onSkipToResults: () -> Void` and `var onComplete: () -> Void`
- After each successful `submitComparison`, call `api.sessionStatus(sessionId:)` — if `isComplete`, call `onComplete()` and return (no `fetchNextPair`)
- Read `stage` from `NextPairResponse` and store in `@State var currentStage: String?`
- Show stage subtitle in the toolbar: "Broad discovery" / "Refining top photos" / "Choosing between similar shots"
- Rename "See Results" → "Skip to Results"

- [ ] **Step 1: Replace ComparisonView.swift**

Replace `ios/Sources/App/Views/ComparisonView.swift` with:

```swift
import SwiftUI

struct ComparisonView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    @ObservedObject var uploadService: UploadService
    var onSkipToResults: () -> Void
    var onComplete: () -> Void

    @State private var pair: NextPairResponse?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var comparisonCount = 0
    @State private var currentStage: String?
    @State private var fullscreenPhoto: PairPhoto?

    var body: some View {
        VStack(spacing: 0) {
            if !uploadService.isComplete {
                HStack {
                    ProgressView(
                        value: Double(uploadService.completed),
                        total: Double(max(uploadService.total, 1))
                    )
                    Text("\(uploadService.completed)/\(uploadService.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
            }

            if isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading photos…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let errorMessage {
                Spacer()
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
                Spacer()
            } else if let pair {
                Spacer()
                VStack(spacing: 8) {
                    photoButton(photo: pair.photoA)
                    photoButton(photo: pair.photoB)
                }
                .padding(.horizontal, 8)
                .disabled(isSubmitting)
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(comparisonCount) comparisons")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if let stage = currentStage {
                        Text(stageLabel(stage))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Skip to Results") { onSkipToResults() }
                    .font(.subheadline)
                    .disabled(comparisonCount < 1)
            }
            .padding()
        }
        .task { await fetchNextPair() }
        .fullScreenCover(item: $fullscreenPhoto) { photo in
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        ProgressView().tint(.white)
                    }
                }
            }
            .onTapGesture { fullscreenPhoto = nil }
        }
    }

    // MARK: - Private

    private func stageLabel(_ stage: String) -> String {
        switch stage {
        case "stage1": return "Broad discovery"
        case "stage2": return "Refining top photos"
        case "stage3": return "Choosing between similar shots"
        default: return ""
        }
    }

    @ViewBuilder
    private func photoButton(photo: PairPhoto) -> some View {
        Button {
            Task { @MainActor in await choose(winner: photo) }
        } label: {
            Color(.secondarySystemBackground)
                .frame(maxWidth: .infinity)
                .aspectRatio(4/3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(8)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func choose(winner: PairPhoto) async {
        guard let pair else { return }
        isSubmitting = true
        do {
            _ = try await api.submitComparison(
                comparisonId: pair.comparisonId,
                winnerId: winner.id
            )
            comparisonCount += 1

            // Check for completion after each comparison. Non-fatal if status call fails.
            if let status = try? await api.sessionStatus(sessionId: sessionId),
               status.isComplete {
                onComplete()
                return
            }
        } catch {
            print("Submit failed: \(error)")
        }
        isSubmitting = false
        self.pair = nil
        await fetchNextPair()
    }

    private func fetchNextPair(retryCount: Int = 0) async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await api.nextPair(sessionId: sessionId)
            pair = response
            currentStage = response.stage
            isLoading = false
        } catch APIError.httpError(statusCode: 422, _) {
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
}
```

- [ ] **Step 2: Build — expect compile errors in ContentView**

`⌘B`. Expected: build fails because `ContentView` still passes a single trailing closure (`onFinish`) to `ComparisonView`, but `ComparisonView` now requires `onSkipToResults` and `onComplete`. Fixed in the next task.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Views/ComparisonView.swift
git commit -m "feat(ios): poll session status after each comparison; show stage label; rename escape button"
```

---

### Task 4: Create CompletionView

**Files:**
- Create: `ios/Sources/App/Views/CompletionView.swift`

Shows "Your favorites are ready!" with the top-10 ranked photos in a 3-column grid, a primary "Export All Favorites" button, and a secondary "See Full Rankings" link that navigates to `ResultsView`.

- [ ] **Step 1: Create CompletionView.swift**

Create `ios/Sources/App/Views/CompletionView.swift`:

```swift
import SwiftUI
import Photos

struct CompletionView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    let totalComparisons: Int
    var onSeeFullRankings: () -> Void

    @State private var photos: [RankedPhoto] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportAlertMessage: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.yellow)

                        Text("Your favorites are ready!")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text("\(totalComparisons) comparisons · \(photos.count) photos ranked")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                    .padding(.horizontal)

                    // Top photos grid
                    if isLoading {
                        ProgressView()
                            .frame(height: 200)
                    } else {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(photos) { photo in
                                AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 110)
                                            .clipped()
                                    default:
                                        Color(.secondarySystemBackground)
                                            .frame(height: 110)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal, 4)
                    }

                    // Actions
                    VStack(spacing: 12) {
                        Button(action: exportAll) {
                            Group {
                                if isExporting {
                                    ProgressView()
                                } else {
                                    Text("Export All Favorites")
                                        .font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(photos.isEmpty || isExporting)

                        Button("See Full Rankings") {
                            onSeeFullRankings()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await fetchTopPhotos() }
        .alert("Saved to Photos", isPresented: Binding(
            get: { exportAlertMessage != nil },
            set: { if !$0 { exportAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    // MARK: - Private

    private func fetchTopPhotos() async {
        isLoading = true
        do {
            let response = try await api.results(sessionId: sessionId, limit: 10)
            photos = response.photos
        } catch {
            print("Failed to fetch top photos: \(error)")
        }
        isLoading = false
    }

    private func exportAll() {
        Task { @MainActor in
            isExporting = true
            var saved = 0
            for photo in photos {
                guard let url = URL(string: photo.signedUrl) else { continue }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let image = UIImage(data: data) else { continue }
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.creationRequestForAsset(from: image)
                    }
                    saved += 1
                } catch {
                    print("Export failed: \(error)")
                }
            }
            isExporting = false
            if saved > 0 {
                let noun = saved == 1 ? "photo" : "photos"
                exportAlertMessage = "\(saved) \(noun) saved to your library."
            }
        }
    }
}
```

- [ ] **Step 2: Build — CompletionView compiles**

`⌘B`. Expected: CompletionView builds (ContentView still has unresolved errors — fixed next).

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/Views/CompletionView.swift
git commit -m "feat(ios): add CompletionView with top-10 grid and export-all"
```

---

### Task 5: Update ContentView

**Files:**
- Modify: `ios/Sources/App/ContentView.swift`

Add `.complete(sessionId: UUID, totalComparisons: Int)` to `AppState`. Wire `ComparisonView`'s new `onComplete` callback to transition to `.complete`. Show `CompletionView` for `.complete`. Update animation value.

- [ ] **Step 1: Replace ContentView.swift**

Replace `ios/Sources/App/ContentView.swift` with:

```swift
import SwiftUI

enum AppState {
    case setup
    case comparing(sessionId: UUID, upload: UploadService)
    case complete(sessionId: UUID, totalComparisons: Int)
    case results(sessionId: UUID)
}

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var api: APIClient

    @State private var appState: AppState = .setup
    @State private var sessionStatus: SessionStatus?

    var body: some View {
        Group {
            switch appState {
            case .setup:
                SessionSetupView { sessionId, uploadService in
                    appState = .comparing(sessionId: sessionId, upload: uploadService)
                }

            case .comparing(let sessionId, let upload):
                ComparisonView(
                    sessionId: sessionId,
                    uploadService: upload,
                    onSkipToResults: {
                        appState = .results(sessionId: sessionId)
                    },
                    onComplete: {
                        // Fetch the comparison count for the completion subtitle.
                        // If the fetch fails, fall back to 0.
                        Task {
                            let count = (try? await api.sessionStatus(sessionId: sessionId))?.totalComparisons ?? 0
                            appState = .complete(sessionId: sessionId, totalComparisons: count)
                        }
                    }
                )

            case .complete(let sessionId, let totalComparisons):
                CompletionView(
                    sessionId: sessionId,
                    totalComparisons: totalComparisons,
                    onSeeFullRankings: {
                        appState = .results(sessionId: sessionId)
                    }
                )

            case .results(let sessionId):
                ResultsView(sessionId: sessionId)
            }
        }
        .animation(.easeInOut, value: {
            switch appState {
            case .setup: return 0
            case .comparing: return 1
            case .complete: return 2
            case .results: return 3
            }
        }())
    }
}
```

- [ ] **Step 2: Build — confirm success**

`⌘B`. Expected: project builds with no errors. All compile errors from Tasks 2–3 are now resolved.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/App/ContentView.swift
git commit -m "feat(ios): add .complete AppState; wire CompletionView into navigation state machine"
```

---

### Task 6: Update ResultsView with stage badge

**Files:**
- Modify: `ios/Sources/App/Views/ResultsView.swift`

`ResultsView` already calls `api.results(sessionId:)`. After the Task 2 change, this now returns `ResultsResponse` instead of `[RankedPhoto]`, so `fetchResults()` must be updated. Add a stage badge to the navigation bar.

- [ ] **Step 1: Update fetchResults and add stage state**

In `ResultsView.swift`, find the `@State private var isLoading = true` block and add two lines after it:

```swift
    @State private var sessionStage: String?
    @State private var isSessionComplete = false
```

- [ ] **Step 2: Update fetchResults()**

Find:

```swift
    private func fetchResults() async {
        isLoading = true
        do {
            photos = try await api.results(sessionId: sessionId)
        } catch {
            errorMessage = "Failed to load results: \(error.localizedDescription)"
        }
        isLoading = false
    }
```

Replace with:

```swift
    private func fetchResults() async {
        isLoading = true
        do {
            let response = try await api.results(sessionId: sessionId)
            photos = response.photos
            sessionStage = response.session?.stage
            isSessionComplete = response.session?.isComplete ?? false
        } catch {
            errorMessage = "Failed to load results: \(error.localizedDescription)"
        }
        isLoading = false
    }
```

- [ ] **Step 3: Add stage badge to navigation toolbar**

Find the `.toolbar` modifier block:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export All") { exportAll() }
                        .disabled(photos.isEmpty)
                }
            }
```

Replace with:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let stage = sessionStage {
                        Text(isSessionComplete ? "Complete" : "In Progress")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSessionComplete ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .foregroundStyle(isSessionComplete ? .green : .orange)
                            .clipShape(Capsule())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export All") { exportAll() }
                        .disabled(photos.isEmpty)
                }
            }
```

- [ ] **Step 4: Build — verify no errors**

`⌘B`. Expected: build succeeds with no errors or warnings.

- [ ] **Step 5: Run all tests**

`⌘U`. Expected: all tests pass (the existing `testResultsResponseDecodes` test uses JSON without `session`, which now decodes to `session: nil` — still valid since `session` is optional).

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/App/Views/ResultsView.swift
git commit -m "feat(ios): show stage badge in ResultsView; update fetchResults for new ResultsResponse shape"
```

---

### Task 7: Manual smoke test on simulator

**Files:** No code changes — verification only.

- [ ] **Step 1: Build and run on iPhone 15 simulator (iOS 17)**

`⌘R` in Xcode targeting iPhone 15 Simulator.

- [ ] **Step 2: Verify stage label appears during comparison**

Select 6+ photos. After first comparison loads, check the bottom toolbar:
- "Broad discovery" subtitle should appear below the comparison count
- After enough comparisons (all photos have ≥ 3): subtitle changes to "Refining top photos"

(Note: with only 6 photos, Stage 2 transition triggers after 9 comparisons.)

- [ ] **Step 3: Verify "Skip to Results" still works**

Tap "Skip to Results" before completion. Expected: transitions to `ResultsView` with "In Progress" badge in the navigation bar.

- [ ] **Step 4: Verify CompletionView appears automatically**

Continue making comparisons until the backend marks the session complete (may require many comparisons with real photos and a deployed backend). Expected: `CompletionView` appears automatically with "Your favorites are ready!" header and top photos grid.

- [ ] **Step 5: Verify "Export All Favorites" and "See Full Rankings"**

- Tap "Export All Favorites" → accept Photos permission prompt → alert shows saved count
- Tap "See Full Rankings" → transitions to `ResultsView` with "Complete" badge

---

## Self-Review

### 1. Spec Coverage

| Requirement | Task |
|---|---|
| Session status polling after each comparison | Task 3: `choose()` calls `api.sessionStatus()` |
| Auto-navigate to CompletionView when complete | Task 3: `onComplete()` called on `isComplete == true` |
| "Your favorites are ready!" screen with top photos | Task 4: `CompletionView` |
| 3-column top-10 grid | Task 4: `LazyVGrid(columns: 3)`, `limit: 10` |
| "Export All Favorites" CTA | Task 4: `exportAll()` function |
| "See Full Rankings" escape to ResultsView | Task 4: `onSeeFullRankings` callback → Task 5: transitions to `.results` |
| Stage label during comparison | Task 3: `stageLabel()` in ComparisonView |
| "Skip to Results" manual escape | Task 3: `onSkipToResults` replaces old `onFinish` |
| Stage badge in ResultsView | Task 6: toolbar badge from `response.session?.stage` |
| Backward-compatible model changes | Task 1: `stage: String?`, `session: SessionInfo?` are optional |

### 2. Placeholder Scan

No TBD, TODO, or incomplete steps. All view code is complete and compilable.

### 3. Type Consistency

- `SessionStatus.isComplete: Bool` defined Task 1 → used in Task 3 `choose()`: `status.isComplete` ✓
- `ResultsResponse.photos: [RankedPhoto]` defined Task 1 → assigned to `photos` in `ResultsView.fetchResults()` (Task 6): `response.photos` ✓
- `ResultsResponse.session: SessionInfo?` defined Task 1 → `response.session?.stage` in Tasks 4 and 6 ✓
- `CompletionView(sessionId:, totalComparisons:, onSeeFullRankings:)` defined Task 4 → called in `ContentView` Task 5 with all three parameters ✓
- `ComparisonView(sessionId:, uploadService:, onSkipToResults:, onComplete:)` defined Task 3 → called in `ContentView` Task 5 with all four parameters ✓
- `AppState.complete(sessionId: UUID, totalComparisons: Int)` defined Task 5 → `CompletionView` init receives both fields ✓
- `APIClient.results()` returns `ResultsResponse` after Task 2 → `CompletionView.fetchTopPhotos()` calls `api.results(...)` and accesses `.photos` ✓
- `APIClient.sessionStatus()` returns `SessionStatus` after Task 2 → called in `ComparisonView.choose()` and in `ContentView.onComplete` closure ✓
