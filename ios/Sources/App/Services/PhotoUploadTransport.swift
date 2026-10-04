import Foundation
import Supabase

struct PhotoRegistration: Sendable, Equatable {
    let photoId: UUID
    let storagePath: String
}

protocol PhotoUploadTransport: Sendable {
    func upload(storagePath: String, data: Data) async throws
    // Registers a batch of already-uploaded photos. Throws if the whole request
    // failed (nothing is known to be registered); otherwise returns one result
    // per photo, and only the ones with `success == false` need retrying.
    func registerPhotos(sessionId: UUID, photos: [PhotoRegistration]) async throws -> [PhotoRegistrationResult]
    func markUploadComplete(sessionId: UUID) async throws
}

struct SupabaseUploadTransport: PhotoUploadTransport {
    let supabase: SupabaseClient
    let api: APIClient

    func upload(storagePath: String, data: Data) async throws {
        do {
            try await supabase.storage
                .from("working-copies")
                .upload(storagePath, data: data, options: FileOptions(contentType: "image/jpeg"))
        } catch {
            // A retry after a success whose response was lost: the object is
            // already there, which is the outcome we wanted.
            if isAlreadyExists(error) { return }
            throw error
        }
    }

    func registerPhotos(sessionId: UUID, photos: [PhotoRegistration]) async throws -> [PhotoRegistrationResult] {
        try await api.registerPhotos(sessionId: sessionId, photos: photos)
    }

    func markUploadComplete(sessionId: UUID) async throws {
        try await api.markUploadComplete(sessionId: sessionId)
    }

    private func isAlreadyExists(_ error: Error) -> Bool {
        guard let storageError = error as? StorageError else { return false }
        return storageError.statusCode == "409" || storageError.error == "Duplicate"
    }
}
