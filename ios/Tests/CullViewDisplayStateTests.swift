import XCTest
import UIKit
@testable import Pictalis

final class CullViewDisplayStateTests: XCTestCase {

    private func makeCard() -> LocalCardProvider.Card {
        LocalCardProvider.Card(photoId: UUID(), image: UIImage())
    }

    func testReadyWithNoCurrentCardFallsBackToLoadingNotBlank() {
        // Regression test: the provider sets state = .ready as soon as it queues a card, a
        // beat before the view takes that card as currentCard, so this combination is
        // reachable. It must resolve to a visible spinner, never to a state the view
        // renders nothing for.
        XCTAssertEqual(CullView.displayState(for: .ready, currentCard: nil), .loading)
    }

    func testReadyWithCurrentCardShowsCard() {
        XCTAssertEqual(CullView.displayState(for: .ready, currentCard: makeCard()), .card)
    }

    func testLoadingShowsLoadingRegardlessOfCard() {
        XCTAssertEqual(CullView.displayState(for: .loading, currentCard: nil), .loading)
        XCTAssertEqual(CullView.displayState(for: .loading, currentCard: makeCard()), .loading)
    }

    func testExhaustedShowsExhausted() {
        XCTAssertEqual(CullView.displayState(for: .exhausted, currentCard: nil), .exhausted)
    }

    func testNilProviderStateDefaultsToLoading() {
        XCTAssertEqual(CullView.displayState(for: nil, currentCard: nil), .loading)
    }

    func testStalledFlagShowsStalledUnlessCardOrExhausted() {
        XCTAssertEqual(CullView.displayState(for: .ready, currentCard: nil, isStalled: true), .stalled)
        XCTAssertEqual(CullView.displayState(for: .loading, currentCard: nil, isStalled: true), .stalled)
        XCTAssertEqual(CullView.displayState(for: nil, currentCard: nil, isStalled: true), .stalled)
        // A late card beats a stale stalled flag.
        XCTAssertEqual(CullView.displayState(for: .ready, currentCard: makeCard(), isStalled: true), .card)
        XCTAssertEqual(CullView.displayState(for: .exhausted, currentCard: nil, isStalled: true), .exhausted)
    }

    func testWatchdogFiresOnlyWhenPhotosAreOnDiskWithNoCard() {
        XCTAssertEqual(
            CullView.watchdogVerdict(queueState: .ready, currentCard: nil, materializedCount: 1), .stalled)
        XCTAssertEqual(
            CullView.watchdogVerdict(queueState: .loading, currentCard: nil, materializedCount: 253), .stalled)
        // Nothing on disk yet: still loading, not a fault.
        XCTAssertEqual(
            CullView.watchdogVerdict(queueState: .loading, currentCard: nil, materializedCount: 0), .waiting)
        XCTAssertEqual(
            CullView.watchdogVerdict(queueState: nil, currentCard: nil, materializedCount: 0), .waiting)
        XCTAssertEqual(
            CullView.watchdogVerdict(queueState: .ready, currentCard: makeCard(), materializedCount: 5), .resolved)
        XCTAssertEqual(
            CullView.watchdogVerdict(queueState: .exhausted, currentCard: nil, materializedCount: 5), .resolved)
    }
}
