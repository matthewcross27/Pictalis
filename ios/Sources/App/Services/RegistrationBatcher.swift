import Foundation

// Sends uploaded photos to the server's batch register endpoint: a batch goes out
// once `batchSize` photos are waiting, or `flushDelay` after the first one queued,
// and only one request is ever in flight. A call per photo trips the server's
// per-caller rate limit on large sessions.
//
// Photos whose result failed (or all of them, if the whole request failed) are
// retried alone after a backoff that honors the server's Retry-After, and handed
// back as parked once their retry budget (`retryDelays.count` retries) is spent.
// The photo state machine lives in PhotoPipeline; this type only reports outcomes.
@MainActor
final class RegistrationBatcher {
    struct Settlement {
        var registered: [UUID] = []
        var requeued: [UUID] = []
        var parked: [UUID] = []
        var serverWait: Duration?
    }

    private let transport: any PhotoUploadTransport
    private let sessionId: UUID
    private let storagePath: (UUID) -> String
    private let batchSize: Int
    private let flushDelay: Duration
    private let retryDelays: [Duration]
    // Returns whether the photo still needs registering, and marks it in flight.
    private let claim: (UUID) -> Bool
    private let settle: (Settlement) -> Void
    private let didGoIdle: () -> Void

    private var queue: [UUID] = []
    private var attempts: [UUID: Int] = [:]
    private var isRunning = false
    nonisolated(unsafe) private var timer: Task<Void, Never>?
    nonisolated(unsafe) private var loop: Task<Void, Never>?

    init(
        transport: any PhotoUploadTransport,
        sessionId: UUID,
        batchSize: Int,
        flushDelay: Duration,
        retryDelays: [Duration],
        storagePath: @escaping (UUID) -> String,
        claim: @escaping (UUID) -> Bool,
        settle: @escaping (Settlement) -> Void,
        didGoIdle: @escaping () -> Void
    ) {
        self.transport = transport
        self.sessionId = sessionId
        self.batchSize = batchSize
        self.flushDelay = flushDelay
        self.retryDelays = retryDelays
        self.storagePath = storagePath
        self.claim = claim
        self.settle = settle
        self.didGoIdle = didGoIdle
    }

    deinit {
        timer?.cancel()
        loop?.cancel()
    }

    func enqueue(_ id: UUID) {
        queue.append(id)
        if !isRunning, queue.count >= batchSize {
            start()
        } else {
            armTimer()
        }
    }

    private func armTimer() {
        guard !isRunning, timer == nil, !queue.isEmpty else { return }
        timer = Task { [weak self, flushDelay] in
            try? await Task.sleep(for: flushDelay)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.start()
        }
    }

    private func start() {
        guard !isRunning else { return }
        timer?.cancel()
        timer = nil
        isRunning = true
        loop = Task { await self.run() }
    }

    // Keeps going while full batches are waiting, or after a backoff (so retried
    // photos aren't held back by another flush delay); a partial batch is left to
    // the timer so requests stay about a flush delay apart.
    private func run() async {
        defer {
            isRunning = false
            armTimer()
            didGoIdle()
        }
        var backedOff = false
        repeat {
            let batch = takeBatch()
            guard !batch.isEmpty else { return }
            let backoff = await send(batch)
            backedOff = backoff != nil
            if let backoff {
                do { try await Task.sleep(for: backoff) } catch { return }
            }
        } while !queue.isEmpty && (backedOff || queue.count >= batchSize)
    }

    private func takeBatch() -> [UUID] {
        var batch: [UUID] = []
        while batch.count < batchSize, !queue.isEmpty {
            let id = queue.removeFirst()
            if claim(id) { batch.append(id) }
        }
        return batch
    }

    // Returns how long to wait before the next request, if any photo was re-queued.
    private func send(_ ids: [UUID]) async -> Duration? {
        let photos = ids.map { PhotoRegistration(photoId: $0, storagePath: storagePath($0)) }
        var settlement = Settlement()
        var succeeded: Set<UUID> = []
        do {
            let results = try await transport.registerPhotos(sessionId: sessionId, photos: photos)
            succeeded = Set(results.filter(\.success).map(\.photoId))
            if ids.contains(where: { !succeeded.contains($0) }) {
                ErrorReporter.capture(PipelineError.registrationRejected)
            }
        } catch {
            if case let APIError.rateLimited(retryAfter) = error {
                // Expected under load, not worth a Sentry event: the server says how long to wait.
                settlement.serverWait = retryAfter.map { .seconds($0) }
            } else if !(error is CancellationError) {
                ErrorReporter.capture(error)
            }
        }

        var delay: Duration = .zero
        for id in ids {
            if succeeded.contains(id) {
                attempts[id] = nil
                settlement.registered.append(id)
                continue
            }
            let used = (attempts[id] ?? 0) + 1
            if used <= retryDelays.count {
                attempts[id] = used
                settlement.requeued.append(id)
                delay = max(delay, retryDelays[used - 1])
            } else {
                attempts[id] = nil
                settlement.parked.append(id)
            }
        }
        queue.insert(contentsOf: settlement.requeued, at: 0)
        settle(settlement)
        guard !settlement.requeued.isEmpty else { return nil }
        return max(delay, settlement.serverWait ?? .zero) + .milliseconds(Int.random(in: 0...300))
    }
}

// Re-fires parked photos on a growing delay (base, 2x, 4x ... capped), so a rate
// limit or outage that outlasts the inline retries still recovers without waiting
// for a connectivity change or a manual tap.
@MainActor
final class ParkedRetryTimer {
    private let baseDelay: Duration
    private let maxDelay: Duration
    private var attempt = 0
    nonisolated(unsafe) private var task: Task<Void, Never>?

    init(baseDelay: Duration, maxDelay: Duration) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    deinit { task?.cancel() }

    // No-op while a retry is already scheduled.
    func schedule(minimumDelay: Duration? = nil, action: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        var delay = min(baseDelay * (1 << min(attempt, 8)), maxDelay)
        if let minimumDelay { delay = max(delay, minimumDelay) }
        attempt += 1
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // Something registered, so the next failure starts the backoff over.
    func reset() { attempt = 0 }
}
