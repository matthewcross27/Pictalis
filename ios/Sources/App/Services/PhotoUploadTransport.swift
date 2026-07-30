import Foundation
import Supabase

protocol PhotoUploadTransport: Sendable {
    func upload(storagePath: String, data: Data) async throws
    func markUploaded(sessionId: UUID, photoId: UUID, storagePath: String) async throws
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

    func markUploaded(sessionId: UUID, photoId: UUID, storagePath: String) async throws {
        try await api.registerPhoto(sessionId: sessionId, photoId: photoId, storagePath: storagePath)
    }

    func markUploadComplete(sessionId: UUID) async throws {
        try await api.markUploadComplete(sessionId: sessionId)
    }

    private func isAlreadyExists(_ error: Error) -> Bool {
        guard let storageError = error as? StorageError else { return false }
        return storageError.statusCode == "409" || storageError.error == "Duplicate"
    }
}
