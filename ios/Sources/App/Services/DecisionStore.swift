import Foundation

@Observable @MainActor
final class DecisionStore {
    private(set) var decisions: [StoredDecision] = []

    private let (stream, continuation) = AsyncStream.makeStream(
        of: [StoredDecision].self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private let persistence = DecisionPersistence()

    var allDecidedIds: [UUID] { decisions.map(\.photoId) }
    var pendingDecisions: [StoredDecision] { decisions.filter { !$0.synced } }

    // Loads decisions from disk and starts the persistence write loop.
    // Must complete before LocalCardProvider.start() is called.
    func load(sessionId: UUID) async -> [UUID] {
        decisions = await persistence.load(sessionId: sessionId)
        // Capture stream and persistence by value to avoid retaining self in the Task.
        // The stream terminates when deinit calls continuation.finish().
        let capturedStream = stream
        let capturedPersistence = persistence
        Task { await capturedPersistence.run(stream: capturedStream, sessionId: sessionId) }
        return allDecidedIds
    }

    func record(photoId: UUID, decision: CullDecision) {
        decisions.append(StoredDecision(
            photoId: photoId,
            decision: decision,
            synced: false
        ))
        continuation.yield(decisions)
    }

    func markSynced(photoIds: [UUID]) {
        let idSet = Set(photoIds)
        for i in decisions.indices where idSet.contains(decisions[i].photoId) {
            decisions[i].synced = true
        }
        continuation.yield(decisions)
    }

    deinit { continuation.finish() }
}

enum PersistenceError: Error {
    case noAppSupportDirectory
}

actor DecisionPersistence {
    private let fileManager = FileManager.default
    private let decoder     = JSONDecoder()
    private let encoder     = JSONEncoder()
    private let directoryOverride: URL?
    private var directoryEnsured = false

    // `directory` overrides Library/Application Support (tests only).
    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    private func supportDirectory() throws -> URL {
        if let directoryOverride { return directoryOverride }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PersistenceError.noAppSupportDirectory
        }
        return support
    }

    private func fileURL(sessionId: UUID) throws -> URL {
        try supportDirectory().appendingPathComponent("cull_\(sessionId.lowercased).json")
    }

    // Library/Application Support does not exist in a fresh install's container, so the
    // first write must create it. Only marked done once creation succeeds, so a failure retries.
    private func ensureDirectoryExists() throws {
        guard !directoryEnsured else { return }
        try fileManager.createDirectory(at: supportDirectory(), withIntermediateDirectories: true)
        directoryEnsured = true
    }

    func load(sessionId: UUID) -> [StoredDecision] {
        let url: URL
        do {
            url = try fileURL(sessionId: sessionId)
        } catch {
            ErrorReporter.capture(error)
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let file = try decoder.decode(SessionDecisionFile.self, from: data)
            return file.decisions
        } catch {
            ErrorReporter.capture(error)
            return []
        }
    }

    func run(stream: AsyncStream<[StoredDecision]>, sessionId: UUID) async {
        for await snapshot in stream {
            save(snapshot, sessionId: sessionId)
        }
    }

    func save(_ decisions: [StoredDecision], sessionId: UUID) {
        let dest: URL
        do {
            dest = try fileURL(sessionId: sessionId)
        } catch {
            ErrorReporter.capture(error)
            return
        }
        let file = SessionDecisionFile(decisions: decisions)
        guard let data = try? encoder.encode(file) else { return }
        let tmp  = dest.deletingLastPathComponent()
            .appendingPathComponent("cull_\(sessionId.lowercased).tmp.json")
        do {
            try ensureDirectoryExists()
            try data.write(to: tmp)
            _ = try fileManager.replaceItem(
                at: dest, withItemAt: tmp,
                backupItemName: nil, options: [], resultingItemURL: nil
            )
        } catch {
            ErrorReporter.capture(error)
            try? fileManager.removeItem(at: tmp)
        }
    }
}
