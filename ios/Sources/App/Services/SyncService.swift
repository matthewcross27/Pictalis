import Foundation
import Network
import UIKit

@MainActor
final class SyncService {
    private let api:       APIClient
    private let sessionId: UUID
    private var store:     DecisionStore?
    private var isDraining = false
    private var monitor:   NWPathMonitor?
    private let registrationState: (UUID) -> PhotoRegistrationState

    init(
        sessionId: UUID,
        api: APIClient,
        registrationState: @escaping (UUID) -> PhotoRegistrationState = { _ in .registered }
    ) {
        self.sessionId = sessionId
        self.api = api
        self.registrationState = registrationState
    }

    // Decisions for registered photos go to the server; decisions for photos
    // the server will never know (cancelled uploads) are settled locally;
    // the rest stay pending until their photo registers.
    nonisolated static func partition(
        pending: [StoredDecision],
        registrationState: (UUID) -> PhotoRegistrationState
    ) -> (send: [StoredDecision], markLocalOnly: [UUID]) {
        var send: [StoredDecision] = []
        var markLocalOnly: [UUID] = []
        for decision in pending {
            switch registrationState(decision.photoId) {
            case .registered:  send.append(decision)
            case .unavailable: markLocalOnly.append(decision.photoId)
            case .pending:     break
            }
        }
        return (send, markLocalOnly)
    }

    // Awaits an initial drain attempt, then sets up foreground + network triggers.
    func start(store: DecisionStore) async {
        self.store = store
        await drain()
        startObservers()
    }

    // Fire-and-forget drain; safe to call after every decision — isDraining guard prevents pile-up.
    func syncIfNeeded() {
        guard !isDraining else { return }
        Task { await drain() }
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
    func drain() async {
        guard !isDraining, let store else { return }
        let (send, markLocalOnly) = Self.partition(
            pending: store.pendingDecisions,
            registrationState: registrationState
        )
        if !markLocalOnly.isEmpty { store.markSynced(photoIds: markLocalOnly) }
        guard !send.isEmpty else { return }

        isDraining = true
        defer { isDraining = false }

        let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        var attempt = 0

        while true {
            do {
                let response = try await api.batchSubmitCull(sessionId: sessionId, decisions: send)
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
