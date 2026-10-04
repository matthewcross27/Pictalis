import Foundation
import Observation
import Supabase

enum APIError: Error {
    case unauthenticated
    case httpError(statusCode: Int, body: Data)
    // 429. `retryAfter` is the server's Retry-After wait, when it sent one.
    case rateLimited(retryAfter: TimeInterval?)

    var retryAfter: TimeInterval? {
        if case let .rateLimited(retryAfter) = self { return retryAfter }
        return nil
    }
}

@Observable
@MainActor
final class APIClient {
    private let urlSession: URLSession
    private let accessToken: () async throws -> String
    private let decoder = JSONDecoder()

    init(supabase: SupabaseClient, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.accessToken = {
            // `auth.session` refreshes an expired token; `currentSession` can
            // hand back a stale one that the server then rejects.
            do {
                return try await supabase.auth.session.accessToken
            } catch AuthError.sessionMissing {
                throw APIError.unauthenticated
            }
        }
    }

    /// Test seam: supplies the bearer token directly instead of a `SupabaseClient`.
    init(urlSession: URLSession, accessToken: @escaping () async throws -> String) {
        self.urlSession = urlSession
        self.accessToken = accessToken
    }

    // MARK: - Helpers

    private var functionsBase: URL {
        SupabaseConfig.url.appending(path: "functions/v1")
    }

    private func authHeader() async throws -> String {
        "Bearer \(try await accessToken())"
    }

    private func buildRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> URLRequest {
        guard var comps = URLComponents(url: functionsBase.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(try await authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    nonisolated static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 429 {
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: seconds.map { max(0, $0) })
        }
        throw APIError.httpError(statusCode: http.statusCode, body: data)
    }

    // A pooled connection the server or a middlebox dropped while idle fails
    // the next request with one of these even though the device is online, and
    // URLSession does not retry POSTs itself. A fresh attempt opens a new
    // connection, so a request that is safe to repeat is retried once
    // immediately. Retry is opt-in per call (`retryOnTransientFailure`): a
    // lost response can mean the server already applied the request, and
    // endpoints guarded on state (finish-cull, submit-comparison, remove-photo)
    // would answer the repeat with a 409 the UI cannot recover from.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    private func send(_ req: URLRequest, retryOnTransientFailure: Bool = false) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch where retryOnTransientFailure && Self.isTransient(error) {
            (data, response) = try await urlSession.data(for: req)
        }
        try Self.validate(response, data: data)
        return data
    }

    // Shared by every endpoint whose entire request is `POST { session_id }`.
    private func postSessionId(_ path: String, sessionId: UUID, retryOnTransientFailure: Bool) async throws -> Data {
        let req = try await buildRequest(path: path, method: "POST", body: ["session_id": sessionId.lowercased])
        return try await send(req, retryOnTransientFailure: retryOnTransientFailure)
    }

    // Shared by every endpoint whose entire request is `GET ?session_id=...`.
    private func getSessionId(_ path: String, sessionId: UUID, retryOnTransientFailure: Bool) async throws -> Data {
        let req = try await buildRequest(
            path: path,
            queryItems: [URLQueryItem(name: "session_id", value: sessionId.lowercased)]
        )
        return try await send(req, retryOnTransientFailure: retryOnTransientFailure)
    }

    // MARK: - create-session
    // POST { photo_count, session_id } → { session: { id, created_at, expires_at, status, photo_count } }
    // `sessionId` is client-generated and makes the call idempotent: repeating it
    // returns the already-created session rather than inserting another one.

    func createSession(sessionId: UUID, photoCount: Int) async throws -> APISession {
        let req = try await buildRequest(path: "create-session", method: "POST", body: [
            "photo_count": photoCount,
            "session_id": sessionId.lowercased
        ])
        let data = try await send(req, retryOnTransientFailure: true)
        return try decoder.decode(CreateSessionResponse.self, from: data).session
    }

    // MARK: - batch-register-photos
    // POST { session_id, photos: [{ photo_id, storage_path }] } → { results: [{ photo_id, success, error? }] }

    func registerPhotos(sessionId: UUID, photos: [PhotoRegistration]) async throws -> [PhotoRegistrationResult] {
        let req = try await buildRequest(path: "batch-register-photos", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "photos": photos.map { ["photo_id": $0.photoId.lowercased, "storage_path": $0.storagePath] }
        ])
        let data = try await send(req, retryOnTransientFailure: true)
        return try decoder.decode(BatchRegisterResponse.self, from: data).results
    }

    // MARK: - next-pair
    // GET ?session_id=... → { comparison_id, photo_a, photo_b }

    func nextPair(sessionId: UUID) async throws -> NextPairResponse {
        let data = try await getSessionId("next-pair", sessionId: sessionId, retryOnTransientFailure: false)
        return try decoder.decode(NextPairResponse.self, from: data)
    }

    // MARK: - submit-comparison
    // POST { comparison_id, winner_id } → { winner_id, loser_id, winner_new_rating, loser_new_rating }

    func submitComparison(comparisonId: UUID, winnerId: UUID) async throws {
        let req = try await buildRequest(path: "submit-comparison", method: "POST", body: [
            "comparison_id": comparisonId.lowercased,
            "winner_id": winnerId.lowercased
        ])
        _ = try await send(req, retryOnTransientFailure: false)
    }

    // MARK: - remove-photo
    // POST { session_id, photo_id } → { photo_id }

    func removePhoto(sessionId: UUID, photoId: UUID) async throws {
        let req = try await buildRequest(path: "remove-photo", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "photo_id": photoId.lowercased
        ])
        _ = try await send(req, retryOnTransientFailure: false)
    }

    // MARK: - session-status
    // GET ?session_id=... → { stage, is_complete, top_photo_count, total_comparisons }

    func sessionStatus(sessionId: UUID) async throws -> SessionStatus {
        let data = try await getSessionId("session-status", sessionId: sessionId, retryOnTransientFailure: true)
        return try decoder.decode(SessionStatus.self, from: data)
    }

    // MARK: - results
    // GET ?session_id=...&limit=20 → { photos: [...], session: { stage, is_complete } }

    func results(sessionId: UUID, limit: Int = 20) async throws -> ResultsResponse {
        let req = try await buildRequest(
            path: "results",
            queryItems: [
                URLQueryItem(name: "session_id", value: sessionId.lowercased),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        let data = try await send(req, retryOnTransientFailure: true)
        return try decoder.decode(ResultsResponse.self, from: data)
    }

    // MARK: - start-cull
    // POST { session_id } → { stage }

    func startCull(sessionId: UUID) async throws {
        _ = try await postSessionId("start-cull", sessionId: sessionId, retryOnTransientFailure: true)
    }

    // MARK: - finish-cull
    // POST { session_id } → { stage }

    func finishCull(sessionId: UUID) async throws {
        _ = try await postSessionId("finish-cull", sessionId: sessionId, retryOnTransientFailure: false)
    }

    // MARK: - batch-submit-cull
    // POST { session_id, decisions } → { results }

    func batchSubmitCull(sessionId: UUID, decisions: [StoredDecision]) async throws -> BatchSubmitResponse {
        let req = try await buildRequest(path: "batch-submit-cull", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "decisions": decisions.map { item in
                ["photo_id": item.photoId.lowercased, "decision": item.decision.rawValue]
            }
        ])
        let data = try await send(req, retryOnTransientFailure: false)
        return try decoder.decode(BatchSubmitResponse.self, from: data)
    }

    // MARK: - mark-upload-complete
    // POST { session_id } → { ok }

    func markUploadComplete(sessionId: UUID) async throws {
        _ = try await postSessionId("mark-upload-complete", sessionId: sessionId, retryOnTransientFailure: true)
    }

    // MARK: - batch-pre-register
    // POST { session_id, photo_ids } → { ok }

    func batchPreRegister(sessionId: UUID, photoIds: [UUID]) async throws {
        let req = try await buildRequest(path: "batch-pre-register", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "photo_ids": photoIds.map { $0.lowercased }
        ])
        _ = try await send(req, retryOnTransientFailure: true)
    }
}
