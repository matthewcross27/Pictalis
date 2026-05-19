import PhotosUI
import Supabase
import SwiftUI
import UIKit

@MainActor
final class UploadService: ObservableObject {
    @Published private(set) var total: Int = 0
    @Published private(set) var completed: Int = 0
    @Published private(set) var isComplete = false

    private let supabase: SupabaseClient
    private let api: APIClient

    init(supabase: SupabaseClient, api: APIClient) {
        self.supabase = supabase
        self.api = api
    }

    // Start uploading. Returns immediately; progress published via @Published.
    func start(items: [PhotosPickerItem], sessionId: UUID, userId: UUID) {
        total = items.count
        Task { await runAll(items: items, sessionId: sessionId, userId: userId) }
    }

    // MARK: - Private

    private func runAll(items: [PhotosPickerItem], sessionId: UUID, userId: UUID) async {
        await withTaskGroup(of: Void.self) { group in
            var iter = items.makeIterator()

            func addNext() {
                guard let item = iter.next() else { return }
                group.addTask { @MainActor in
                    await self.uploadOne(item: item, sessionId: sessionId, userId: userId)
                }
            }

            // Seed with up to 4 concurrent tasks; addNext() is a no-op when exhausted.
            for _ in 0..<4 { addNext() }

            for await _ in group { addNext() }
        }
        isComplete = true
    }

    private func uploadOne(item: PhotosPickerItem, sessionId: UUID, userId: UUID) async {
        do {
            guard let imageData = try await item.loadTransferable(type: Data.self) else {
                throw CompressionError.noImageData
            }
            // Compress off the main thread; create UIImage inside the detached task
            // so Sendable checking doesn't flag the Data→UIImage conversion.
            let compressed = try await Task.detached(priority: .userInitiated) {
                guard let image = UIImage(data: imageData) else {
                    throw CompressionError.noImageData
                }
                return try ImageCompressor.compressImage(image)
            }.value
            let filename = "\(UUID().uuidString.lowercased()).jpg"
            let storagePath = "\(userId.uuidString.lowercased())/\(sessionId.uuidString.lowercased())/\(filename)"
            try await supabase.storage
                .from("working-copies")
                .upload(storagePath, data: compressed, options: FileOptions(contentType: "image/jpeg"))
            _ = try await api.registerPhoto(sessionId: sessionId, storagePath: storagePath)
            completed += 1
        } catch {
            print("Upload failed: \(error)")
            completed += 1
        }
    }
}
