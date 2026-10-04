import Foundation

/// The two backend calls "Start Curating" needs before the pipeline can run.
@MainActor
protocol SessionStartAPI {
    func createSession(sessionId: UUID, photoCount: Int) async throws -> APISession
    func batchPreRegister(sessionId: UUID, photoIds: [UUID]) async throws
}

extension APIClient: SessionStartAPI {}

/// One "Start Curating" attempt for a fixed photo selection. The session id and
/// photo ids are fixed up front and each backend step records its success, so
/// re-running after a failure resumes at the step that failed instead of
/// starting over (and never creates a second session for the same selection).
@MainActor
final class SessionStartAttempt {
    let sessionId: UUID
    let photos: [PendingPhoto]

    private var sessionCreated = false
    private var photosPreRegistered = false

    init(photos: [PendingPhoto], sessionId: UUID = UUID()) {
        self.photos = photos
        self.sessionId = sessionId
    }

    func run(api: some SessionStartAPI) async throws {
        if !sessionCreated {
            _ = try await api.createSession(sessionId: sessionId, photoCount: photos.count)
            sessionCreated = true
        }
        if !photosPreRegistered {
            try await api.batchPreRegister(sessionId: sessionId, photoIds: photos.map(\.id))
            photosPreRegistered = true
        }
    }
}
