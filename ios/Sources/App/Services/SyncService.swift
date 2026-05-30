import Foundation
import Network

@MainActor
final class SyncService {
    private let api:       APIClient
    private let sessionId: UUID
    private var store:     DecisionStore?
    private var isDraining = false
    private var monitor:   NWPathMonitor?

    init(sessionId: UUID, api: APIClient) {
        self.sessionId = sessionId
        self.api       = api
    }

    // Awaits an initial drain attempt, then sets up foreground + network triggers.
    func start(store: DecisionStore) async {
        self.store = store
        await drain()
        startObservers()
    }

    // MARK: - Private

    private func startObservers() {
        // Re-drain on app foreground
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification
            ) {
                await self?.drain()
            }
        }

        // Re-drain on connectivity restore
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { continuation.yield() }
        }
        monitor.start(queue: DispatchQueue(label: "sync.monitor", qos: .background))

        Task { @MainActor [weak self] in
            for await _ in stream { await self?.drain() }
        }
    }

    // Sends all pending decisions in one request; marks successes as synced.
    // Retries with exponential backoff (1s, 2s, 4s) before giving up.
    // Failed entries remain pending and will be retried on the next trigger.
    private func drain() async {
        guard !isDraining, let store else { return }
        let pending = store.pendingDecisions
        guard !pending.isEmpty else { return }

        isDraining = true
        defer { isDraining = false }

        let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        var attempt = 0

        while true {
            do {
                let response = try await api.batchSubmitCull(sessionId: sessionId, decisions: pending)
                let succeeded = response.results.filter(\.success).map(\.photoId)
                if !succeeded.isEmpty { store.markSynced(photoIds: succeeded) }
                return
            } catch {
                guard attempt < backoff.count else { return }
                try? await Task.sleep(for: backoff[attempt])
                attempt += 1
            }
        }
    }
}
