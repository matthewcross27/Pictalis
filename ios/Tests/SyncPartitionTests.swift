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
