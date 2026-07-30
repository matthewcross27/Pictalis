import Foundation
import Observation
import Supabase

enum APIError: Error {
    case unauthenticated
    case httpError(statusCode: Int, body: Data)
}

@Observable
@MainActor
final class APIClient {
    private let supabase: SupabaseClient
    private let decoder = JSONDecoder()

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    // MARK: - Helpers

    private var functionsBase: URL {
        SupabaseConfig.url.appending(path: "functions/v1")
    }

    private func authHeader() throws -> String {
        guard let token = supabase.auth.currentSession?.accessToken else {
            throw APIError.unauthenticated
        }
        return "Bearer \(token)"
    }

    private func buildRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard var comps = URLComponents(url: functionsBase.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        throw APIError.httpError(statusCode: http.statusCode, body: data)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    // Shared by every endpoint whose entire request is `POST { session_id }`.
    private func postSessionId(_ path: String, sessionId: UUID) async throws -> Data {
        let req = try buildRequest(path: path, method: "POST", body: ["session_id": sessionId.lowercased])
        return try await send(req)
    }

    // Shared by every endpoint whose entire request is `GET ?session_id=...`.
    private func getSessionId(_ path: String, sessionId: UUID) async throws -> Data {
        let req = try buildRequest(
            path: path,
            queryItems: [URLQueryItem(name: "session_id", value: sessionId.lowercased)]
        )
        return try await send(req)
    }

    // MARK: - create-session
    // POST { photo_count } → { session: { id, created_at, expires_at, status, photo_count } }

    func createSession(photoCount: Int) async throws -> APISession {
        let req = try buildRequest(path: "create-session", method: "POST", body: ["photo_count": photoCount])
        let data = try await send(req)
        return try decoder.decode(CreateSessionResponse.self, from: data).session
    }

    // MARK: - register-photo
    // POST { session_id, photo_id, storage_path } → { photo: { id, ... } }

    func registerPhoto(sessionId: UUID, photoId: UUID, storagePath: String) async throws -> RegisteredPhoto {
        let req = try buildRequest(path: "register-photo", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "photo_id": photoId.lowercased,
            "storage_path": storagePath,
        ])
        let data = try await send(req)
        return try decoder.decode(RegisterPhotoResponse.self, from: data).photo
    }

    // MARK: - next-pair
    // GET ?session_id=... → { comparison_id, photo_a, photo_b }

    func nextPair(sessionId: UUID) async throws -> NextPairResponse {
        let data = try await getSessionId("next-pair", sessionId: sessionId)
        return try decoder.decode(NextPairResponse.self, from: data)
    }

    // MARK: - submit-comparison
    // POST { comparison_id, winner_id } → { winner_id, loser_id, winner_new_rating, loser_new_rating }

    func submitComparison(comparisonId: UUID, winnerId: UUID) async throws -> SubmitComparisonResponse {
        let req = try buildRequest(path: "submit-comparison", method: "POST", body: [
            "comparison_id": comparisonId.lowercased,
            "winner_id": winnerId.lowercased,
        ])
        let data = try await send(req)
        return try decoder.decode(SubmitComparisonResponse.self, from: data)
    }

    // MARK: - remove-photo
    // POST { session_id, photo_id } → { photo_id }

    func removePhoto(sessionId: UUID, photoId: UUID) async throws {
        let req = try buildRequest(path: "remove-photo", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "photo_id":   photoId.lowercased,
        ])
        _ = try await send(req)
    }

    // MARK: - session-status
    // GET ?session_id=... → { stage, is_complete, top_photo_count, total_comparisons }

    func sessionStatus(sessionId: UUID) async throws -> SessionStatus {
        let data = try await getSessionId("session-status", sessionId: sessionId)
        return try decoder.decode(SessionStatus.self, from: data)
    }

    // MARK: - results
    // GET ?session_id=...&limit=20 → { photos: [...], session: { stage, is_complete } }

    func results(sessionId: UUID, limit: Int = 20) async throws -> ResultsResponse {
        let req = try buildRequest(
            path: "results",
            queryItems: [
                URLQueryItem(name: "session_id", value: sessionId.lowercased),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ]
        )
        let data = try await send(req)
        return try decoder.decode(ResultsResponse.self, from: data)
    }

    // MARK: - start-cull
    // POST { session_id } → { stage }

    func startCull(sessionId: UUID) async throws -> StartCullResponse {
        let data = try await postSessionId("start-cull", sessionId: sessionId)
        return try decoder.decode(StartCullResponse.self, from: data)
    }

    // MARK: - finish-cull
    // POST { session_id } → { stage }

    func finishCull(sessionId: UUID) async throws {
        _ = try await postSessionId("finish-cull", sessionId: sessionId)
    }

    // MARK: - batch-submit-cull
    // POST { session_id, decisions } → { results }

    func batchSubmitCull(sessionId: UUID, decisions: [StoredDecision]) async throws -> BatchSubmitResponse {
        let req = try buildRequest(path: "batch-submit-cull", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "decisions":  decisions.map { d in
                ["photo_id": d.photoId.lowercased, "decision": d.decision.rawValue]
            },
        ])
        let data = try await send(req)
        return try decoder.decode(BatchSubmitResponse.self, from: data)
    }

    // MARK: - mark-upload-complete
    // POST { session_id } → { ok }

    func markUploadComplete(sessionId: UUID) async throws {
        _ = try await postSessionId("mark-upload-complete", sessionId: sessionId)
    }

    // MARK: - batch-pre-register
    // POST { session_id, photo_ids } → { ok }

    func batchPreRegister(sessionId: UUID, photoIds: [UUID]) async throws {
        let req = try buildRequest(path: "batch-pre-register", method: "POST", body: [
            "session_id": sessionId.lowercased,
            "photo_ids": photoIds.map { $0.lowercased },
        ])
        _ = try await send(req)
    }
}
