import UIKit
import XCTest
@testable import Pictalis

// MARK: - Test fixtures

enum TestImage {
    static func make(width: CGFloat = 64, height: CGFloat = 48, color: UIColor = .systemTeal) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func jpegData(width: CGFloat = 64, height: CGFloat = 48) -> Data {
        make(width: width, height: height).jpegData(compressionQuality: 0.8)!
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
    private(set) var markedUploadedIds: [UUID] = []
    private(set) var registerBatches: [[UUID]] = []
    private(set) var registerCallTimes: [ContinuousClock.Instant] = []
    private(set) var markCompleteCount = 0
    var uploadFailures: [UUID: Int] = [:]
    // Per-photo registration refusals: the call succeeds but this photo's result is a failure.
    var markUploadedFailures: [UUID: Int] = [:]
    // Whole-request failures, thrown one per call (in order) before any photo is processed.
    var registerErrors: [Error] = []
    var uploadDelay: Duration = .zero

    // Gated uploads: a gated photo's upload blocks (after announcing it started)
    // until the test releases it — lets a test act while the photo is mid-upload.
    var gatedIds: Set<UUID> = []
    private(set) var startedIds: Set<UUID> = []
    var releasedIds: Set<UUID> = []

    private func photoId(fromPath path: String) -> UUID? {
        guard let filename = path.split(separator: "/").last else { return nil }
        return UUID(uuidString: String(filename.dropLast(4)))
    }

    func upload(storagePath: String, data: Data) async throws {
        if let id = photoId(fromPath: storagePath), gatedIds.contains(id) {
            startedIds.insert(id)
            while !releasedIds.contains(id) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        if uploadDelay > .zero { try? await Task.sleep(for: uploadDelay) }
        if let id = photoId(fromPath: storagePath), let n = uploadFailures[id], n > 0 {
            uploadFailures[id] = n - 1
            throw MockTransportError()
        }
        uploadedPaths.append(storagePath)
    }

    func registerPhotos(sessionId: UUID, photos: [PhotoRegistration]) async throws -> [PhotoRegistrationResult] {
        registerBatches.append(photos.map(\.photoId))
        registerCallTimes.append(ContinuousClock.now)
        if !registerErrors.isEmpty { throw registerErrors.removeFirst() }
        return photos.map { photo in
            if let n = markUploadedFailures[photo.photoId], n > 0 {
                markUploadedFailures[photo.photoId] = n - 1
                return PhotoRegistrationResult(photoId: photo.photoId, success: false)
            }
            markedUploadedIds.append(photo.photoId)
            return PhotoRegistrationResult(photoId: photo.photoId, success: true)
        }
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

@MainActor
func makeTestPipeline(
    transport: MockTransport? = nil,
    retryDelays: [Duration] = [],
    materializeConcurrency: Int = 1,
    uploadConcurrency: Int = 1,
    registrationBatchSize: Int = 25,
    registrationFlushDelay: Duration = .milliseconds(20),
    parkedRetryBaseDelay: Duration = .seconds(3600),
    connectivity: AsyncStream<Void> = AsyncStream { $0.finish() }
) -> PhotoPipeline {
    PhotoPipeline(
        transport: transport ?? MockTransport(),
        sessionId: UUID(),
        userId: UUID(),
        retryDelays: retryDelays,
        materializeConcurrency: materializeConcurrency,
        uploadConcurrency: uploadConcurrency,
        registrationBatchSize: registrationBatchSize,
        registrationFlushDelay: registrationFlushDelay,
        parkedRetryBaseDelay: parkedRetryBaseDelay,
        connectivityEvents: connectivity
    )
}

// MARK: - Tests

@MainActor
final class PhotoPipelineTests: XCTestCase {

    func testMaterializesPhotoToDisk() async throws {
        let pipeline = makeTestPipeline(transport: MockTransport())
        let photo = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [photo])

        let url = try await pipeline.materializedFileURL(for: photo.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let image = UIImage(data: try Data(contentsOf: url))
        XCTAssertNotNil(image)
    }

    func testDisplayImageDecodesMaterializedPhoto() async throws {
        let pipeline = makeTestPipeline(transport: MockTransport())
        let photo = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [photo])

        let image = try await pipeline.displayImage(for: photo.id)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testMaterializeFailureMarksFailed() async throws {
        let pipeline = makeTestPipeline(transport: MockTransport())
        let bad = PendingPhoto(loader: MockLoader(data: nil))
        let good = PendingPhoto(loader: MockLoader())
        pipeline.start(photos: [bad, good])

        try await waitUntil { pipeline.failedIds == [bad.id] }
        do {
            _ = try await pipeline.displayImage(for: bad.id)
            XCTFail("expected photoUnavailable")
        } catch {}
    }

    func testUploadsAndRegistersAllPhotos() async throws {
        let transport = MockTransport()
        let pipeline = makeTestPipeline(transport: transport, uploadConcurrency: 4)
        let photos = (0..<5).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 5)
        XCTAssertEqual(Set(transport.markedUploadedIds), Set(photos.map(\.id)))
        XCTAssertEqual(transport.markCompleteCount, 1)
        XCTAssertTrue(pipeline.failedIds.isEmpty)
    }

    func testKeptPhotoJumpsQueue() async throws {
        let transport = MockTransport()
        transport.uploadDelay = .milliseconds(50)
        let pipeline = makeTestPipeline(transport: transport)
        let photos = (0..<5).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        // With materialize+upload concurrency 1 and a 50ms upload delay,
        // photo 0 is mid-upload while later photos queue behind it.
        pipeline.setDecision(photoId: photos[4].id, decision: .keep)

        try await waitUntil { pipeline.isComplete }
        // The kept photo must register before undecided photo 2.
        let registered = transport.markedUploadedIds
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
        transport.markUploadedFailures[photos[1].id] = 2
        let pipeline = makeTestPipeline(transport: transport, retryDelays: [.zero, .zero, .zero])
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 3)
        XCTAssertTrue(pipeline.failedIds.isEmpty)
    }

    func testExhaustedRetriesPark() async throws {
        let transport = MockTransport()
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.uploadFailures[photos[1].id] = 99
        let pipeline = makeTestPipeline(transport: transport, retryDelays: [.zero])
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isSettled }
        XCTAssertEqual(pipeline.registeredCount, 2)
        XCTAssertEqual(pipeline.failedIds, [photos[1].id])
        // A parked photo is not registered, so the session must not be marked complete.
        XCTAssertFalse(pipeline.isComplete)
        XCTAssertEqual(transport.markCompleteCount, 0)
    }

    func testDropCancelsQueuedUpload() async throws {
        let transport = MockTransport()
        transport.uploadDelay = .milliseconds(50)
        let pipeline = makeTestPipeline(transport: transport)
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        // Wait until photo 2 is materialized (so it has a tmp file), then drop
        // it while photo 0 is still mid-upload behind the 50ms delay.
        let fileURL = try await pipeline.materializedFileURL(for: photos[2].id)
        pipeline.setDecision(photoId: photos[2].id, decision: .drop)

        try await waitUntil { pipeline.isComplete }
        XCTAssertFalse(transport.markedUploadedIds.contains(photos[2].id))
        XCTAssertEqual(pipeline.registeredCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(pipeline.registrationState(for: photos[2].id), .registered)
        XCTAssertEqual(transport.markCompleteCount, 1)
    }

    func testDropWhileUploadingDoesNotRegister() async throws {
        let transport = MockTransport()
        let photo = PendingPhoto(loader: MockLoader())
        transport.gatedIds = [photo.id]
        let pipeline = makeTestPipeline(transport: transport)
        pipeline.start(photos: [photo])

        // Block until the upload is in-flight, so the drop lands while the
        // photo is .uploading (the leak window: it would otherwise register).
        try await waitUntil { transport.startedIds.contains(photo.id) }
        pipeline.setDecision(photoId: photo.id, decision: .drop)
        transport.releasedIds.insert(photo.id) // let the in-flight upload finish

        try await waitUntil { pipeline.isComplete }
        // Drop during upload: bytes may have gone to storage, but markUploaded was
        // not called — upload_status stays 'pending'. The server excludes this photo
        // via is_suppressed=true (set by batch-submit-cull for the drop decision).
        XCTAssertFalse(transport.markedUploadedIds.contains(photo.id))
        XCTAssertEqual(pipeline.registeredCount, 0)
        // Row exists (pre-registered) — registrationState is .registered, not .unavailable.
        XCTAssertEqual(pipeline.registrationState(for: photo.id), .registered)
    }

    func testDropAfterRegisteredIsNoop() async throws {
        let transport = MockTransport()
        let pipeline = makeTestPipeline(transport: transport)
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
        let pipeline = makeTestPipeline(transport: transport, connectivity: stream)
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isSettled }
        XCTAssertEqual(pipeline.failedIds, [photos[1].id])

        continuation.yield() // connectivity restored; failure budget is spent
        try await waitUntil { pipeline.registeredCount == 2 }
        XCTAssertTrue(pipeline.failedIds.isEmpty)
        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.markCompleteCount, 1)
    }

    func testRetryParkedRequeuesFailedPhotos() async throws {
        let transport = MockTransport()
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.markUploadedFailures[photos[0].id] = 1
        let pipeline = makeTestPipeline(transport: transport)
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isSettled }
        XCTAssertEqual(pipeline.failedIds, [photos[0].id])

        pipeline.retryParked()
        try await waitUntil { pipeline.registeredCount == 2 }
        XCTAssertTrue(pipeline.failedIds.isEmpty)
        // The storage upload already succeeded — the retry must not re-upload.
        XCTAssertEqual(transport.uploadedPaths.count, 2)
    }

    // MARK: - Batch registration

    func testRegistersInBatchesOfConfiguredSize() async throws {
        let transport = MockTransport()
        // A huge flush delay: only full batches may be sent.
        let pipeline = makeTestPipeline(
            transport: transport, uploadConcurrency: 4,
            registrationBatchSize: 5, registrationFlushDelay: .seconds(3600)
        )
        let photos = (0..<10).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.registerBatches.map(\.count), [5, 5])
        XCTAssertEqual(Set(transport.markedUploadedIds), Set(photos.map(\.id)))
    }

    func testPartialBatchIsSentAfterFlushDelay() async throws {
        let transport = MockTransport()
        let pipeline = makeTestPipeline(
            transport: transport, uploadConcurrency: 4,
            registrationBatchSize: 25, registrationFlushDelay: .milliseconds(300)
        )
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.registerBatches.count, 1)
        XCTAssertEqual(Set(transport.registerBatches[0]), Set(photos.map(\.id)))
    }

    func testRefusedPhotoIsRetriedAloneInASecondRequest() async throws {
        let transport = MockTransport()
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.markUploadedFailures[photos[1].id] = 1
        let pipeline = makeTestPipeline(
            transport: transport, retryDelays: [.zero], uploadConcurrency: 3,
            registrationFlushDelay: .milliseconds(300)
        )
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 3)
        XCTAssertEqual(transport.registerBatches.count, 2)
        XCTAssertEqual(Set(transport.registerBatches[0]), Set(photos.map(\.id)))
        XCTAssertEqual(transport.registerBatches[1], [photos[1].id])
    }

    func testWholeRequestFailureRetriesTheBatch() async throws {
        let transport = MockTransport()
        transport.registerErrors = [MockTransportError()]
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        let pipeline = makeTestPipeline(
            transport: transport, retryDelays: [.zero], uploadConcurrency: 2,
            registrationFlushDelay: .milliseconds(300)
        )
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 2)
        XCTAssertEqual(transport.registerBatches.count, 2)
        XCTAssertEqual(Set(transport.registerBatches[1]), Set(photos.map(\.id)))
    }

    func testRateLimitedRequestWaitsForRetryAfter() async throws {
        let transport = MockTransport()
        transport.registerErrors = [APIError.rateLimited(retryAfter: 0.4)]
        let photo = PendingPhoto(loader: MockLoader())
        let pipeline = makeTestPipeline(transport: transport, retryDelays: [.zero])
        pipeline.start(photos: [photo])

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.registerCallTimes.count, 2)
        let gap = transport.registerCallTimes[1] - transport.registerCallTimes[0]
        XCTAssertGreaterThanOrEqual(gap, .milliseconds(400))
        XCTAssertEqual(pipeline.registeredCount, 1)
    }

    func testParkedPhotosRetryOnTimerWithGrowingBackoff() async throws {
        let transport = MockTransport()
        let photo = PendingPhoto(loader: MockLoader())
        transport.markUploadedFailures[photo.id] = 3
        // No inline retries: every refusal parks the photo, and only the timer retries it.
        let pipeline = makeTestPipeline(transport: transport, parkedRetryBaseDelay: .milliseconds(100))
        pipeline.start(photos: [photo])

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(pipeline.registeredCount, 1)
        XCTAssertTrue(pipeline.failedIds.isEmpty)
        let times = transport.registerCallTimes
        XCTAssertEqual(times.count, 4)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        // Delays double: ~100ms, ~200ms, ~400ms.
        XCTAssertGreaterThanOrEqual(gaps[0], .milliseconds(100))
        XCTAssertGreaterThanOrEqual(gaps[1], .milliseconds(200))
        XCTAssertGreaterThanOrEqual(gaps[2], .milliseconds(400))
    }

    func testSessionIsNotMarkedCompleteWhileAPhotoIsParked() async throws {
        let transport = MockTransport()
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.markUploadedFailures[photos[1].id] = 99
        let pipeline = makeTestPipeline(transport: transport)
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isSettled }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(pipeline.isComplete)
        XCTAssertEqual(transport.markCompleteCount, 0)

        transport.markUploadedFailures[photos[1].id] = 0
        pipeline.retryParked()
        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.markCompleteCount, 1)
        XCTAssertEqual(pipeline.registeredCount, 2)
    }

    func testDroppingAParkedPhotoLetsTheSessionComplete() async throws {
        let transport = MockTransport()
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        transport.markUploadedFailures[photos[1].id] = 99
        let pipeline = makeTestPipeline(transport: transport)
        pipeline.start(photos: photos)

        try await waitUntil { pipeline.isSettled }
        pipeline.setDecision(photoId: photos[1].id, decision: .drop)
        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.markCompleteCount, 1)
    }

    func testDropWhileAwaitingRegistrationSkipsIt() async throws {
        let transport = MockTransport()
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        let pipeline = makeTestPipeline(
            transport: transport, uploadConcurrency: 2,
            registrationFlushDelay: .milliseconds(500)
        )
        pipeline.start(photos: photos)

        // Both are uploaded and waiting on the 500ms flush; drop one before it fires.
        try await waitUntil { transport.uploadedPaths.count == 2 }
        pipeline.setDecision(photoId: photos[1].id, decision: .drop)

        try await waitUntil { pipeline.isComplete }
        XCTAssertEqual(transport.markedUploadedIds, [photos[0].id])
    }
}
