import XCTest
@testable import Pictalis

final class SyncPartitionTests: XCTestCase {
    func testPartitionsByRegistrationState() {
        let registered = UUID()
        let failed = UUID()
        let decisions = [
            StoredDecision(photoId: registered, decision: .keep, timestamp: .now, synced: false),
            StoredDecision(photoId: failed, decision: .drop, timestamp: .now, synced: false),
        ]
        let states: [UUID: PhotoRegistrationState] = [
            registered: .registered,
            failed: .unavailable,
        ]

        let (send, markLocalOnly) = SyncService.partition(
            pending: decisions,
            registrationState: { states[$0] ?? .registered }
        )

        XCTAssertEqual(send.map(\.photoId), [registered])
        XCTAssertEqual(markLocalOnly, [failed])
    }
}

// Records every photo_id ever submitted. `paused` holds responses open so a
// test can keep a drain in flight while it records another decision.
@MainActor
final class MockSubmitter: CullDecisionSubmitting {
    private(set) var submitted: [UUID] = []
    private(set) var callCount = 0
    var paused = false

    func batchSubmitCull(sessionId: UUID, decisions: [StoredDecision]) async throws -> BatchSubmitResponse {
        callCount += 1
        while paused { try? await Task.sleep(for: .milliseconds(5)) }
        submitted.append(contentsOf: decisions.map(\.photoId))
        return BatchSubmitResponse(
            results: decisions.map { BatchDecisionResult(photoId: $0.photoId, success: true, error: nil) }
        )
    }
}

@MainActor
final class SyncServiceFlushTests: XCTestCase {

    private func makeService(_ api: MockSubmitter) -> SyncService {
        SyncService(sessionId: UUID(), api: api, registrationState: { _ in .registered })
    }

    // The leak that put dropped photos into ranking: a decision recorded while a
    // background drain is in flight is dropped by the coalesced drain() (its
    // isDraining guard early-returns), so it never reaches the server.
    func testCoalescedDrainMissesDecisionRecordedInFlight() async throws {
        let api = MockSubmitter()
        let store = DecisionStore()
        let service = makeService(api)
        await service.start(store: store)

        let a = UUID(), b = UUID()
        api.paused = true
        store.record(photoId: a, decision: .drop)
        service.syncIfNeeded()                              // drain starts, hangs in submit
        try await waitUntil { api.callCount >= 1 }
        store.record(photoId: b, decision: .drop)           // recorded while drain in flight

        await service.drain()                               // coalesced: no-op (isDraining)
        api.paused = false
        try await waitUntil { api.submitted.contains(a) }

        XCTAssertTrue(api.submitted.contains(a))
        XCTAssertFalse(api.submitted.contains(b))           // the leak: b never sent
    }

    // flush() is the finish() backstop: it guarantees the same in-flight decision
    // reaches the server before ranking starts.
    func testFlushDeliversDecisionRecordedInFlight() async throws {
        let api = MockSubmitter()
        let store = DecisionStore()
        let service = makeService(api)
        await service.start(store: store)

        let a = UUID(), b = UUID()
        api.paused = true
        store.record(photoId: a, decision: .drop)
        service.syncIfNeeded()                              // drain starts, hangs in submit
        try await waitUntil { api.callCount >= 1 }
        store.record(photoId: b, decision: .drop)           // recorded while drain in flight

        let flush = Task { await service.flush() }
        try await Task.sleep(for: .milliseconds(20))        // let flush attempt while paused
        api.paused = false
        await flush.value

        XCTAssertTrue(api.submitted.contains(a))
        XCTAssertTrue(api.submitted.contains(b))            // both delivered
        XCTAssertTrue(store.pendingDecisions.isEmpty)       // and marked synced
    }
}
