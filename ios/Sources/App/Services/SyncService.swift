import Foundation
import Network
import UIKit

// Seam for testing: the one server call SyncService makes. APIClient conforms.
@MainActor
protocol CullDecisionSubmitting {
    func batchSubmitCull(sessionId: UUID, decisions: [StoredDecision]) async throws -> BatchSubmitResponse
}

extension APIClient: CullDecisionSubmitting {}

@MainActor
final class SyncService {
    private let api:       any CullDecisionSubmitting
    private let sessionId: UUID
    private var store:     DecisionStore?
    private var isDraining = false
    private var monitor:   NWPathMonitor?
    private let registrationState: (UUID) -> PhotoRegistrationState
    private var observerTasks: [Task<Void, Never>] = []
    // nil in production (a real NWPathMonitor is started in startObservers()); tests
    // inject a stream they control so connectivity-restore drains are deterministic
    // instead of depending on the real OS network path, which can flip mid-test.
    private let injectedConnectivityEvents: AsyncStream<Void>?

    init(
        sessionId: UUID,
        api: any CullDecisionSubmitting,
        registrationState: @escaping (UUID) -> PhotoRegistrationState = { _ in .registered },
        connectivityEvents: AsyncStream<Void>? = nil
    ) {
        self.sessionId = sessionId
        self.api = api
        self.registrationState = registrationState
        self.injectedConnectivityEvents = connectivityEvents
    }

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

    // Backstop before entering ranking: sends all pending decisions before the
    // SyncService is torn down. With pre-registration every photo has a server row,
    // so all decisions are immediately sendable — one drain call is sufficient.
    func flush() async {
        // All photos have server rows from pre-registration, so every pending
        // decision is immediately sendable. One drain call is sufficient.
        await performDrain()
    }

    // MARK: - Private

    private func startObservers() {
        // Re-drain on app foreground
        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification
            ) {
                await self?.drain()
            }
        })

        // Re-drain on connectivity restore
        let connectivityStream: AsyncStream<Void>
        if let injectedConnectivityEvents {
            connectivityStream = injectedConnectivityEvents
        } else {
            let (stream, monitor) = ConnectivityMonitor.makeStream(label: "sync.monitor")
            self.monitor = monitor
            connectivityStream = stream
        }

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in connectivityStream { await self?.drain() }
        })
    }

    func stop() {
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
        monitor?.cancel()
        monitor = nil
    }

    deinit {
        for task in observerTasks { task.cancel() }
        monitor?.cancel()
    }

    // Coalesced drain: skips if one is already running. The isDraining guard
    // keeps background triggers from piling up concurrent network batches.
    func drain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        await performDrain()
    }

    // Sends all currently-sendable decisions in one request; marks successes as
    // synced. Cancelled-photo decisions are settled locally. Retries with
    // exponential backoff (1s, 2s, 4s) before giving up; failed entries remain
    // pending for the next trigger. Does NOT consult isDraining — callers own
    // coalescing — so flush() can drive it to completion.
    private func performDrain() async {
        guard let store else { return }
        let (send, markLocalOnly) = Self.partition(
            pending: store.pendingDecisions,
            registrationState: registrationState
        )
        if !markLocalOnly.isEmpty { store.markSynced(photoIds: markLocalOnly) }
        guard !send.isEmpty else { return }

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
