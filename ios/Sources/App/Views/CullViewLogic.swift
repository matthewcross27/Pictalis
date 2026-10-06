import Foundation

// The pure decisions behind CullView's body and watchdog, kept apart from the view so they
// can be unit-tested directly (see CullViewDisplayStateTests).
extension CullView {
    static func displayState(
        for queueState: CullQueueState?,
        currentCard: LocalCardProvider.Card?,
        finishErrorMessage: String? = nil,
        isStalled: Bool = false
    ) -> CullDisplayState {
        if queueState == .exhausted, let finishErrorMessage {
            return .finishFailed(message: finishErrorMessage)
        }
        switch queueState ?? .loading {
        case .exhausted:
            return .exhausted
        case .ready where currentCard != nil:
            return .card
        case .ready, .loading:
            return isStalled ? .stalled : .loading
        }
    }

    static func shouldFinishCull(onQueueState queueState: CullQueueState?, isFinishing: Bool) -> Bool {
        queueState == .exhausted && !isFinishing
    }

    // Stalled means the deck has no card to show even though photos are already on disk -
    // waiting for photos that have not materialized yet is just loading, not a fault.
    static func watchdogVerdict(
        queueState: CullQueueState?,
        currentCard: LocalCardProvider.Card?,
        materializedCount: Int
    ) -> CullWatchdogVerdict {
        if currentCard != nil || queueState == .exhausted { return .resolved }
        return materializedCount > 0 ? .stalled : .waiting
    }
}
