# Invisible Upload Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the upload process invisible in the filter-then-rank flow: cull cards render from on-device images, uploads retry in a background keeper-priority queue, and dropped photos never upload.

**Architecture:** A new `PhotoPipeline` (iOS, `@MainActor`) owns a per-photo state machine — `pending → materialized → uploading → registered`, with `cancelled`/`parked`/`failed` branches — fed by a `PhotoDataLoading` abstraction over `PhotosPickerItem` and a `PhotoUploadTransport` abstraction over Supabase Storage + edge functions (both mockable). A new `LocalCardProvider` serves cull cards from the pipeline's on-disk compressed JPEGs, replacing the server round trip in `CullPrefetchService`. `register-photo` gains an optional client-supplied `photo_id` and becomes idempotent so retries are safe.

**Tech Stack:** SwiftUI + async/await with strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`), XCTest, Supabase edge functions (Deno + Zod), `deno test`.

**Spec:** `docs/superpowers/specs/2026-06-10-invisible-upload-pipeline-design.md`

**Commands used throughout:**

- iOS tests (after adding any new file, regenerate the project first):
  ```bash
  cd ios && xcodegen generate && xcodebuild test \
    -project Pictalis.xcodeproj -scheme Pictalis \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    CODE_SIGNING_ALLOWED=NO -quiet
  ```
  (If `iPhone 16` isn't installed, substitute any available iPhone simulator from `xcrun simctl list devices available`.)
- Backend tests:
  ```bash
  cd backend/supabase/functions && deno test --allow-env _shared/
  ```

---

### Task 1: Backend — `register-photo` accepts client `photo_id`, idempotent

**Files:**
- Create: `backend/supabase/functions/_shared/photo-registration.ts`
- Create: `backend/supabase/functions/_shared/photo-registration.test.ts`
- Modify: `backend/supabase/functions/register-photo/index.ts`

- [ ] **Step 1: Write the failing test**

Create `backend/supabase/functions/_shared/photo-registration.test.ts`:

```ts
import { assertEquals } from 'jsr:@std/assert@1';
import { isUniqueViolation, RegisterPhotoBody } from './photo-registration.ts';

const VALID_PATH =
  '11111111-2222-3333-4444-555555555555/66666666-7777-8888-9999-aaaaaaaaaaaa/photo.jpg';

Deno.test('RegisterPhotoBody accepts a body without photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
  });
  assertEquals(result.success, true);
});

Deno.test('RegisterPhotoBody accepts a valid photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
    photo_id: 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',
  });
  assertEquals(result.success, true);
});

Deno.test('RegisterPhotoBody rejects a non-UUID photo_id', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: VALID_PATH,
    photo_id: 'not-a-uuid',
  });
  assertEquals(result.success, false);
});

Deno.test('RegisterPhotoBody rejects a malformed storage_path', () => {
  const result = RegisterPhotoBody.safeParse({
    session_id: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    storage_path: 'just-a-filename.jpg',
  });
  assertEquals(result.success, false);
});

Deno.test('isUniqueViolation detects Postgres code 23505', () => {
  assertEquals(isUniqueViolation({ code: '23505' }), true);
  assertEquals(isUniqueViolation({ code: '42P01' }), false);
  assertEquals(isUniqueViolation(null), false);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/supabase/functions && deno test --allow-env _shared/photo-registration.test.ts`
Expected: FAIL — module `./photo-registration.ts` not found.

- [ ] **Step 3: Write the shared module**

Create `backend/supabase/functions/_shared/photo-registration.ts`:

```ts
import { z } from 'npm:zod@3';

const UUID_RE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
export const STORAGE_PATH_RE = new RegExp(`^${UUID_RE}/${UUID_RE}/[^/]+$`, 'i');

export const RegisterPhotoBody = z.object({
  session_id: z.string().uuid(),
  storage_path: z.string().regex(STORAGE_PATH_RE, 'Must match {uid}/{session_id}/{filename}'),
  photo_id: z.string().uuid().optional(),
});

// Postgres unique_violation — a retry of a register that already succeeded.
export function isUniqueViolation(error: { code?: string } | null): boolean {
  return error?.code === '23505';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/supabase/functions && deno test --allow-env _shared/photo-registration.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Wire into `register-photo/index.ts`**

In `backend/supabase/functions/register-photo/index.ts`:

Replace the local schema block (lines 11–17: `UUID_RE`, `STORAGE_PATH_RE`, `RegisterPhotoBody`) with an import:

```ts
import { isUniqueViolation, RegisterPhotoBody } from '../_shared/photo-registration.ts';
```

Replace the destructuring line (`const { session_id, storage_path } = parsed.data;`) with:

```ts
const { session_id, storage_path, photo_id } = parsed.data;
```

Replace the insert block (the `const { data: photo, error: insertError } = ...` statement and its error handler) with:

```ts
const PHOTO_COLUMNS =
  'id, session_id, storage_path, elo_rating, comparison_count, created_at, is_suppressed';

const insertRow: Record<string, string> = { session_id, storage_path };
if (photo_id) insertRow.id = photo_id;

const { data: photo, error: insertError } = await supabase
  .from('photos')
  .insert(insertRow)
  .select(PHOTO_COLUMNS)
  .single();

if (insertError && photo_id && isUniqueViolation(insertError)) {
  // Client retry of a register that already succeeded — return the existing row.
  const { data: existing } = await supabase
    .from('photos')
    .select(PHOTO_COLUMNS)
    .eq('id', photo_id)
    .single();
  if (existing && existing.session_id === session_id && existing.storage_path === storage_path) {
    return new Response(JSON.stringify({ photo: existing }), {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
  return new Response(JSON.stringify({ error: 'photo_id conflict' }), {
    status: 409,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

if (insertError || !photo) {
  console.error('Failed to insert photo record:', insertError);
  return new Response(JSON.stringify({ error: 'Failed to register photo' }), {
    status: 500,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
```

- [ ] **Step 6: Run all backend checks**

Run: `cd backend/supabase/functions && deno fmt --check . && deno lint . && deno check register-photo/index.ts && deno test --allow-env _shared/`
Expected: all PASS. If `deno fmt` complains, run `deno fmt .` and re-check.

- [ ] **Step 7: Commit**

```bash
git add backend/supabase/functions/_shared/photo-registration.ts \
        backend/supabase/functions/_shared/photo-registration.test.ts \
        backend/supabase/functions/register-photo/index.ts
git commit -m "feat(backend): register-photo accepts client photo_id, idempotent on retry"
```

---

### Task 2: iOS — photo source + transport abstractions

These are thin wrappers with no branching logic (except one error check), so there are no unit tests in this task; they exist so later tasks can mock them.

**Files:**
- Create: `ios/Sources/App/Services/PhotoSource.swift`
- Create: `ios/Sources/App/Services/PhotoUploadTransport.swift`
- Modify: `ios/Sources/App/Services/APIClient.swift:55-68` (registerPhoto)
- Modify: `ios/Sources/App/Services/UploadService.swift:65-70` (keep compiling until Task 8 deletes it)

- [ ] **Step 1: Create `PhotoSource.swift`**

```swift
import Foundation
import PhotosUI

// Abstracts PhotosPickerItem so PhotoPipeline can be unit-tested with fixture data.
protocol PhotoDataLoading: Sendable {
    func loadData() async throws -> Data
}

struct PickerItemLoader: PhotoDataLoading {
    let item: PhotosPickerItem

    func loadData() async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CompressionError.noImageData
        }
        return data
    }
}

struct PendingPhoto: Identifiable, Sendable {
    let id: UUID
    let loader: any PhotoDataLoading

    init(id: UUID = UUID(), loader: any PhotoDataLoading) {
        self.id = id
        self.loader = loader
    }
}
```

Note: if the compiler reports that `PhotosPickerItem` is not `Sendable`, change the conformance line to `struct PickerItemLoader: PhotoDataLoading, @unchecked Sendable {` — the item is only read once from a single task.

- [ ] **Step 2: Create `PhotoUploadTransport.swift`**

```swift
import Foundation
import Supabase

protocol PhotoUploadTransport: Sendable {
    func upload(storagePath: String, data: Data) async throws
    func register(sessionId: UUID, photoId: UUID, storagePath: String) async throws
    func markUploadComplete(sessionId: UUID) async throws
}

struct SupabaseUploadTransport: PhotoUploadTransport {
    let supabase: SupabaseClient
    let api: APIClient

    func upload(storagePath: String, data: Data) async throws {
        do {
            try await supabase.storage
                .from("working-copies")
                .upload(storagePath, data: data, options: FileOptions(contentType: "image/jpeg"))
        } catch {
            // A retry after a success whose response was lost: the object is
            // already there, which is the outcome we wanted.
            if isAlreadyExists(error) { return }
            throw error
        }
    }

    func register(sessionId: UUID, photoId: UUID, storagePath: String) async throws {
        _ = try await api.registerPhoto(sessionId: sessionId, photoId: photoId, storagePath: storagePath)
    }

    func markUploadComplete(sessionId: UUID) async throws {
        try await api.markUploadComplete(sessionId: sessionId)
    }

    private func isAlreadyExists(_ error: Error) -> Bool {
        guard let storageError = error as? StorageError else { return false }
        return storageError.statusCode == "409" || storageError.error == "Duplicate"
    }
}
```

Note: `StorageError`'s fields are `statusCode: String?` / `error: String?` in supabase-swift v2. If the compiler disagrees (e.g., `statusCode` is `Int?`), adjust the comparison to the actual type — the intent is "HTTP 409 / duplicate object means success."

- [ ] **Step 3: Add `photoId` to `APIClient.registerPhoto`**

In `ios/Sources/App/Services/APIClient.swift`, replace the `registerPhoto` method:

```swift
    // MARK: - register-photo
    // POST { session_id, photo_id, storage_path } → { photo: { id, ... } }

    func registerPhoto(sessionId: UUID, photoId: UUID, storagePath: String) async throws -> RegisteredPhoto {
        let url = functionsBase.appending(path: "register-photo")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased(),
            "photo_id": photoId.uuidString.lowercased(),
            "storage_path": storagePath,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(RegisterPhotoResponse.self, from: data).photo
    }
```

This breaks the call in `UploadService.swift:70`. Patch it minimally so the project still compiles (UploadService is deleted in Task 8). In `ios/Sources/App/Services/UploadService.swift`, replace lines 65–70:

```swift
            let photoId = UUID()
            let filename = "\(photoId.uuidString.lowercased()).jpg"
            let storagePath = "\(userId.uuidString.lowercased())/\(sessionId.uuidString.lowercased())/\(filename)"
            try await supabase.storage
                .from("working-copies")
                .upload(storagePath, data: compressed, options: FileOptions(contentType: "image/jpeg"))
            _ = try await api.registerPhoto(sessionId: sessionId, photoId: photoId, storagePath: storagePath)
```

- [ ] **Step 4: Build and run existing tests**

Run the iOS test command from the header.
Expected: BUILD SUCCEEDED, all existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/PhotoSource.swift \
        ios/Sources/App/Services/PhotoUploadTransport.swift \
        ios/Sources/App/Services/APIClient.swift \
        ios/Sources/App/Services/UploadService.swift \
        ios/Pictalis.xcodeproj
git commit -m "feat(ios): photo source and upload transport abstractions, client photo_id in register"
```

---

### Task 3: iOS — `PhotoPipeline` materialization

**Files:**
- Create: `ios/Sources/App/Services/PhotoPipeline.swift`
- Create: `ios/Tests/PhotoPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Tests/PhotoPipelineTests.swift`:

```swift
import UIKit
import XCTest
@testable import Pictalis

// MARK: - Test fixtures

enum TestImage {
    static func jpegData(width: CGFloat = 64, height: CGFloat = 48) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }
}

struct MockLoader: PhotoDataLoading {
    var data: Data? = TestImage.jpegData()
    func loadData() async throws -> Data {
        guard let data else { throw CompressionError.noImageData }
        return data
    }
}

struct MockTransportError: Error {}

@MainActor
final class MockTransport: PhotoUploadTransport {
    private(set) var uploadedPaths: [String] = []
    private(set) var registeredIds: [UUID] = []
    private(set) var markCompleteCount = 0
    var uploadFailures: [UUID: Int] = [:]   // photoId → remaining failures to throw
    var registerFailures: [UUID: Int] = [:]
    var uploadDelay: Duration = .zero

    private func photoId(fromPath path: String) -> UUID? {
        guard let filename = path.split(separator: "/").last else { return nil }
        return UUID(uuidString: String(filename.dropLast(4)))
    }

    func upload(storagePath: String, data: Data) async throws {
        if uploadDelay > .zero { try? await Task.sleep(for: uploadDelay) }
        if let id = photoId(fromPath: storagePath), let n = uploadFailures[id], n > 0 {
            uploadFailures[id] = n - 1
            throw MockTransportError()
        }
        uploadedPaths.append(storagePath)
    }

    func register(sessionId: UUID, photoId: UUID, storagePath: String) async throws {
        if let n = registerFailures[photoId], n > 0 {
            registerFailures[photoId] = n - 1
            throw MockTransportError()
        }
        registeredIds.append(photoId)
    }

    func markUploadComplete(sessionId: UUID) async throws {
        markCompleteCount += 1
    }
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("waitUntil timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Tests

@MainActor
final class PhotoPipelineTests: XCTestCase {

    private func makePipeline(
        transport: MockTransport,
        retryDelays: [Duration] = [],
        materializeConcurrency: Int = 1,
        uploadConcurrency: Int = 1,
        connectivity: AsyncStream<Void> = AsyncStream { $0.finish() }
    ) -> PhotoPipeline {
        PhotoPipeline(
            transport: transport,
            sessionId: UUID(),
            userId: UUID(),
            retryDelays: retryDelays,
            materializeConcurrency: materializeConcurrency,
            uploadConcurrency: uploadConcurrency,
            connectivityEvents: connectivity
        )
    }

    func testMaterializesPhotoToDisk() async throws {
        let pipeline = makePipeline(transport: MockTransport())
        let photo = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [photo])

        let url = try await pipeline.materializedFileURL(for: photo.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let image = UIImage(data: try Data(contentsOf: url))
        XCTAssertNotNil(image)
    }

    func testDisplayImageDecodesMaterializedPhoto() async throws {
        let pipeline = makePipeline(transport: MockTransport())
        let photo = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [photo])

        let image = try await pipeline.displayImage(for: photo.id)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testMaterializeFailureMarksFailed() async throws {
        let pipeline = makePipeline(transport: MockTransport())
        let bad = PendingPhoto(loader: MockLoader(data: nil))
        let good = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [bad, good])

        try await waitUntil { pipeline.failedIds == [bad.id] }
        do {
            _ = try await pipeline.displayImage(for: bad.id)
            XCTFail("expected photoUnavailable")
        } catch {}
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the iOS test command (xcodegen first — two new files).
Expected: BUILD FAILS — `PhotoPipeline` not defined.

- [ ] **Step 3: Create `PhotoPipeline.swift` with materialization**

Create `ios/Sources/App/Services/PhotoPipeline.swift`:

```swift
import Foundation
import Network
import UIKit

enum PhotoRegistrationState {
    case registered   // server knows this photo
    case pending      // may still register (queued, uploading, retrying, parked)
    case unavailable  // cancelled or failed — the server will never know it
}

enum PipelineError: Error {
    case photoUnavailable
}

// Owns the per-photo state machine: materialize (compress to tmp disk) →
// upload → register. Cull display images decode from the same tmp files,
// so the cull phase never touches the network.
@MainActor
final class PhotoPipeline: ObservableObject {

    enum ItemState: Equatable {
        case pending       // waiting to materialize
        case materialized  // compressed JPEG on disk, queued for upload
        case uploading     // an upload worker owns it
        case registered    // server row exists
        case cancelled     // dropped in cull before upload — never uploads
        case parked        // retries exhausted; waits for connectivity or user retry
        case failed        // local asset could not be read — terminal
    }

    private struct Item {
        let photoId: UUID
        let loader: any PhotoDataLoading
        var state: ItemState = .pending
        var isKept = false
        var didUpload = false
        var fileURL: URL?
        var materializeAttempts = 0
    }

    @Published private(set) var registeredCount = 0
    @Published private(set) var failedIds: [UUID] = []
    @Published private(set) var isComplete = false

    private(set) var order: [UUID] = []
    var totalCount: Int { order.count }
    var onRegistered: ((UUID) -> Void)?

    private var items: [UUID: Item] = [:]
    private var uploadQueue: [UUID] = []
    private var activeUploads = 0
    private var waiters: [UUID: [CheckedContinuation<URL, Error>]] = [:]
    private var didMarkComplete = false

    private let transport: any PhotoUploadTransport
    private let sessionId: UUID
    private let userId: UUID
    private let retryDelays: [Duration]
    private let materializeConcurrency: Int
    private let uploadConcurrency: Int
    private let connectivityEvents: AsyncStream<Void>
    private var monitor: NWPathMonitor?

    init(
        transport: any PhotoUploadTransport,
        sessionId: UUID,
        userId: UUID,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        materializeConcurrency: Int = 3,
        uploadConcurrency: Int = 4,
        connectivityEvents: AsyncStream<Void>? = nil
    ) {
        self.transport = transport
        self.sessionId = sessionId
        self.userId = userId
        self.retryDelays = retryDelays
        self.materializeConcurrency = materializeConcurrency
        self.uploadConcurrency = uploadConcurrency
        if let connectivityEvents {
            self.connectivityEvents = connectivityEvents
        } else {
            let monitor = NWPathMonitor()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { continuation.yield() }
            }
            monitor.start(queue: DispatchQueue(label: "pipeline.connectivity", qos: .background))
            self.connectivityEvents = stream
            self.monitor = monitor
        }
    }

    func start(photos: [PendingPhoto]) {
        order = photos.map(\.id)
        for photo in photos {
            items[photo.id] = Item(photoId: photo.id, loader: photo.loader)
        }
        prepareSessionDirectory()
        Task { await self.materializeAll() }
        Task { [weak self] in
            guard let events = self?.connectivityEvents else { return }
            for await _ in events { self?.retryParked() }
        }
    }

    // MARK: - Display access

    // Returns the on-disk compressed JPEG, waiting for materialization if needed.
    func materializedFileURL(for id: UUID) async throws -> URL {
        guard let item = items[id] else { throw PipelineError.photoUnavailable }
        switch item.state {
        case .cancelled, .failed:
            throw PipelineError.photoUnavailable
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
        default:
            guard let url = item.fileURL else { throw PipelineError.photoUnavailable }
            return url
        }
    }

    func displayImage(for id: UUID) async throws -> UIImage {
        let url = try await materializedFileURL(for: id)
        return try await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                throw PipelineError.photoUnavailable
            }
            return image
        }.value
    }

    // MARK: - Stubs completed in later tasks

    func setDecision(photoId: UUID, decision: CullDecision) {}
    func retryParked() {}

    func registrationState(for id: UUID) -> PhotoRegistrationState {
        switch items[id]?.state {
        case .registered: return .registered
        case .cancelled, .failed, nil: return .unavailable
        default: return .pending
        }
    }

    // MARK: - Materialization

    private var sessionDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PictalisUploads")
            .appendingPathComponent(sessionId.uuidString.lowercased())
    }

    private func prepareSessionDirectory() {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PictalisUploads")
        try? FileManager.default.removeItem(at: parent) // clear previous sessions
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    private func materializeAll() async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = order.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask { @MainActor in await self.materialize(id) }
            }
            for _ in 0..<materializeConcurrency { addNext() }
            for await _ in group { addNext() }
        }
    }

    private func materialize(_ id: UUID) async {
        guard items[id]?.state == .pending, let loader = items[id]?.loader else { return }
        items[id]?.materializeAttempts += 1
        do {
            let raw = try await loader.loadData()
            let jpeg = try await Task.detached(priority: .userInitiated) {
                guard let image = UIImage(data: raw) else { throw CompressionError.noImageData }
                return try ImageCompressor.compressImage(image)
            }.value
            // The photo may have been dropped while we were decoding.
            guard items[id]?.state == .pending else { return }
            let url = sessionDirectory.appendingPathComponent("\(id.uuidString.lowercased()).jpg")
            try jpeg.write(to: url)
            items[id]?.fileURL = url
            items[id]?.state = .materialized
            resumeWaiters(for: id, with: .success(url))
            enqueueUpload(id)
        } catch {
            if items[id]?.materializeAttempts == 1 {
                await materialize(id) // one immediate retry
            } else {
                items[id]?.state = .failed
                updateFailedIds()
                resumeWaiters(for: id, with: .failure(PipelineError.photoUnavailable))
                checkCompletion()
            }
        }
    }

    private func resumeWaiters(for id: UUID, with result: Result<URL, Error>) {
        for continuation in waiters[id] ?? [] {
            continuation.resume(with: result)
        }
        waiters[id] = nil
    }

    // MARK: - Upload (completed in Task 4)

    private func enqueueUpload(_ id: UUID) {}

    // MARK: - Bookkeeping

    private func updateFailedIds() {
        failedIds = order.filter {
            let state = items[$0]?.state
            return state == .parked || state == .failed
        }
    }

    private func checkCompletion() {
        guard !didMarkComplete, !order.isEmpty else { return }
        let unresolved = order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading: return true
            default: return false
            }
        }
        guard !unresolved else { return }
        didMarkComplete = true
        isComplete = true
        Task { try? await self.transport.markUploadComplete(sessionId: self.sessionId) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the iOS test command.
Expected: the three `PhotoPipelineTests` PASS; existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/PhotoPipeline.swift ios/Tests/PhotoPipelineTests.swift ios/Pictalis.xcodeproj
git commit -m "feat(ios): PhotoPipeline materialization — compress to tmp disk, local display access"
```

---

### Task 4: iOS — `PhotoPipeline` upload, priority, retry

**Files:**
- Modify: `ios/Sources/App/Services/PhotoPipeline.swift`
- Modify: `ios/Tests/PhotoPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `PhotoPipelineTests` in `ios/Tests/PhotoPipelineTests.swift`:

```swift
    func testUploadsAndRegistersAllPhotos() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport, uploadConcurrency: 4)
        let photos = (0..<5).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 5)
        XCTAssertEqual(Set(transport.registeredIds), Set(photos.map(\.id)))
        XCTAssertEqual(transport.markCompleteCount, 1)
        XCTAssertTrue(pipeline.failedIds.isEmpty)
    }

    func testKeptPhotoJumpsQueue() async throws {
        let transport = MockTransport()
        transport.uploadDelay = .milliseconds(50)
        let pipeline = makePipeline(transport: transport)
        let photos = (0..<5).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        // With materialize+upload concurrency 1 and a 50ms upload delay,
        // photo 0 is mid-upload while later photos queue behind it.
        pipeline.setDecision(photoId: photos[4].id, decision: .keep)

        try await waitUntil { pipeline.isComplete }
        // The kept photo must register before undecided photo 2.
        let registered = transport.registeredIds
        guard let keptIndex = registered.firstIndex(of: photos[4].id),
              let photo2Index = registered.firstIndex(of: photos[2].id) else {
            XCTFail("both photos should have registered")
            return
        }
        XCTAssertLessThan(keptIndex, photo2Index)
    }

    func testTransientFailuresRetryAndSucceed() async throws {
        let transport = MockTransport()
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.registerFailures[photos[1].id] = 2
        let pipeline = makePipeline(transport: transport, retryDelays: [.zero, .zero, .zero])
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 3)
        XCTAssertTrue(pipeline.failedIds.isEmpty)
    }

    func testExhaustedRetriesPark() async throws {
        let transport = MockTransport()
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.uploadFailures[photos[1].id] = 99
        let pipeline = makePipeline(transport: transport, retryDelays: [.zero])
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 2)
        XCTAssertEqual(pipeline.failedIds, [photos[1].id])
        XCTAssertEqual(transport.markCompleteCount, 1)
    }
```

Note on `testKeptPhotoJumpsQueue`: `setDecision(.keep)` is a stub until Task 5, but the `isKept` flag it sets lives in this task's queue-priority logic, so implement the keep half of `setDecision` here (see Step 3).

- [ ] **Step 2: Run tests to verify they fail**

Run the iOS test command.
Expected: the four new tests FAIL or time out (`enqueueUpload` is a no-op stub, so `isComplete` never becomes true).

- [ ] **Step 3: Implement the upload pump**

In `ios/Sources/App/Services/PhotoPipeline.swift`, replace the stub `private func enqueueUpload(_ id: UUID) {}` (and its `// MARK: - Upload` comment) with:

```swift
    // MARK: - Upload

    private func enqueueUpload(_ id: UUID) {
        uploadQueue.append(id)
        pumpUploads()
    }

    private func pumpUploads() {
        while activeUploads < uploadConcurrency, let id = dequeueNextUpload() {
            activeUploads += 1
            items[id]?.state = .uploading
            Task { await self.uploadAndRegister(id) }
        }
    }

    // Kept photos jump the queue; otherwise FIFO (selection order).
    private func dequeueNextUpload() -> UUID? {
        while !uploadQueue.isEmpty {
            let index = uploadQueue.firstIndex { items[$0]?.isKept == true } ?? 0
            let id = uploadQueue.remove(at: index)
            if items[id]?.state == .materialized { return id }
            // dropped while queued — skip it
        }
        return nil
    }

    private func uploadAndRegister(_ id: UUID) async {
        defer {
            activeUploads -= 1
            pumpUploads()
            checkCompletion()
        }
        guard let fileURL = items[id]?.fileURL, let data = try? Data(contentsOf: fileURL) else {
            items[id]?.state = .failed
            updateFailedIds()
            return
        }
        let storagePath = "\(userId.uuidString.lowercased())/\(sessionId.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
        do {
            if items[id]?.didUpload != true {
                try await withRetries { try await self.transport.upload(storagePath: storagePath, data: data) }
                items[id]?.didUpload = true
            }
            try await withRetries {
                try await self.transport.register(sessionId: self.sessionId, photoId: id, storagePath: storagePath)
            }
            items[id]?.state = .registered
            registeredCount += 1
            updateFailedIds()
            onRegistered?(id)
        } catch {
            items[id]?.state = .parked
            updateFailedIds()
        }
    }

    private func withRetries(_ operation: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch {
                guard attempt < retryDelays.count else { throw error }
                let jitter = Duration.milliseconds(Int.random(in: 0...300))
                try? await Task.sleep(for: retryDelays[attempt] + jitter)
                attempt += 1
            }
        }
    }
```

Also replace the `setDecision` stub with the keep half (drop is Task 5):

```swift
    func setDecision(photoId: UUID, decision: CullDecision) {
        guard items[photoId] != nil else { return }
        if decision == .keep {
            items[photoId]?.isKept = true
        }
    }
```

Note: with `retryDelays: []` an operation gets exactly one attempt; with `[.zero, .zero, .zero]` it gets four (immediate) attempts. The jitter only matters for the real default delays — `Task.sleep(for: .zero + jitter)` adds up to 300ms per zero-delay retry, which is why the retry tests use `waitUntil` rather than asserting timing.

- [ ] **Step 4: Run tests to verify they pass**

Run the iOS test command.
Expected: all `PhotoPipelineTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/PhotoPipeline.swift ios/Tests/PhotoPipelineTests.swift
git commit -m "feat(ios): PhotoPipeline background upload with keeper priority and per-step retry"
```

---

### Task 5: iOS — `PhotoPipeline` decisions, cancellation, connectivity recovery

**Files:**
- Modify: `ios/Sources/App/Services/PhotoPipeline.swift`
- Modify: `ios/Tests/PhotoPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `PhotoPipelineTests`:

```swift
    func testDropCancelsQueuedUpload() async throws {
        let transport = MockTransport()
        transport.uploadDelay = .milliseconds(50)
        let pipeline = makePipeline(transport: transport)
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        // Wait until photo 2 is materialized (so it has a tmp file), then drop
        // it while photo 0 is still mid-upload behind the 50ms delay.
        let fileURL = try await pipeline.materializedFileURL(for: photos[2].id)
        pipeline.setDecision(photoId: photos[2].id, decision: .drop)

        try await waitUntil { pipeline.isComplete }
        XCTAssertFalse(transport.registeredIds.contains(photos[2].id))
        XCTAssertEqual(pipeline.registeredCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(pipeline.registrationState(for: photos[2].id), .unavailable)
        XCTAssertEqual(transport.markCompleteCount, 1)
    }

    func testDropAfterRegisteredIsNoop() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)
        let photo = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [photo])

        try await waitUntil { pipeline.isComplete }
        pipeline.setDecision(photoId: photo.id, decision: .drop)
        XCTAssertEqual(pipeline.registrationState(for: photo.id), .registered)
    }

    func testConnectivityEventRetriesParked() async throws {
        let transport = MockTransport()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.uploadFailures[photos[1].id] = 1
        let pipeline = makePipeline(transport: transport, connectivity: stream)
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.failedIds, [photos[1].id])

        continuation.yield() // connectivity restored; failure budget is spent
        try await waitUntil { pipeline.registeredCount == 2 }
        XCTAssertTrue(pipeline.failedIds.isEmpty)
    }

    func testRetryParkedRequeuesFailedPhotos() async throws {
        let transport = MockTransport()
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.registerFailures[photos[0].id] = 1
        let pipeline = makePipeline(transport: transport)
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.failedIds, [photos[0].id])

        pipeline.retryParked()
        try await waitUntil { pipeline.registeredCount == 2 }
        XCTAssertTrue(pipeline.failedIds.isEmpty)
        // The storage upload already succeeded — the retry must not re-upload.
        XCTAssertEqual(transport.uploadedPaths.count, 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the iOS test command.
Expected: the four new tests FAIL (drop is ignored; `retryParked` is a stub).

- [ ] **Step 3: Implement decisions and parked retry**

In `ios/Sources/App/Services/PhotoPipeline.swift`, replace the keep-only `setDecision` and the `retryParked` stub (rename the MARK to `// MARK: - Decisions & retry`):

```swift
    // Drop ⇒ cancel the upload if the server doesn't know the photo yet.
    // Keep ⇒ promote it to the front of the upload queue.
    func setDecision(photoId: UUID, decision: CullDecision) {
        guard items[photoId] != nil else { return }
        switch decision {
        case .keep:
            items[photoId]?.isKept = true
        case .drop:
            switch items[photoId]?.state {
            case .pending, .materialized, .parked:
                items[photoId]?.state = .cancelled
                if let url = items[photoId]?.fileURL {
                    try? FileManager.default.removeItem(at: url)
                    items[photoId]?.fileURL = nil
                }
                resumeWaiters(for: photoId, with: .failure(PipelineError.photoUnavailable))
                updateFailedIds()
                checkCompletion()
            default:
                // uploading or registered: let it finish; the synced drop
                // decision suppresses it server-side.
                break
            }
        }
    }

    // Give parked photos a fresh retry budget. Called on connectivity
    // restore and from the user-facing retry affordance.
    func retryParked() {
        for id in order where items[id]?.state == .parked {
            items[id]?.state = .materialized
            enqueueUpload(id)
        }
        updateFailedIds()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the iOS test command.
Expected: all `PhotoPipelineTests` PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/PhotoPipeline.swift ios/Tests/PhotoPipelineTests.swift
git commit -m "feat(ios): PhotoPipeline cull decisions, drop-cancellation, connectivity retry"
```

---

### Task 6: iOS — `SyncService` filters decisions by registration state

**Files:**
- Modify: `ios/Sources/App/Services/SyncService.swift`
- Create: `ios/Tests/SyncPartitionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/Tests/SyncPartitionTests.swift`:

```swift
import XCTest
@testable import Pictalis

final class SyncPartitionTests: XCTestCase {
    func testPartitionsByRegistrationState() {
        let registered = UUID()
        let inFlight = UUID()
        let cancelled = UUID()
        let decisions = [
            StoredDecision(photoId: registered, decision: .keep, timestamp: .now, synced: false),
            StoredDecision(photoId: inFlight, decision: .keep, timestamp: .now, synced: false),
            StoredDecision(photoId: cancelled, decision: .drop, timestamp: .now, synced: false),
        ]
        let states: [UUID: PhotoRegistrationState] = [
            registered: .registered,
            inFlight: .pending,
            cancelled: .unavailable,
        ]

        let (send, markLocalOnly) = SyncService.partition(
            pending: decisions,
            registrationState: { states[$0] ?? .pending }
        )

        XCTAssertEqual(send.map(\.photoId), [registered])
        XCTAssertEqual(markLocalOnly, [cancelled])
    }
}
```

(If `StoredDecision`'s memberwise initializer has a different argument order, match `Models.swift:197` — fields are `photoId`, `decision`, `timestamp`, `synced`.)

- [ ] **Step 2: Run test to verify it fails**

Run the iOS test command (xcodegen first — new file).
Expected: BUILD FAILS — `SyncService.partition` not defined.

- [ ] **Step 3: Implement partition and wire into drain**

In `ios/Sources/App/Services/SyncService.swift`:

Add a stored property and update the initializer:

```swift
    private let registrationState: (UUID) -> PhotoRegistrationState

    init(
        sessionId: UUID,
        api: APIClient,
        registrationState: @escaping (UUID) -> PhotoRegistrationState = { _ in .registered }
    ) {
        self.sessionId = sessionId
        self.api = api
        self.registrationState = registrationState
    }
```

(The default keeps any other construction sites compiling with today's send-everything behavior.)

Add the pure helper:

```swift
    // Decisions for registered photos go to the server; decisions for photos
    // the server will never know (cancelled uploads) are settled locally;
    // the rest stay pending until their photo registers.
    static func partition(
        pending: [StoredDecision],
        registrationState: (UUID) -> PhotoRegistrationState
    ) -> (send: [StoredDecision], markLocalOnly: [UUID]) {
        var send: [StoredDecision] = []
        var markLocalOnly: [UUID] = []
        for decision in pending {
            switch registrationState(decision.photoId) {
            case .registered:  send.append(decision)
            case .unavailable: markLocalOnly.append(decision.photoId)
            case .pending:     break
            }
        }
        return (send, markLocalOnly)
    }
```

Replace the start of `drain()` (the lines from `guard !isDraining, let store else { return }` through `guard !pending.isEmpty else { return }`) with:

```swift
        guard !isDraining, let store else { return }
        let (send, markLocalOnly) = Self.partition(
            pending: store.pendingDecisions,
            registrationState: registrationState
        )
        if !markLocalOnly.isEmpty { store.markSynced(photoIds: markLocalOnly) }
        guard !send.isEmpty else { return }
```

and replace the `api.batchSubmitCull(sessionId: sessionId, decisions: pending)` call inside the retry loop with `api.batchSubmitCull(sessionId: sessionId, decisions: send)`.

- [ ] **Step 4: Run tests to verify they pass**

Run the iOS test command.
Expected: `SyncPartitionTests` PASS; all other tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/SyncService.swift ios/Tests/SyncPartitionTests.swift ios/Pictalis.xcodeproj
git commit -m "feat(ios): SyncService sends only registered-photo decisions, settles cancelled locally"
```

---

### Task 7: iOS — `LocalCardProvider` replaces server-driven cull prefetch

**Files:**
- Create: `ios/Sources/App/Services/LocalCardProvider.swift`
- Create: `ios/Tests/LocalCardProviderTests.swift`
- Modify: `ios/Sources/App/Services/CullPrefetchService.swift:3-8` (remove `CullQueueState` — it moves to the new file)

- [ ] **Step 1: Write the failing tests**

Create `ios/Tests/LocalCardProviderTests.swift`:

```swift
import XCTest
@testable import Pictalis

@MainActor
final class LocalCardProviderTests: XCTestCase {

    private func makePipeline(photos: [PendingPhoto]) -> PhotoPipeline {
        let pipeline = PhotoPipeline(
            transport: MockTransport(),
            sessionId: UUID(),
            userId: UUID(),
            retryDelays: [],
            materializeConcurrency: 1,
            uploadConcurrency: 1,
            connectivityEvents: AsyncStream { $0.finish() }
        )
        pipeline.start(photos: photos)
        return pipeline
    }

    func testServesCardsInSelectionOrderExcludingDecided() async throws {
        let photos = (0..<4).map { _ in PendingPhoto(loader: MockLoader()) }
        let provider = LocalCardProvider(pipeline: makePipeline(photos: photos))

        await provider.start(excluding: [photos[1].id])
        try await waitUntil { provider.queue.count == 3 }

        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.advance()?.photoId, photos[0].id)
        XCTAssertEqual(provider.advance()?.photoId, photos[2].id)
        XCTAssertEqual(provider.advance()?.photoId, photos[3].id)
        XCTAssertEqual(provider.state, .exhausted)
    }

    func testSkipsPhotoThatFailsToMaterialize() async throws {
        let photos = [
            PendingPhoto(loader: MockLoader()),
            PendingPhoto(loader: MockLoader(data: nil)),
            PendingPhoto(loader: MockLoader()),
        ]
        let provider = LocalCardProvider(pipeline: makePipeline(photos: photos))

        await provider.start(excluding: [])
        try await waitUntil { provider.queue.count == 2 }

        XCTAssertEqual(provider.advance()?.photoId, photos[0].id)
        XCTAssertEqual(provider.advance()?.photoId, photos[2].id)
        XCTAssertEqual(provider.state, .exhausted)
    }

    func testExhaustedWhenEverythingAlreadyDecided() async throws {
        let photos = [PendingPhoto(loader: MockLoader())]
        let provider = LocalCardProvider(pipeline: makePipeline(photos: photos))

        await provider.start(excluding: [photos[0].id])
        XCTAssertEqual(provider.state, .exhausted)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the iOS test command (xcodegen first).
Expected: BUILD FAILS — `LocalCardProvider` not defined.

- [ ] **Step 3: Create `LocalCardProvider.swift` and move `CullQueueState`**

Remove the `CullQueueState` enum from `ios/Sources/App/Services/CullPrefetchService.swift:3-8` (it is redeclared in the new file; the rest of `CullPrefetchService` keeps compiling against it until Task 8 deletes the file).

Create `ios/Sources/App/Services/LocalCardProvider.swift`:

```swift
import UIKit

enum CullQueueState: Equatable {
    case loading
    case ready
    case exhausted
    case error(String)
}

// Serves cull cards from PhotoPipeline's on-disk compressed copies.
// Zero network: replaces the server-driven CullPrefetchService.
@Observable @MainActor
final class LocalCardProvider {

    struct Card: Sendable, Identifiable {
        let photoId: UUID
        let image:   UIImage
        var id: UUID { photoId }
    }

    private static let normalQueueSize = 10
    private static let minQueueSize    = 3

    private(set) var queue: [Card] = []
    private(set) var state: CullQueueState = .loading

    private let pipeline: PhotoPipeline
    private var remaining: [UUID] = []   // undecided ids, selection order, not yet queued
    private var isFilling = false
    private var currentMaxQueueSize = LocalCardProvider.normalQueueSize
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    init(pipeline: PhotoPipeline) {
        self.pipeline = pipeline
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMemoryWarning() }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Decode just the first card before returning (sub-second first paint),
    // then keep filling the decode-ahead window in the background.
    func start(excluding decidedIds: [UUID]) async {
        let decided = Set(decidedIds)
        remaining = pipeline.order.filter { !decided.contains($0) }
        await fill(target: 1)
        if queue.isEmpty && remaining.isEmpty {
            state = .exhausted
        } else if !queue.isEmpty {
            state = .ready
        }
        Task { await self.fill() }
    }

    func advance() -> Card? {
        guard !queue.isEmpty else {
            if remaining.isEmpty { state = .exhausted }
            return nil
        }
        let card = queue.removeFirst()
        if queue.isEmpty && remaining.isEmpty {
            state = .exhausted
        } else {
            Task { await self.fill() }
        }
        return card
    }

    // Kept for CullView's error-state button; local loads rarely need it.
    func retry() {
        Task {
            await self.fill()
            if !self.queue.isEmpty { self.state = .ready }
        }
    }

    // MARK: - Private

    private func fill(target: Int? = nil) async {
        guard !isFilling else { return }
        isFilling = true
        defer { isFilling = false }

        while queue.count < (target ?? currentMaxQueueSize), !remaining.isEmpty {
            let id = remaining.removeFirst()
            do {
                let image = try await pipeline.displayImage(for: id)
                queue.append(Card(photoId: id, image: image))
                if state == .loading { state = .ready }
            } catch {
                continue // cancelled or unreadable — skip silently
            }
        }
        if queue.isEmpty && remaining.isEmpty { state = .exhausted }
    }

    private func handleMemoryWarning() {
        currentMaxQueueSize = Self.minQueueSize
        if queue.count > currentMaxQueueSize {
            // Evict from the tail (furthest from display); ids go back to the
            // head of `remaining` so they re-decode later in order.
            let evicted = queue.suffix(queue.count - currentMaxQueueSize).map(\.photoId)
            queue.removeLast(queue.count - currentMaxQueueSize)
            remaining.insert(contentsOf: evicted, at: 0)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the iOS test command.
Expected: `LocalCardProviderTests` PASS; all other tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/App/Services/LocalCardProvider.swift \
        ios/Sources/App/Services/CullPrefetchService.swift \
        ios/Tests/LocalCardProviderTests.swift ios/Pictalis.xcodeproj
git commit -m "feat(ios): LocalCardProvider serves cull cards from on-device photos"
```

---

### Task 8: iOS — wire views to the pipeline, delete the old upload path

No new unit tests (pure UI wiring; UI tests are optional in MVP per CLAUDE.md). The full suite must stay green.

**Files:**
- Modify: `ios/Sources/App/ContentView.swift`
- Modify: `ios/Sources/App/Views/SessionSetupView.swift`
- Modify: `ios/Sources/App/Views/CullChoiceView.swift`
- Modify: `ios/Sources/App/Views/CullView.swift`
- Modify: `ios/Sources/App/Views/ComparisonView.swift`
- Modify: `ios/Sources/App/Models/Models.swift` (remove `PrefetchCullCard`/`PrefetchCullResponse`, lines ~223–236)
- Modify: `ios/Sources/App/Services/APIClient.swift` (remove `prefetchCull`, lines ~216–237)
- Delete: `ios/Sources/App/Services/UploadService.swift`
- Delete: `ios/Sources/App/Services/CullPrefetchService.swift`

- [ ] **Step 1: `ContentView.swift` — carry `PhotoPipeline` through app state**

Replace the `upload: UploadService` association in `AppState` with `pipeline: PhotoPipeline`:

```swift
enum AppState {
    case setup
    case choosingCullMode(sessionId: UUID, pipeline: PhotoPipeline)
    case culling(sessionId: UUID, pipeline: PhotoPipeline)
    case comparing(sessionId: UUID, pipeline: PhotoPipeline)
    case complete(sessionId: UUID, totalComparisons: Int)
    case results(sessionId: UUID, previousComparisons: Int? = nil, initialPhotos: [RankedPhoto] = [])
}
```

In the body, the corresponding cases become:

```swift
            case .setup:
                SessionSetupView { sessionId, pipeline in
                    appState = .choosingCullMode(sessionId: sessionId, pipeline: pipeline)
                }

            case .choosingCullMode(let sessionId, let pipeline):
                CullChoiceView(
                    sessionId: sessionId,
                    onFilterThenRank: {
                        appState = .culling(sessionId: sessionId, pipeline: pipeline)
                    },
                    onRankOnly: {
                        appState = .comparing(sessionId: sessionId, pipeline: pipeline)
                    }
                )

            case .culling(let sessionId, let pipeline):
                CullView(
                    sessionId: sessionId,
                    pipeline: pipeline,
                    onComplete: {
                        appState = .comparing(sessionId: sessionId, pipeline: pipeline)
                    }
                )

            case .comparing(let sessionId, let pipeline):
                ComparisonView(
                    sessionId: sessionId,
                    pipeline: pipeline,
                    onSkipToResults: {
                        appState = .complete(sessionId: sessionId, totalComparisons: 0)
                    },
                    onComplete: { totalComparisons in
                        appState = .complete(sessionId: sessionId, totalComparisons: totalComparisons)
                    }
                )
```

(`.complete` and `.results` cases are unchanged.)

- [ ] **Step 2: `SessionSetupView.swift` — construct the pipeline**

Change the callback type (line 8) to:

```swift
    var onStart: (UUID, PhotoPipeline) -> Void
```

Replace `startSession()`:

```swift
    private func startSession() {
        guard let userId = auth.userId else { return }
        let items = selectedItems
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let session = try await api.createSession(photoCount: items.count)
                let pipeline = PhotoPipeline(
                    transport: SupabaseUploadTransport(supabase: auth.storageClient, api: api),
                    sessionId: session.id,
                    userId: userId
                )
                pipeline.start(photos: items.map { PendingPhoto(loader: PickerItemLoader(item: $0)) })
                onStart(session.id, pipeline)
            } catch {
                errorMessage = "Could not start: \(error.localizedDescription)"
                isStarting = false
            }
        }
    }
```

- [ ] **Step 3: `CullChoiceView.swift` — remove the upload banner**

Delete the `@ObservedObject var uploadService: UploadService` property, the `uploadBanner` computed property (lines 94–121), and the `uploadBanner` reference in the body (line 19). The view now takes only `sessionId`, `onFilterThenRank`, `onRankOnly` (and keeps its `@EnvironmentObject` api).

- [ ] **Step 4: `CullView.swift` — local cards + decision routing**

Property and state changes at the top of the struct:

```swift
    let sessionId: UUID
    @ObservedObject var pipeline: PhotoPipeline
    var onComplete: () -> Void

    @State private var decisionStore  = DecisionStore()
    @State private var cardProvider:    LocalCardProvider?
    @State private var syncService:     SyncService?
    @State private var currentCard:     LocalCardProvider.Card?
    @State private var dragOffset:      CGFloat = 0
    @State private var isFinishing      = false
    @State private var finishFailed     = false
    @State private var isInitialized    = false
    @State private var expandedCard:     LocalCardProvider.Card?
```

Replace `initialize()`:

```swift
    private func initialize() async {
        let provider = LocalCardProvider(pipeline: pipeline)
        let p = pipeline
        let ss = SyncService(
            sessionId: sessionId,
            api: api,
            registrationState: { p.registrationState(for: $0) }
        )
        cardProvider = provider
        syncService  = ss
        // Late registrations unblock their pending keep/drop decisions.
        pipeline.onRegistered = { _ in ss.syncIfNeeded() }

        async let syncReady: Void = ss.start(store: decisionStore)
        let decidedIds = await decisionStore.load(sessionId: sessionId)
        await provider.start(excluding: decidedIds)
        await syncReady

        currentCard   = provider.advance()
        isInitialized = true
    }
```

In the body and helpers, rename every `prefetchService` to `cardProvider` and every `CullPrefetchService.PrefetchedCard` to `LocalCardProvider.Card` (the `switch cardProvider?.state`, both `onChange` handlers, `cardStack(card:)`, `bottomButtons(card:)`, and the `retry()` button keep their existing structure).

In `topBar`, replace the upload-derived count and failure line (lines 109–119) with:

```swift
            if pipeline.totalCount > 0 {
                let remaining = max(0, pipeline.totalCount - decisionStore.decisions.count)
                Text("\(remaining) remaining")
                    .font(.captionSerif)
                    .foregroundStyle(Color.secondaryText)
            }
```

In `commitDecision`, route the decision to the pipeline before the sync call:

```swift
    private func commitDecision(_ decision: CullDecision, card: LocalCardProvider.Card) {
        // Hot path: zero blocking — record in-memory, pop next card from queue
        decisionStore.record(photoId: card.photoId, decision: decision)
        pipeline.setDecision(photoId: card.photoId, decision: decision)
        syncService?.syncIfNeeded()
        // ... (animation and advance() unchanged)
```

- [ ] **Step 5: `ComparisonView.swift` — registered-count gate, quiet failure line**

Replace the `uploadService` property:

```swift
    @ObservedObject var pipeline: PhotoPipeline
```

Delete the `uploadBanner` computed property (lines 104–146) and its reference in the body (line 32). In its place at the top of the `VStack`, add the quiet failure line:

```swift
                if !pipeline.failedIds.isEmpty {
                    Button {
                        pipeline.retryParked()
                    } label: {
                        Text("\(pipeline.failedIds.count) photo\(pipeline.failedIds.count == 1 ? "" : "s") couldn't be included — tap to retry")
                            .font(.captionSerif)
                            .foregroundStyle(Color.secondaryText)
                    }
                    .padding(.vertical, 6)
                }
```

In `fetchNextPair()`, replace the upload-wait loop (lines 321–336) with:

```swift
        // A pair only needs 2 registered photos; registeredCount increments
        // as register-photo succeeds — wait on local state instead of
        // burning network round trips on guaranteed 422s.
        while pipeline.registeredCount < 2 {
            if pipeline.isComplete {
                errorMessage = "Not enough photos could be uploaded. Please go back and try again."
                waitingForUploads = false
                isLoading = false
                return
            }
            waitingForUploads = true
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        waitingForUploads = false
```

- [ ] **Step 6: Delete the old upload path**

```bash
rm ios/Sources/App/Services/UploadService.swift ios/Sources/App/Services/CullPrefetchService.swift
```

In `ios/Sources/App/Services/APIClient.swift`, delete the `prefetchCull` method and its `// MARK: - prefetch-cull` comment (lines ~216–237).
In `ios/Sources/App/Models/Models.swift`, delete `PrefetchCullCard` and `PrefetchCullResponse` (lines ~223–236).

Verify nothing references the removed symbols:

```bash
grep -rn "UploadService\|CullPrefetchService\|prefetchCull\|PrefetchCull" ios/Sources ios/Tests
```

Expected: no matches.

- [ ] **Step 7: Regenerate, run the full suite**

Run the iOS test command from the header (xcodegen regenerates after the deletions).
Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add -A ios
git commit -m "feat(ios): local-first cull and invisible background upload

Cull cards render from on-device compressed copies via LocalCardProvider;
PhotoPipeline replaces UploadService with a retrying, keeper-priority
background queue; dropped photos never upload. Upload banners removed."
```

---

### Task 9: Full verification

- [ ] **Step 1: Backend suite**

Run: `cd backend/supabase/functions && deno fmt --check . && deno lint . && deno test --allow-env _shared/`
Expected: all PASS.

- [ ] **Step 2: iOS suite**

Run the iOS test command from the header.
Expected: all PASS.

- [ ] **Step 3: Ranking engine (untouched — sanity only)**

Run: `cd ranking-engine && npm test`
Expected: PASS, no changes.

- [ ] **Step 4: Manual smoke test (simulator)**

Launch the app in the simulator, select ~20 photos, choose "Filter then rank":
- First cull card appears in < 1s with no upload banner anywhere.
- Swiping is instant; toggling the network off mid-cull does not interrupt culling.
- After "Done — start comparing", the first pair appears (keeper uploads were prioritized).
- Drop a few photos early, then check Supabase storage: dropped photos' objects were never created.

- [ ] **Step 5: Commit any straggler fixes, then hand off for review**
