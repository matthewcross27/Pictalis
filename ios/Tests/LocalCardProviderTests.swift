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
