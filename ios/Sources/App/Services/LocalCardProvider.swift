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
        let image: UIImage
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
    private var isStopped = false
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

    // Abandons this provider (the deck is being rebuilt): stops filling, even if a fill is
    // parked waiting on a photo.
    func stop() {
        isStopped = true
        fillTask?.cancel()
    }

    // State for diagnostics when the deck is stuck.
    func snapshot() -> [String: String] {
        [
            "provider_state": String(describing: state),
            "queue_count": String(queue.count),
            "cursor": String(remainingCursor),
            "remaining_count": String(remaining.count),
            "is_filling": String(isFilling)
        ]
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

    // Fills the decode-ahead window with whichever undecided photos are on disk, preferring
    // selection order but never waiting on a photo that is still pending (slow, hung or
    // failed) while a later one is ready.
    private func fill(target: Int? = nil) async {
        guard !isFilling else { return }
        isFilling = true
        defer { isFilling = false }

        while !isStopped, queue.count < (target ?? currentMaxQueueSize) {
            dropUnavailable()
            guard hasRemaining else { break }
            let id: UUID
            do {
                id = try await pipeline.firstMaterialized(among: Array(remaining[remainingCursor...]))
            } catch {
                // timedOut: nothing new materialized yet, re-evaluate. photoUnavailable: every
                // candidate went away while waiting, dropUnavailable() clears them next pass.
                continue
            }
            guard !isStopped, let index = remaining[remainingCursor...].firstIndex(of: id) else { continue }
            if index == remainingCursor {
                remainingCursor += 1
            } else {
                remaining.remove(at: index)
            }
            do {
                let image = try await pipeline.displayImage(for: id)
                queue.append(Card(photoId: id, image: image))
                if state == .loading { state = .ready }
            } catch {
                // The file vanished or won't decode - the deck moves on regardless, but a
                // failure here is silent to the user in this swipe-deck flow (unlike
                // ComparisonView's failedIds banner), so it's worth capturing.
                ErrorReporter.capture(error)
                continue
            }
        }
        if queue.isEmpty && !hasRemaining { state = .exhausted }
    }

    // Photos dropped or unreadable (already reported by the pipeline) will never become cards.
    private func dropUnavailable() {
        guard hasRemaining else { return }
        let viable = remaining[remainingCursor...].filter { pipeline.availability(for: $0) != .unavailable }
        remaining.replaceSubrange(remainingCursor..., with: viable)
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
