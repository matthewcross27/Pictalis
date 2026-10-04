import XCTest
@testable import Pictalis

@MainActor
final class SessionStartAttemptTests: XCTestCase {
    private struct StubLoader: PhotoDataLoading {
        func loadData() async throws -> Data { Data() }
    }

    private final class FakeAPI: SessionStartAPI {
        var createCalls: [(sessionId: UUID, photoCount: Int)] = []
        var preRegisterCalls: [(sessionId: UUID, photoIds: [UUID])] = []
        var failCreate = false
        var failPreRegister = false

        func createSession(sessionId: UUID, photoCount: Int) async throws -> APISession {
            createCalls.append((sessionId, photoCount))
            if failCreate { throw URLError(.networkConnectionLost) }
            return try JSONDecoder().decode(
                APISession.self,
                from: Data(#"{"id":"\#(sessionId.uuidString)","status":"ranking","photo_count":\#(photoCount)}"#.utf8)
            )
        }

        func batchPreRegister(sessionId: UUID, photoIds: [UUID]) async throws {
            preRegisterCalls.append((sessionId, photoIds))
            if failPreRegister { throw URLError(.networkConnectionLost) }
        }
    }

    private func makeAttempt(photoCount: Int = 3) -> SessionStartAttempt {
        SessionStartAttempt(photos: (0..<photoCount).map { _ in PendingPhoto(loader: StubLoader()) })
    }

    func testRunCreatesSessionThenPreRegistersWithTheSameIds() async throws {
        let api = FakeAPI()
        let attempt = makeAttempt()

        try await attempt.run(api: api)

        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.createCalls[0].sessionId, attempt.sessionId)
        XCTAssertEqual(api.createCalls[0].photoCount, 3)
        XCTAssertEqual(api.preRegisterCalls.count, 1)
        XCTAssertEqual(api.preRegisterCalls[0].sessionId, attempt.sessionId)
        XCTAssertEqual(api.preRegisterCalls[0].photoIds, attempt.photos.map(\.id))
    }

    func testRetryAfterPreRegisterFailureSkipsCreateSession() async throws {
        let api = FakeAPI()
        api.failPreRegister = true
        let attempt = makeAttempt()

        do {
            try await attempt.run(api: api)
            XCTFail("expected the pre-register failure")
        } catch {}

        api.failPreRegister = false
        try await attempt.run(api: api)

        XCTAssertEqual(api.createCalls.count, 1, "session was already created")
        XCTAssertEqual(api.preRegisterCalls.count, 2)
        XCTAssertEqual(api.preRegisterCalls[0].sessionId, api.preRegisterCalls[1].sessionId)
        XCTAssertEqual(api.preRegisterCalls[0].photoIds, api.preRegisterCalls[1].photoIds)
    }

    func testRetryAfterCreateFailureReusesTheSameSessionId() async throws {
        let api = FakeAPI()
        api.failCreate = true
        let attempt = makeAttempt()

        do {
            try await attempt.run(api: api)
            XCTFail("expected the create failure")
        } catch {}
        XCTAssertTrue(api.preRegisterCalls.isEmpty)

        api.failCreate = false
        try await attempt.run(api: api)

        XCTAssertEqual(api.createCalls.map(\.sessionId), [attempt.sessionId, attempt.sessionId])
        XCTAssertEqual(api.preRegisterCalls.count, 1)
    }

    func testCompletedAttemptDoesNotRepeatAnyStep() async throws {
        let api = FakeAPI()
        let attempt = makeAttempt()

        try await attempt.run(api: api)
        try await attempt.run(api: api)

        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.preRegisterCalls.count, 1)
    }

    func testSeparateAttemptsGetDistinctSessionsAndPhotoIds() {
        let a = makeAttempt()
        let b = makeAttempt()

        XCTAssertNotEqual(a.sessionId, b.sessionId)
        XCTAssertTrue(Set(a.photos.map(\.id)).isDisjoint(with: b.photos.map(\.id)))
    }
}
