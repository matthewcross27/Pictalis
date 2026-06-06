import PhotosUI
import Supabase
import SwiftUI
import UIKit

@MainActor
final class UploadService: ObservableObject {
    @Published private(set) var total: Int = 0
    @Published private(set) var completed: Int = 0
    @Published private(set) var failed: Int = 0
    @Published private(set) var isComplete = false

    var hasFailures: Bool { failed > 0 }

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
        await withTaskGroup(of: Bool.self) { group in
            var iter = items.makeIterator()

            func addNext() {
                guard let item = iter.next() else { return }
                group.addTask { @MainActor in
                    await self.uploadOne(item: item, sessionId: sessionId, userId: userId)
                }
            }

            for _ in 0..<4 { addNext() }
            for await didSucceed in group {
                if didSucceed { completed += 1 } else { failed += 1 }
                addNext()
            }
        }
        isComplete = true
        try? await api.markUploadComplete(sessionId: sessionId)
    }

    private func uploadOne(item: PhotosPickerItem, sessionId: UUID, userId: UUID) async -> Bool {
        do {
            guard let imageData = try await item.loadTransferable(type: Data.self) else {
                throw CompressionError.noImageData
            }
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
            return true
        } catch {
            print("Upload failed: \(error)")
            return false
        }
    }
}
