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
}
