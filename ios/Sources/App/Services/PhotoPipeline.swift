import Foundation
import Network
import Observation
import UIKit

enum PhotoRegistrationState {
    case registered   // server row exists (guaranteed by pre-registration before cull)
    case unavailable  // local asset failed to read — no server action needed
}

enum PipelineError: Error {
    case photoUnavailable
    // The batch register call succeeded but refused some photos.
    case registrationRejected
}

// Owns the per-photo state machine: materialize (compress to tmp disk) →
// upload → register. Cull display images decode from the same tmp files,
// so the cull phase never touches the network.
//
// Registration is batched: uploaded photos queue up and are sent to the server
// together (when a batch is full, or after a short delay), because a call per
// photo trips the server's per-caller rate limit on large sessions.
@Observable
@MainActor
final class PhotoPipeline {

    private(set) var registeredCount = 0
    private(set) var failedIds: [UUID] = []
    // True once the server was told every photo is uploaded and registered (so never
    // while photos are parked). See `isSettled` for "nothing left in flight".
    private(set) var isComplete = false

    private(set) var order: [UUID] = []
    var totalCount: Int { order.count }

    private var items: [UUID: Item] = [:]
    private var uploadQueue: [UUID] = []
    private var activeUploads = 0
    private var waiters: [UUID: [CheckedContinuation<URL, Error>]] = [:]
    private var didMarkComplete = false
    @ObservationIgnored nonisolated(unsafe) private var backgroundTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var registrationBatcher: RegistrationBatcher?
    @ObservationIgnored private let parkedRetryTimer: ParkedRetryTimer

    private let transport: any PhotoUploadTransport
    private let sessionId: UUID
    private let userId: UUID
    private let retryDelays: [Duration]
    private let materializeConcurrency: Int
    private let uploadConcurrency: Int
    private let connectivityEvents: AsyncStream<Void>
    private var monitor: NWPathMonitor?

    init(
        transport: any PhotoUploadTransport,
        sessionId: UUID,
        userId: UUID,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        materializeConcurrency: Int = 3,
        uploadConcurrency: Int = 4,
        registrationBatchSize: Int = 25,
        registrationFlushDelay: Duration = .seconds(1),
        parkedRetryBaseDelay: Duration = .seconds(5),
        parkedRetryMaxDelay: Duration = .seconds(60),
        connectivityEvents: AsyncStream<Void>? = nil
    ) {
        self.transport = transport
        self.sessionId = sessionId
        self.userId = userId
        self.retryDelays = retryDelays
        self.materializeConcurrency = materializeConcurrency
        self.uploadConcurrency = uploadConcurrency
        self.parkedRetryTimer = ParkedRetryTimer(baseDelay: parkedRetryBaseDelay, maxDelay: parkedRetryMaxDelay)
        if let connectivityEvents {
            self.connectivityEvents = connectivityEvents
        } else {
            let (stream, monitor) = ConnectivityMonitor.makeStream(label: "pipeline.connectivity")
            self.connectivityEvents = stream
            self.monitor = monitor
        }
        registrationBatcher = RegistrationBatcher(
            transport: transport,
            sessionId: sessionId,
            batchSize: registrationBatchSize,
            flushDelay: registrationFlushDelay,
            retryDelays: retryDelays,
            storagePath: { [userId] id in "\(userId.lowercased)/\(sessionId.lowercased)/\(id.lowercased).jpg" },
            claim: { [weak self] id in self?.claimForRegistration(id) ?? false },
            settle: { [weak self] settlement in self?.applyRegistration(settlement) },
            didGoIdle: { [weak self] in self?.checkCompletion() }
        )
    }

    func start(photos: [PendingPhoto]) {
        order = photos.map(\.id)
        for photo in photos {
            items[photo.id] = Item(loader: photo.loader)
        }
        prepareSessionDirectory()
        backgroundTasks.append(Task { await self.materializeAll() })
        backgroundTasks.append(Task { [weak self] in
            guard let events = self?.connectivityEvents else { return }
            for await _ in events { self?.retryParked() }
        })
    }

    deinit { for task in backgroundTasks { task.cancel() } }

    // MARK: - Display access

    // Returns the on-disk compressed JPEG, waiting for materialization if needed.
    func materializedFileURL(for id: UUID) async throws -> URL {
        guard let item = items[id] else { throw PipelineError.photoUnavailable }
        switch item.state {
        case .cancelled, .failed:
            throw PipelineError.photoUnavailable
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
        default:
            guard let url = item.fileURL else { throw PipelineError.photoUnavailable }
            return url
        }
    }

    func displayImage(for id: UUID) async throws -> UIImage {
        let url = try await materializedFileURL(for: id)
        return try await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                throw PipelineError.photoUnavailable
            }
            return image
        }.value
    }

    // MARK: - Decisions & retry

    // Drop ⇒ cancel the upload to save bandwidth; the drop is sent to the server
    // via SyncService. Keep ⇒ promote it to the front of the upload queue.
    func setDecision(photoId: UUID, decision: CullDecision) {
        guard items[photoId] != nil else { return }
        switch decision {
        case .keep:
            items[photoId]?.isKept = true
        case .drop:
            switch items[photoId]?.state {
            case .pending, .materialized, .parked, .uploading, .awaitingRegistration:
                // (.registering is deliberately not here: that call is already in flight.)
                // The server row already exists (pre-registered). The drop decision
                // is sent to the server via SyncService — no timing dependency here.
                // Cancelling the upload saves bandwidth: a dropped photo's bytes
                // don't need to land. upload_status stays 'pending'; is_suppressed=true
                // (set by batch-submit-cull) keeps it out of the ranking pool.
                items[photoId]?.state = .cancelled
                removeWorkingCopy(photoId)
                resumeWaiters(for: photoId, with: .failure(PipelineError.photoUnavailable))
                updateFailedIds()
                checkCompletion()
            default:
                // .uploaded, .cancelled, .failed: already terminal
                break
            }
        }
    }

    // Give parked photos a fresh retry budget. Called on connectivity
    // restore, from the user-facing retry affordance, and by the backoff timer
    // that re-arms itself while photos stay parked.
    func retryParked() {
        parkedRetryTimer.cancel()
        for id in order where items[id]?.state == .parked {
            if items[id]?.didUpload == true {
                // Bytes already landed - only the registration is outstanding.
                items[id]?.state = .awaitingRegistration
                registrationBatcher?.enqueue(id)
            } else {
                items[id]?.state = .materialized
                enqueueUpload(id)
            }
        }
        updateFailedIds()
    }

    func registrationState(for id: UUID) -> PhotoRegistrationState {
        switch items[id]?.state {
        case .failed, nil: return .unavailable
        default: return .registered
        }
    }

    // MARK: - Materialization

    private var sessionDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PictalisUploads")
            .appendingPathComponent(sessionId.lowercased)
    }

    private func prepareSessionDirectory() {
        try? FileManager.default.removeItem(at: sessionDirectory) // clear this session only
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    private func materializeAll() async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = order.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask { await self.materialize(id) }
            }
            for _ in 0..<materializeConcurrency { addNext() }
            for await _ in group { addNext() }
        }
    }

    private func materialize(_ id: UUID) async {
        guard items[id]?.state == .pending, let loader = items[id]?.loader else { return }
        items[id]?.materializeAttempts += 1
        do {
            let raw = try await loader.loadData()
            let jpeg = try await Task.detached(priority: .userInitiated) {
                try ImageCompressor.compressData(raw)
            }.value
            // The photo may have been dropped while we were decoding.
            guard items[id]?.state == .pending else { return }
            let url = sessionDirectory.appendingPathComponent("\(id.lowercased).jpg")
            try jpeg.write(to: url)
            items[id]?.fileURL = url
            items[id]?.state = .materialized
            resumeWaiters(for: id, with: .success(url))
            enqueueUpload(id)
        } catch {
            if items[id]?.materializeAttempts == 1 {
                await materialize(id) // one immediate retry
            } else {
                ErrorReporter.capture(error)
                items[id]?.state = .failed
                updateFailedIds()
                resumeWaiters(for: id, with: .failure(PipelineError.photoUnavailable))
                checkCompletion()
            }
        }
    }

    private func resumeWaiters(for id: UUID, with result: Result<URL, Error>) {
        for continuation in waiters[id] ?? [] {
            continuation.resume(with: result)
        }
        waiters[id] = nil
    }

    private func removeWorkingCopy(_ id: UUID) {
        if let url = items[id]?.fileURL {
            try? FileManager.default.removeItem(at: url)
            items[id]?.fileURL = nil
        }
    }

    // MARK: - Upload

    private func enqueueUpload(_ id: UUID) {
        uploadQueue.append(id)
        pumpUploads()
    }

    private func pumpUploads() {
        while activeUploads < uploadConcurrency, let id = dequeueNextUpload() {
            activeUploads += 1
            items[id]?.state = .uploading
            backgroundTasks.append(Task { await self.uploadAndQueueRegistration(id) })
        }
    }

    // Kept photos jump the queue; otherwise FIFO (selection order).
    private func dequeueNextUpload() -> UUID? {
        while !uploadQueue.isEmpty {
            let index = uploadQueue.firstIndex { items[$0]?.isKept == true } ?? 0
            let id = uploadQueue.remove(at: index)
            if items[id]?.state == .materialized { return id }
            // dropped while queued — skip it
        }
        return nil
    }

    private func uploadAndQueueRegistration(_ id: UUID) async {
        defer {
            activeUploads -= 1
            pumpUploads()
            checkCompletion()
        }
        guard let fileURL = items[id]?.fileURL, let data = try? Data(contentsOf: fileURL) else {
            // File missing: a drop removed it or materialization failed.
            // Only flag .failed if still actively uploading (not already cancelled).
            if items[id]?.state == .uploading { items[id]?.state = .failed }
            updateFailedIds()
            return
        }
        do {
            try await uploadBytesIfNeeded(id, data: data, storagePath: storagePath(for: id))
            // Photo may have been dropped while bytes were in flight. Skip
            // registration — the drop is already on the server (is_suppressed=true),
            // and upload_status staying 'pending' is a second exclusion from ranking.
            guard items[id]?.state == .uploading else { return }
            items[id]?.state = .awaitingRegistration
            registrationBatcher?.enqueue(id)
        } catch {
            ErrorReporter.capture(error)
            if items[id]?.state == .uploading { items[id]?.state = .parked }
            updateFailedIds()
            scheduleParkedRetry()
        }
    }

    private func scheduleParkedRetry(minimumDelay: Duration? = nil) {
        guard items.values.contains(where: { $0.state == .parked }) else { return }
        parkedRetryTimer.schedule(minimumDelay: minimumDelay) { [weak self] in self?.retryParked() }
    }

    private func uploadBytesIfNeeded(_ id: UUID, data: Data, storagePath: String) async throws {
        guard items[id]?.didUpload != true else { return }
        try await retryWithBackoff(delays: retryDelays, jitter: 0...300) {
            try await self.transport.upload(storagePath: storagePath, data: data)
        }
        items[id]?.didUpload = true
    }

    // MARK: - Registration (batched by RegistrationBatcher)

    private func storagePath(for id: UUID) -> String {
        "\(userId.lowercased)/\(sessionId.lowercased)/\(id.lowercased).jpg"
    }

    private func claimForRegistration(_ id: UUID) -> Bool {
        guard items[id]?.state == .awaitingRegistration else { return false } // e.g. dropped while queued
        items[id]?.state = .registering
        return true
    }

    private func applyRegistration(_ settlement: RegistrationBatcher.Settlement) {
        for id in settlement.registered where items[id]?.state == .registering {
            items[id]?.state = .uploaded
            registeredCount += 1
        }
        // A photo dropped mid-flight is no longer .registering and keeps its state.
        for (ids, state) in [(settlement.requeued, ItemState.awaitingRegistration), (settlement.parked, .parked)] {
            for id in ids where items[id]?.state == .registering { items[id]?.state = state }
        }
        if !settlement.registered.isEmpty { parkedRetryTimer.reset() }
        updateFailedIds()
        if !settlement.parked.isEmpty { scheduleParkedRetry(minimumDelay: settlement.serverWait) }
    }

    // MARK: - Bookkeeping

    private func updateFailedIds() {
        failedIds = order.filter {
            let state = items[$0]?.state
            return state == .parked || state == .failed
        }
    }

    // True once nothing is in flight: every photo is registered, dropped, failed,
    // or parked (waiting on a retry). Unlike `isComplete`, parked photos don't hold it back.
    var isSettled: Bool {
        !order.isEmpty && !order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading, .awaitingRegistration, .registering: return true
            default: return false
            }
        }
    }

    private func checkCompletion() {
        guard !didMarkComplete, !order.isEmpty else { return }
        // Parked photos have bytes in storage but no registered row, so ranking
        // would ignore them: don't tell the server the upload is complete yet.
        let unresolved = order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading, .awaitingRegistration, .registering, .parked: return true
            default: return false
            }
        }
        guard !unresolved else { return }
        didMarkComplete = true
        // Mark the session complete only once the server has been told, so
        // observers waiting on `isComplete` see a settled state.
        backgroundTasks.append(Task {
            do {
                try await self.transport.markUploadComplete(sessionId: self.sessionId)
            } catch {
                ErrorReporter.capture(error)
            }
            self.isComplete = true
        })
    }
}
