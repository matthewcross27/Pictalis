import Foundation
import Network
import UIKit

enum PhotoRegistrationState {
    case registered   // server row exists (guaranteed by pre-registration before cull)
    case unavailable  // local asset failed to read — no server action needed
}

enum PipelineError: Error {
    case photoUnavailable
}

// Owns the per-photo state machine: materialize (compress to tmp disk) →
// upload → register. Cull display images decode from the same tmp files,
// so the cull phase never touches the network.
@MainActor
final class PhotoPipeline: ObservableObject {

    enum ItemState: Equatable {
        case pending       // waiting to materialize
        case materialized  // compressed JPEG on disk, queued for upload
        case uploading     // an upload worker owns it
        case uploaded      // bytes in storage, server row has upload_status='uploaded'
        case cancelled     // dropped — upload skipped or aborted; server has is_suppressed=true
        case parked        // retries exhausted; waits for connectivity or user retry
        case failed        // local asset could not be read — terminal
    }

    private struct Item {
        let photoId: UUID
        let loader: any PhotoDataLoading
        var state: ItemState = .pending
        var isKept = false
        var didUpload = false
        var fileURL: URL?
        var materializeAttempts = 0
    }

    @Published private(set) var registeredCount = 0
    @Published private(set) var failedIds: [UUID] = []
    @Published private(set) var isComplete = false

    private(set) var order: [UUID] = []
    var totalCount: Int { order.count }


    private var items: [UUID: Item] = [:]
    private var uploadQueue: [UUID] = []
    private var activeUploads = 0
    private var waiters: [UUID: [CheckedContinuation<URL, Error>]] = [:]
    private var didMarkComplete = false

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
        connectivityEvents: AsyncStream<Void>? = nil
    ) {
        self.transport = transport
        self.sessionId = sessionId
        self.userId = userId
        self.retryDelays = retryDelays
        self.materializeConcurrency = materializeConcurrency
        self.uploadConcurrency = uploadConcurrency
        if let connectivityEvents {
            self.connectivityEvents = connectivityEvents
        } else {
            let monitor = NWPathMonitor()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { continuation.yield() }
            }
            monitor.start(queue: DispatchQueue(label: "pipeline.connectivity", qos: .background))
            self.connectivityEvents = stream
            self.monitor = monitor
        }
    }

    func start(photos: [PendingPhoto]) {
        order = photos.map(\.id)
        for photo in photos {
            items[photo.id] = Item(photoId: photo.id, loader: photo.loader)
        }
        prepareSessionDirectory()
        Task { await self.materializeAll() }
        Task { [weak self] in
            guard let events = self?.connectivityEvents else { return }
            for await _ in events { self?.retryParked() }
        }
    }

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
            case .pending, .materialized, .parked, .uploading:
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
    // restore and from the user-facing retry affordance.
    func retryParked() {
        for id in order where items[id]?.state == .parked {
            items[id]?.state = .materialized
            enqueueUpload(id)
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
            .appendingPathComponent(sessionId.uuidString.lowercased())
    }

    private func prepareSessionDirectory() {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PictalisUploads")
        try? FileManager.default.removeItem(at: parent) // clear previous sessions
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    private func materializeAll() async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = order.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask { @MainActor in await self.materialize(id) }
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
                guard let image = UIImage(data: raw) else { throw CompressionError.noImageData }
                return try ImageCompressor.compressImage(image)
            }.value
            // The photo may have been dropped while we were decoding.
            guard items[id]?.state == .pending else { return }
            let url = sessionDirectory.appendingPathComponent("\(id.uuidString.lowercased()).jpg")
            try jpeg.write(to: url)
            items[id]?.fileURL = url
            items[id]?.state = .materialized
            resumeWaiters(for: id, with: .success(url))
            enqueueUpload(id)
        } catch {
            if items[id]?.materializeAttempts == 1 {
                await materialize(id) // one immediate retry
            } else {
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
            Task { await self.uploadAndMarkUploaded(id) }
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

    private func uploadAndMarkUploaded(_ id: UUID) async {
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
        let storagePath = "\(userId.uuidString.lowercased())/\(sessionId.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
        do {
            if items[id]?.didUpload != true {
                try await withRetries { try await self.transport.upload(storagePath: storagePath, data: data) }
                items[id]?.didUpload = true
            }
            // Photo may have been dropped while bytes were in flight. Skip
            // markUploaded — the drop is already on the server (is_suppressed=true),
            // and upload_status staying 'pending' is a second exclusion from ranking.
            guard items[id]?.state == .uploading else { return }
            try await withRetries {
                try await self.transport.markUploaded(sessionId: self.sessionId, photoId: id, storagePath: storagePath)
            }
            items[id]?.state = .uploaded
            registeredCount += 1
            updateFailedIds()
        } catch {
            if items[id]?.state == .uploading { items[id]?.state = .parked }
            updateFailedIds()
        }
    }

    private func withRetries(_ operation: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch {
                guard attempt < retryDelays.count else { throw error }
                let jitter = Duration.milliseconds(Int.random(in: 0...300))
                try? await Task.sleep(for: retryDelays[attempt] + jitter)
                attempt += 1
            }
        }
    }

    // MARK: - Bookkeeping

    private func updateFailedIds() {
        failedIds = order.filter {
            let state = items[$0]?.state
            return state == .parked || state == .failed
        }
    }

    private func checkCompletion() {
        guard !didMarkComplete, !order.isEmpty else { return }
        let unresolved = order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading: return true
            default: return false
            }
        }
        guard !unresolved else { return }
        didMarkComplete = true
        // Mark the session complete only once the server has been told, so
        // observers waiting on `isComplete` see a settled state.
        Task {
            try? await self.transport.markUploadComplete(sessionId: self.sessionId)
            self.isComplete = true
        }
    }
}
