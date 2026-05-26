import Foundation
import Supabase

enum APIError: Error {
    case unauthenticated
    case httpError(statusCode: Int, body: Data)
}

@MainActor
final class APIClient: ObservableObject {
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

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        throw APIError.httpError(statusCode: (response as! HTTPURLResponse).statusCode, body: data)
    }

    // MARK: - create-session
    // POST { photo_count } → { session: { id, created_at, expires_at, status, photo_count } }

    func createSession(photoCount: Int) async throws -> APISession {
        let url = functionsBase.appending(path: "create-session")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["photo_count": photoCount])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(CreateSessionResponse.self, from: data).session
    }

    // MARK: - register-photo
    // POST { session_id, storage_path } → { photo: { id, ... } }

    func registerPhoto(sessionId: UUID, storagePath: String) async throws -> RegisteredPhoto {
        let url = functionsBase.appending(path: "register-photo")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased().lowercased(),
            "storage_path": storagePath,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(RegisterPhotoResponse.self, from: data).photo
    }

    // MARK: - next-pair
    // GET ?session_id=... → { comparison_id, photo_a, photo_b }

    func nextPair(sessionId: UUID) async throws -> NextPairResponse {
        var comps = URLComponents(url: functionsBase.appending(path: "next-pair"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "session_id", value: sessionId.uuidString.lowercased())]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(NextPairResponse.self, from: data)
    }

    // MARK: - submit-comparison
    // POST { comparison_id, winner_id } → { winner_id, loser_id, winner_new_rating, loser_new_rating }

    func submitComparison(comparisonId: UUID, winnerId: UUID) async throws -> SubmitComparisonResponse {
        let url = functionsBase.appending(path: "submit-comparison")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "comparison_id": comparisonId.uuidString.lowercased(),
            "winner_id": winnerId.uuidString.lowercased(),
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(SubmitComparisonResponse.self, from: data)
    }

    // MARK: - remove-photo
    // POST { session_id, photo_id } → { photo_id }

    func removePhoto(sessionId: UUID, photoId: UUID) async throws {
        let url = functionsBase.appending(path: "remove-photo")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased(),
            "photo_id":   photoId.uuidString.lowercased(),
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
    }

    // MARK: - session-status
    // GET ?session_id=... → { stage, is_complete, top_photo_count, total_comparisons }

    func sessionStatus(sessionId: UUID) async throws -> SessionStatus {
        var comps = URLComponents(url: functionsBase.appending(path: "session-status"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "session_id", value: sessionId.uuidString.lowercased())]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(SessionStatus.self, from: data)
    }

    // MARK: - results
    // GET ?session_id=...&limit=20 → { photos: [...], session: { stage, is_complete } }

    func results(sessionId: UUID, limit: Int = 20) async throws -> ResultsResponse {
        var comps = URLComponents(url: functionsBase.appending(path: "results"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "session_id", value: sessionId.uuidString.lowercased()),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(ResultsResponse.self, from: data)
    }

    // MARK: - start-cull
    // POST { session_id } → { stage }

    func startCull(sessionId: UUID) async throws -> StartCullResponse {
        let url = functionsBase.appending(path: "start-cull")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased(),
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(StartCullResponse.self, from: data)
    }

    // MARK: - next-cull
    // GET ?session_id=... → CullCard (done:true when empty)

    func nextCull(sessionId: UUID) async throws -> CullCard {
        var comps = URLComponents(url: functionsBase.appending(path: "next-cull"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "session_id", value: sessionId.uuidString.lowercased())]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(CullCard.self, from: data)
    }

    // MARK: - submit-cull
    // POST { session_id, photo_id, decision } → { done }

    func submitCull(sessionId: UUID, photoId: UUID, decision: String) async throws -> CullActionResponse {
        let url = functionsBase.appending(path: "submit-cull")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased(),
            "photo_id":   photoId.uuidString.lowercased(),
            "decision":   decision,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(CullActionResponse.self, from: data)
    }

    // MARK: - finish-cull
    // POST { session_id } → { stage }

    func finishCull(sessionId: UUID) async throws {
        let url = functionsBase.appending(path: "finish-cull")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId.uuidString.lowercased(),
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
    }
}
