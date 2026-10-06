import XCTest
import UIKit
@testable import Pictalis

final class CullViewDisplayStateTests: XCTestCase {

    private func makeCard() -> LocalCardProvider.Card {
        LocalCardProvider.Card(photoId: UUID(), image: UIImage())
    }

    func testReadyWithNoCurrentCardFallsBackToLoadingNotBlank() {
        // Regression test: LocalCardProvider.start(excluding:) sets state = .ready
        // synchronously before CullView.initialize() finishes awaiting syncReady and
        // setting currentCard, so this combination is reachable mid-initialization.
        // It must resolve to a visible spinner, never to a state the view renders nothing for.
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

    func testExhaustedWithFinishErrorShowsFinishFailed() {
        // Regression test: a failed finishCull network call used to leave the exhausted
        // deck showing an indefinite spinner with no way to retry from the main content area.
        XCTAssertEqual(
            CullView.displayState(for: .exhausted, currentCard: nil, finishErrorMessage: "Couldn't reach the server."),
            .finishFailed(message: "Couldn't reach the server.")
        )
    }

    func testNilProviderStateDefaultsToLoading() {
        XCTAssertEqual(CullView.displayState(for: nil, currentCard: nil), .loading)
    }
}

final class CullViewFinishTests: XCTestCase {

    func testExhaustedQueueFinishesCullSoServerMovesToRanking() {
        // Regression test: exhausting the deck used to call onComplete() directly, skipping
        // finish-cull, so the session stayed at stage 'cull' and the comparison screen's
        // badge read "Cull" during ranking.
        XCTAssertTrue(CullView.shouldFinishCull(onQueueState: .exhausted, isFinishing: false))
    }

    func testExhaustedQueueDoesNotFinishTwiceWhileDoneIsInFlight() {
        XCTAssertFalse(CullView.shouldFinishCull(onQueueState: .exhausted, isFinishing: true))
    }

    func testNonExhaustedStatesDoNotFinishCull() {
        XCTAssertFalse(CullView.shouldFinishCull(onQueueState: .loading, isFinishing: false))
        XCTAssertFalse(CullView.shouldFinishCull(onQueueState: .ready, isFinishing: false))
        XCTAssertFalse(CullView.shouldFinishCull(onQueueState: nil, isFinishing: false))
    }
}
