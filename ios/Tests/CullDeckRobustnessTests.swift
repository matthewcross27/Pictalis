import XCTest
@testable import Pictalis

final class WithTimeoutTests: XCTestCase {

    func testReturnsResultWhenOperationFinishesInTime() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await withTimeout(.seconds(5)) { () async throws -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testThrowsTimeoutEvenWhenOperationIgnoresCancellation() async {
        let start = ContinuousClock.now
        do {
            // Awaiting a detached task's value does not propagate cancellation, so this
            // models loadTransferable ignoring it: a task group would wait the full 2s.
            _ = try await withTimeout(.milliseconds(100)) {
                await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error is TimeoutError)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }
}

@MainActor
final class PipelineHungPhotoTests: XCTestCase {

    func testHungLoadIsMarkedFailedAfterTimeout() async throws {
        let hung = PendingPhoto(loader: HangingLoader())
        let pipeline = makeTestPipeline(materializeTimeout: .milliseconds(50))
        pipeline.start(photos: [hung])

        try await waitUntil { pipeline.registrationState(for: hung.id) == .unavailable }
        XCTAssertEqual(pipeline.availability(for: hung.id), .unavailable)
        XCTAssertEqual(pipeline.failedIds, [hung.id])
    }

    func testWaiterOnPendingPhotoTimesOut() async throws {
        let hung = PendingPhoto(loader: HangingLoader())
        let pipeline = makeTestPipeline(waiterTimeout: .milliseconds(50))
        pipeline.start(photos: [hung])

        do {
            _ = try await pipeline.materializedFileURL(for: hung.id)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? PipelineError, .timedOut)
        }
    }

    func testFirstMaterializedSkipsPendingAndFailedAheadOfReadyPhoto() async throws {
        let photos = [
            PendingPhoto(loader: MockLoader(data: nil)),
            PendingPhoto(loader: HangingLoader()),
            PendingPhoto(loader: MockLoader()),
        ]
        let pipeline = makeTestPipeline(materializeConcurrency: 3)
        pipeline.start(photos: photos)

        let ready = try await pipeline.firstMaterialized(among: photos.map(\.id))
        XCTAssertEqual(ready, photos[2].id)
    }

    func testFirstMaterializedThrowsWhenNothingCanMaterialize() async throws {
        let photo = PendingPhoto(loader: MockLoader(data: nil))
        let pipeline = makeTestPipeline()
        pipeline.start(photos: [photo])
        try await waitUntil { pipeline.availability(for: photo.id) == .unavailable }

        do {
            _ = try await pipeline.firstMaterialized(among: [photo.id])
            XCTFail("expected photoUnavailable")
        } catch {
            XCTAssertEqual(error as? PipelineError, .photoUnavailable)
        }
    }

    func testItemStateSummaryNamesFirstItems() async throws {
        let photos = (0..<3).map { _ in PendingPhoto(loader: HangingLoader()) }
        let pipeline = makeTestPipeline()
        pipeline.start(photos: photos)

        let summary = pipeline.itemStateSummary(first: 2)
        XCTAssertEqual(summary.count, 2)
        XCTAssertTrue(summary[0].hasPrefix(photos[0].id.uuidString.prefix(8)))
        XCTAssertTrue(summary[0].hasSuffix("=pending"))
        XCTAssertEqual(pipeline.materializedCount, 0)
    }
}

@MainActor
final class LocalCardProviderSkipAheadTests: XCTestCase {

    func testHungHeadOfLinePhotoDoesNotBlockFirstCard() async throws {
        let photos = [
            PendingPhoto(loader: HangingLoader()),
            PendingPhoto(loader: MockLoader()),
            PendingPhoto(loader: MockLoader()),
        ]
        let pipeline = makeTestPipeline(materializeConcurrency: 3)
        pipeline.start(photos: photos)
        let provider = LocalCardProvider(pipeline: pipeline)

        await provider.start(excluding: [])
        try await waitUntil { provider.queue.count == 2 }

        // Both good photos load concurrently, so either may be queued first; the hung
        // head-of-line photo must not be one of them.
        XCTAssertEqual(provider.state, .ready)
        let shown = [provider.advance()?.photoId, provider.advance()?.photoId]
        XCTAssertEqual(Set(shown.compactMap { $0 }), [photos[1].id, photos[2].id])
    }

    func testHungPhotoIsSkippedForGoodOnceTimedOutAndDeckExhausts() async throws {
        let photos = [
            PendingPhoto(loader: HangingLoader()),
            PendingPhoto(loader: MockLoader()),
        ]
        let pipeline = makeTestPipeline(materializeConcurrency: 2, materializeTimeout: .milliseconds(50))
        pipeline.start(photos: photos)
        let provider = LocalCardProvider(pipeline: pipeline)

        await provider.start(excluding: [])
        XCTAssertEqual(provider.advance()?.photoId, photos[1].id)
        try await waitUntil { provider.state == .exhausted }
    }

    func testStoppedProviderStopsFilling() async throws {
        let photos = (0..<3).map { _ in PendingPhoto(loader: MockLoader()) }
        let pipeline = makeTestPipeline()
        pipeline.start(photos: photos)
        let provider = LocalCardProvider(pipeline: pipeline)
        await provider.start(excluding: [])
        provider.stop()
        let queued = provider.queue.count

        _ = provider.advance()          // would normally kick off another fill
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(provider.queue.count, queued)
    }

    func testSnapshotDescribesDeckState() async throws {
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        let pipeline = makeTestPipeline()
        pipeline.start(photos: photos)
        let provider = LocalCardProvider(pipeline: pipeline)
        await provider.start(excluding: [])

        let snapshot = provider.snapshot()
        XCTAssertEqual(snapshot["provider_state"], "ready")
        XCTAssertNotNil(snapshot["queue_count"])
        XCTAssertNotNil(snapshot["cursor"])
    }
}

@MainActor
final class CullBootstrapTests: XCTestCase {

    // The failure this guards against: the first card was gated on the sync service
    // starting, with no time limit. Here the sync start never finishes.
    func testFirstCardDoesNotWaitForSyncStart() async throws {
        let photos = [PendingPhoto(loader: MockLoader())]
        let pipeline = makeTestPipeline()
        pipeline.start(photos: photos)
        let provider = LocalCardProvider(pipeline: pipeline)
        var syncStartReturned = false

        let syncTask = await CullBootstrap.run(
            store: DecisionStore(),
            sessionId: UUID(),
            provider: provider,
            startSync: {
                try? await Task.sleep(for: .seconds(3600))
                syncStartReturned = true
            }
        )
        defer { syncTask.cancel() }

        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.queue.map(\.photoId), [photos[0].id])
        XCTAssertFalse(syncStartReturned)
    }

    // The captain's safety requirement: with the sync service starting late, a photo
    // dropped in the meantime is saved locally and reaches the server in the first send.
    func testDropMadeBeforeSyncStartsReachesServerWhenItStarts() async throws {
        let photos = (0..<2).map { _ in PendingPhoto(loader: MockLoader()) }
        let pipeline = makeTestPipeline()
        pipeline.start(photos: photos)
        let provider = LocalCardProvider(pipeline: pipeline)
        let store = DecisionStore()
        let api = MockSubmitter()
        let sync = SyncService(
            sessionId: UUID(),
            api: api,
            registrationState: { pipeline.registrationState(for: $0) },
            connectivityEvents: AsyncStream<Void> { _ in }
        )
        sync.attach(store: store)
        var releaseSync = false

        let syncTask = await CullBootstrap.run(
            store: store,
            sessionId: UUID(),
            provider: provider,
            startSync: {
                while !releaseSync { try? await Task.sleep(for: .milliseconds(5)) }
                await sync.start(store: store)
            }
        )

        // The user drops the first card while the sync service has not started.
        let card = try XCTUnwrap(provider.advance())
        store.record(photoId: card.photoId, decision: .drop)
        pipeline.setDecision(photoId: card.photoId, decision: .drop)
        sync.syncIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.pendingDecisions.map(\.photoId).count + api.submitted.count, 1)

        releaseSync = true
        await syncTask.value

        XCTAssertEqual(api.submitted, [card.photoId])
        XCTAssertTrue(store.pendingDecisions.isEmpty)
    }
}

@MainActor
final class SyncServiceLateStartTests: XCTestCase {

    private func makeService(_ api: MockSubmitter) -> SyncService {
        SyncService(
            sessionId: UUID(),
            api: api,
            registrationState: { _ in .registered },
            connectivityEvents: AsyncStream<Void> { _ in }
        )
    }

    func testDecisionRecordedBeforeStartIsInFirstSend() async throws {
        let api = MockSubmitter()
        let store = DecisionStore()
        let service = makeService(api)
        let dropped = UUID()
        store.record(photoId: dropped, decision: .drop)    // saved locally, service not started

        await service.start(store: store)

        XCTAssertEqual(api.submitted, [dropped])
        XCTAssertEqual(api.callCount, 1)
        XCTAssertTrue(store.pendingDecisions.isEmpty)
    }

    func testFlushBeforeStartStillSendsPendingDecisions() async throws {
        let api = MockSubmitter()
        let store = DecisionStore()
        let service = makeService(api)
        service.attach(store: store)
        let dropped = UUID()
        store.record(photoId: dropped, decision: .drop)

        await service.flush()                               // Done tapped before start() ran

        XCTAssertEqual(api.submitted, [dropped])
        XCTAssertTrue(store.pendingDecisions.isEmpty)
    }
}
