import Foundation

@Observable @MainActor
final class DecisionStore {
    private(set) var decisions: [StoredDecision] = []

    private let (stream, continuation) = AsyncStream.makeStream(
        of: [StoredDecision].self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private let persistence = DecisionPersistence()

    var allDecidedIds: [UUID]              { decisions.map(\.photoId) }
    var pendingDecisions: [StoredDecision] { decisions.filter { !$0.synced } }

    // Loads decisions from disk and starts the persistence write loop.
    // Must complete before CullPrefetchService.start() is called.
    func load(sessionId: UUID) async -> [UUID] {
        decisions = await persistence.load(sessionId: sessionId)
        // Capture stream and persistence by value to avoid retaining self in the Task.
        // The stream terminates when deinit calls continuation.finish().
        let s = stream
        let p = persistence
        Task { await p.run(stream: s, sessionId: sessionId) }
        return allDecidedIds
    }

    func record(photoId: UUID, decision: CullDecision) {
        decisions.append(StoredDecision(
            photoId: photoId,
            decision: decision,
            timestamp: .now,
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

actor DecisionPersistence {
    private let fileManager = FileManager.default
    private let decoder     = JSONDecoder()
    private let encoder     = JSONEncoder()

    private func fileURL(sessionId: UUID) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("cull_\(sessionId.uuidString.lowercased()).json")
    }

    func load(sessionId: UUID) -> [StoredDecision] {
        let url = fileURL(sessionId: sessionId)
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(SessionDecisionFile.self, from: data)
        else { return [] }
        return file.decisions
    }

    func run(stream: AsyncStream<[StoredDecision]>, sessionId: UUID) async {
        for await snapshot in stream {
            save(snapshot, sessionId: sessionId)
        }
    }

    private func save(_ decisions: [StoredDecision], sessionId: UUID) {
        let file = SessionDecisionFile(sessionId: sessionId, decisions: decisions)
        guard let data = try? encoder.encode(file) else { return }
        let dest = fileURL(sessionId: sessionId)
        let tmp  = dest.deletingLastPathComponent()
            .appendingPathComponent("cull_\(sessionId.uuidString.lowercased()).tmp.json")
        do {
            try data.write(to: tmp)
            _ = try fileManager.replaceItem(
                at: dest, withItemAt: tmp,
                backupItemName: nil, options: [], resultingItemURL: nil
            )
        } catch {
            try? fileManager.removeItem(at: tmp)
        }
    }
}
