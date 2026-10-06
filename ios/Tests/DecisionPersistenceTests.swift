import XCTest
@testable import Pictalis

final class DecisionPersistenceTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecisionPersistenceTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testSaveCreatesMissingApplicationSupportDirectoryAndReloads() async {
        // A fresh install's container has no Library/Application Support at all.
        let supportDir = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportDir.path))

        let sessionId = UUID()
        let decisions = [
            StoredDecision(photoId: UUID(), decision: .keep, synced: false),
            StoredDecision(photoId: UUID(), decision: .drop, synced: true)
        ]

        let persistence = DecisionPersistence(directory: supportDir)
        await persistence.save(decisions, sessionId: sessionId)

        // Reload through a new instance, as a relaunch would.
        let reloaded = await DecisionPersistence(directory: supportDir).load(sessionId: sessionId)
        XCTAssertEqual(reloaded.map(\.photoId), decisions.map(\.photoId))
        XCTAssertEqual(reloaded.map(\.decision), decisions.map(\.decision))
        XCTAssertEqual(reloaded.map(\.synced), decisions.map(\.synced))
    }

    func testRepeatedSavesOverwriteExistingFile() async {
        let supportDir = container.appendingPathComponent("Application Support", isDirectory: true)
        let sessionId = UUID()
        let first = StoredDecision(photoId: UUID(), decision: .keep, synced: false)
        let second = StoredDecision(photoId: UUID(), decision: .drop, synced: false)

        let persistence = DecisionPersistence(directory: supportDir)
        await persistence.save([first], sessionId: sessionId)
        await persistence.save([first, second], sessionId: sessionId)

        let reloaded = await persistence.load(sessionId: sessionId)
        XCTAssertEqual(reloaded.map(\.photoId), [first.photoId, second.photoId])
    }
}
