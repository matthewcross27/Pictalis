import Foundation
import Network
import UIKit

enum PhotoRegistrationState {
    case registered   // server knows this photo
    case pending      // may still register (queued, uploading, retrying, parked)
    case unavailable  // cancelled or failed — the server will never know it
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
        case registered    // server row exists
        case cancelled     // dropped in cull before upload — never uploads
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
    var onRegistered: ((UUID) -> Void)?

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

    // MARK: - Stubs completed in later tasks

    func setDecision(photoId: UUID, decision: CullDecision) {}
    func retryParked() {}

    func registrationState(for id: UUID) -> PhotoRegistrationState {
        switch items[id]?.state {
        case .registered: return .registered
        case .cancelled, .failed, nil: return .unavailable
        default: return .pending
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

    // MARK: - Upload (completed in Task 4)

    private func enqueueUpload(_ id: UUID) {}

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
        isComplete = true
        Task { try? await self.transport.markUploadComplete(sessionId: self.sessionId) }
    }
}
