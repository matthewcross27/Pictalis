import Sentry
import UIKit

enum CullQueueState: Equatable {
    case loading
    case ready
    case exhausted
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
    private var remainingCursor = 0      // index of the next id in `remaining` to queue
    private var hasRemaining: Bool { remainingCursor < remaining.count }
    private var isFilling = false
    private var currentMaxQueueSize = LocalCardProvider.normalQueueSize
    @ObservationIgnored nonisolated(unsafe) private var fillTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

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
        fillTask?.cancel()
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Decode just the first card before returning (sub-second first paint),
    // then keep filling the decode-ahead window in the background.
    func start(excluding decidedIds: [UUID]) async {
        let decided = Set(decidedIds)
        remaining = pipeline.order.filter { !decided.contains($0) }
        remainingCursor = 0
        await fill(target: 1)
        if queue.isEmpty && !hasRemaining {
            state = .exhausted
        } else if !queue.isEmpty {
            state = .ready
        }
        fillTask?.cancel()
        fillTask = Task { await self.fill() }
    }

    func advance() -> Card? {
        guard !queue.isEmpty else {
            if !hasRemaining { state = .exhausted }
            return nil
        }
        let card = queue.removeFirst()
        if queue.isEmpty && !hasRemaining {
            state = .exhausted
        } else {
            fillTask?.cancel()
            fillTask = Task { await self.fill() }
        }
        return card
    }

    // MARK: - Private

    private func fill(target: Int? = nil) async {
        guard !isFilling else { return }
        isFilling = true
        defer { isFilling = false }

        while queue.count < (target ?? currentMaxQueueSize), hasRemaining {
            let id = remaining[remainingCursor]
            remainingCursor += 1
            do {
                let image = try await pipeline.displayImage(for: id)
                queue.append(Card(photoId: id, image: image))
                if state == .loading { state = .ready }
            } catch {
                // Card just isn't showable (dropped elsewhere or unreadable) — the
                // deck moves on regardless, but a materialize failure here is still
                // silent to the user in this swipe-deck flow (unlike ComparisonView's
                // failedIds banner), so it's worth capturing for production visibility.
                SentrySDK.capture(error: error)
                continue
            }
        }
        if queue.isEmpty && !hasRemaining { state = .exhausted }
    }

    private func handleMemoryWarning() {
        currentMaxQueueSize = Self.minQueueSize
        if queue.count > currentMaxQueueSize {
            // Evict from the tail (furthest from display); ids go back in front
            // of the remaining cursor so they re-decode next, in order.
            let evicted = queue.suffix(queue.count - currentMaxQueueSize).map(\.photoId)
            queue.removeLast(queue.count - currentMaxQueueSize)
            remaining.insert(contentsOf: evicted, at: remainingCursor)
        }
    }
}
