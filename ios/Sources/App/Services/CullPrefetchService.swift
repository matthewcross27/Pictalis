import UIKit

enum CullQueueState: Equatable {
    case loading
    case ready
    case exhausted
    case error(String)
}

@Observable @MainActor
final class CullPrefetchService {

    struct PrefetchedCard: Sendable {
        let photoId:     UUID
        let clusterSize: Int?
        let image:       UIImage
    }

    private static let normalQueueSize = 20
    private static let minQueueSize    = 5
    private let batchSize              = 15
    private let refillThreshold        = 5
    private let maxConcurrentDownloads = 4

    private(set) var queue: [PrefetchedCard]  = []
    private(set) var state: CullQueueState    = .loading
    private var isFetching                    = false
    private var inFlightIds: Set<UUID>        = []
    private var servedIds:   Set<UUID>        = []
    private var serverExhausted               = false
    private var currentMaxQueueSize           = 20

    private let api:           APIClient
    private let decisionStore: DecisionStore
    private let sessionId:     UUID
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    init(sessionId: UUID, api: APIClient, decisionStore: DecisionStore) {
        self.sessionId     = sessionId
        self.api           = api
        self.decisionStore = decisionStore

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMemoryWarning() }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Call after DecisionStore.load() completes. decidedIds must be the
    // full set of already-decided photo IDs so the first request excludes them.
    func start(excluding decidedIds: [UUID]) async {
        await refill(initialExclude: decidedIds)
    }

    // Synchronous pop from queue. Triggers a background refill when queue
    // drops to refillThreshold. Returns nil only when queue is empty.
    func advance() -> PrefetchedCard? {
        guard !queue.isEmpty else {
            if serverExhausted { state = .exhausted }
            return nil
        }
        let card = queue.removeFirst()
        servedIds.insert(card.photoId)
        if queue.isEmpty && serverExhausted {
            state = .exhausted
        } else if !serverExhausted && queue.count <= refillThreshold && !isFetching {
            Task { await refill() }
        }
        return card
    }

    // Called from the error-state retry button.
    func retry() {
        Task { await refill() }
    }

    // MARK: - Private

    private func refill(initialExclude: [UUID]? = nil) async {
        guard !isFetching else { return }
        isFetching = true

        // Full exclusion: decided + currently on screen + queued + actively downloading
        let excludeIds = Set(initialExclude ?? decisionStore.allDecidedIds)
            .union(servedIds)
            .union(queue.map(\.photoId))
            .union(inFlightIds)

        let thumbnailWidth = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        var batchIds: [UUID] = []
        var attempt = 0

        do {
            var response: PrefetchCullResponse
            repeat {
                response = try await api.prefetchCull(
                    sessionId: sessionId,
                    count: batchSize,
                    excludeIds: Array(excludeIds),
                    thumbnailWidth: thumbnailWidth
                )
                if response.cards.isEmpty && response.hasMore {
                    attempt += 1
                    try await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            } while response.cards.isEmpty && response.hasMore && attempt < 3

            if !response.hasMore { serverExhausted = true }

            batchIds = response.cards.map(\.photoId)
            inFlightIds.formUnion(batchIds)

            // Bounded pipeline: 4 concurrent downloads, add next as each finishes
            var prefetched: [PrefetchedCard] = []
            var it = response.cards.makeIterator()

            await withTaskGroup(of: PrefetchedCard?.self) { group in
                for _ in 0..<min(maxConcurrentDownloads, response.cards.count) {
                    if let card = it.next() { group.addTask { await Self.download(card) } }
                }
                for await result in group {
                    if let card = result { prefetched.append(card) }
                    if let next = it.next() { group.addTask { await Self.download(next) } }
                }
            }

            inFlightIds.subtract(batchIds)
            queue.append(contentsOf: prefetched)

            // Enforce cap; evict oldest (furthest from next display)
            if queue.count > currentMaxQueueSize {
                queue.removeFirst(queue.count - currentMaxQueueSize)
            }
            // Gradual recovery toward normalQueueSize after a clean cycle
            currentMaxQueueSize = min(currentMaxQueueSize + 5, Self.normalQueueSize)

            if serverExhausted && queue.isEmpty {
                state = .exhausted
            } else if !queue.isEmpty {
                state = .ready
            }

        } catch {
            inFlightIds.subtract(batchIds)
            if queue.isEmpty {
                state = .error("Couldn't load photos — tap to retry")
            }
            // If queue has cards, failure is invisible — state stays .ready
        }

        isFetching = false
    }

    // nonisolated: runs off main actor; UIImage(data:) is thread-safe post-iOS 13
    private nonisolated static func download(_ card: PrefetchCullCard) async -> PrefetchedCard? {
        guard let url = URL(string: card.photoUrl),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data)
        else { return nil }
        return PrefetchedCard(photoId: card.photoId, clusterSize: card.clusterSize, image: image)
    }

    @MainActor
    private func handleMemoryWarning() {
        currentMaxQueueSize = Self.minQueueSize
        if queue.count > currentMaxQueueSize {
            queue.removeLast(queue.count - currentMaxQueueSize)
        }
    }
}
