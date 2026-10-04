import XCTest
@testable import Pictalis

/// Replays a scripted sequence of outcomes for each request a `URLSession`
/// built from this protocol makes, and records every request it saw.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case failure(URLError.Code)
        case response(status: Int, body: String)
    }

    private static let lock = NSLock()
    private static var script: [Outcome] = []
    private static var recorded: [URLRequest] = []

    static func reset(script: [Outcome]) {
        lock.lock(); defer { lock.unlock() }
        self.script = script
        recorded = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let outcome = Self.script.isEmpty ? nil : Self.script.removeFirst()
        Self.lock.unlock()

        switch outcome {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}

@MainActor
final class APIClientRetryTests: XCTestCase {
    private let sessionJSON = """
    {"session":{"id":"550e8400-e29b-41d4-a716-446655440000","created_at":"2026-05-17T00:00:00Z","expires_at":"2026-05-18T00:00:00Z","status":"ranking","photo_count":10}}
    """

    private func makeClient(
        script: [ScriptedURLProtocol.Outcome],
        accessToken: @escaping () async throws -> String = { "token" }
    ) -> APIClient {
        ScriptedURLProtocol.reset(script: script)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return APIClient(urlSession: URLSession(configuration: config), accessToken: accessToken)
    }

    private let sessionId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

    func testRetriesOnceAfterLostConnection() async throws {
        let client = makeClient(script: [
            .failure(.networkConnectionLost),
            .response(status: 201, body: sessionJSON)
        ])

        let session = try await client.createSession(sessionId: sessionId, photoCount: 10)

        XCTAssertEqual(session.id, sessionId)
        XCTAssertEqual(ScriptedURLProtocol.requests.count, 2)
    }

    func testRetriesOnceForEachTransientCode() async throws {
        for code in [URLError.Code.networkConnectionLost, .timedOut, .cannotConnectToHost] {
            let client = makeClient(script: [.failure(code), .response(status: 200, body: "{}")])
            try await client.startCull(sessionId: sessionId)
            XCTAssertEqual(ScriptedURLProtocol.requests.count, 2, "\(code)")
        }
    }

    func testRetryResendsTheSameRequestBody() async throws {
        let client = makeClient(script: [
            .failure(.networkConnectionLost),
            .response(status: 201, body: sessionJSON)
        ])

        _ = try await client.createSession(sessionId: sessionId, photoCount: 10)

        let bodies = try ScriptedURLProtocol.requests.map { request -> [String: Any] in
            let data = try XCTUnwrap(request.httpBodyStreamData ?? request.httpBody)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["session_id"] as? String, sessionId.lowercased)
        XCTAssertEqual(bodies[0]["photo_count"] as? Int, 10)
        XCTAssertEqual(bodies[1]["session_id"] as? String, sessionId.lowercased)
    }

    func testGivesUpAfterOneRetry() async {
        let client = makeClient(script: [
            .failure(.networkConnectionLost),
            .failure(.networkConnectionLost),
            .response(status: 200, body: "{}")
        ])

        do {
            try await client.startCull(sessionId: sessionId)
            XCTFail("expected the second failure to be thrown")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(ScriptedURLProtocol.requests.count, 2)
    }

    func testRetriesOnceForEveryRepeatSafeEndpoint() async throws {
        let photoId = UUID()
        let calls: [(String, (APIClient) async throws -> Void)] = [
            ("batch-pre-register", { try await $0.batchPreRegister(sessionId: self.sessionId, photoIds: [photoId]) }),
            ("register-photo", { try await $0.registerPhoto(sessionId: self.sessionId, photoId: photoId, storagePath: "u/s/p.jpg") }),
            ("mark-upload-complete", { try await $0.markUploadComplete(sessionId: self.sessionId) }),
            ("start-cull", { try await $0.startCull(sessionId: self.sessionId) })
        ]
        for (name, call) in calls {
            let client = makeClient(script: [.failure(.networkConnectionLost), .response(status: 200, body: "{}")])
            try await call(client)
            XCTAssertEqual(ScriptedURLProtocol.requests.count, 2, name)
        }
    }

    func testStateGuardedEndpointsAreNeverRetried() async {
        // A lost response can mean the server already applied the request; a
        // repeat would hit the state guard and 409, so these must surface the
        // original URLError after exactly one request.
        let calls: [(String, (APIClient) async throws -> Void)] = [
            ("finish-cull", { try await $0.finishCull(sessionId: self.sessionId) }),
            ("submit-comparison", { try await $0.submitComparison(comparisonId: UUID(), winnerId: UUID()) }),
            ("remove-photo", { try await $0.removePhoto(sessionId: self.sessionId, photoId: UUID()) })
        ]
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            for (name, call) in calls {
                let client = makeClient(script: [.failure(code), .response(status: 200, body: "{}")])
                do {
                    try await call(client)
                    XCTFail("\(name): expected \(code) to be thrown")
                } catch {
                    XCTAssertEqual((error as? URLError)?.code, code, name)
                }
                XCTAssertEqual(ScriptedURLProtocol.requests.count, 1, "\(name) \(code)")
            }
        }
    }

    func testFinishCullTimeoutIsNotRetried() async {
        let client = makeClient(script: [.failure(.timedOut), .response(status: 409, body: "{}")])

        do {
            try await client.finishCull(sessionId: sessionId)
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(ScriptedURLProtocol.requests.count, 1)
    }

    func testDoesNotRetryOtherURLErrors() async {
        let client = makeClient(script: [.failure(.notConnectedToInternet), .response(status: 200, body: "{}")])

        do {
            try await client.startCull(sessionId: sessionId)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(ScriptedURLProtocol.requests.count, 1)
    }

    func testDoesNotRetryHTTPErrors() async {
        let client = makeClient(script: [.response(status: 500, body: "boom"), .response(status: 200, body: "{}")])

        do {
            try await client.startCull(sessionId: sessionId)
            XCTFail("expected an error")
        } catch {
            guard case APIError.httpError(let status, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, 500)
        }
        XCTAssertEqual(ScriptedURLProtocol.requests.count, 1)
    }

    func testBearerTokenComesFromTheAsyncTokenProvider() async throws {
        let client = makeClient(script: [.response(status: 200, body: "{}")]) {
            try await Task.sleep(nanoseconds: 1_000_000)
            return "fresh-token"
        }

        try await client.startCull(sessionId: sessionId)

        XCTAssertEqual(
            ScriptedURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh-token"
        )
    }

    func testTokenProviderFailureSurfacesWithoutSendingARequest() async {
        let client = makeClient(script: [.response(status: 200, body: "{}")]) {
            throw APIError.unauthenticated
        }

        do {
            try await client.startCull(sessionId: sessionId)
            XCTFail("expected unauthenticated")
        } catch {
            guard case APIError.unauthenticated = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertTrue(ScriptedURLProtocol.requests.isEmpty)
    }
}

private extension URLRequest {
    /// URLProtocol sees the body as a stream, not `httpBody`.
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
