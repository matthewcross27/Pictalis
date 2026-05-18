import Photos
import Supabase

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
    func start(assets: [PHAsset], sessionId: UUID, userId: UUID) {
        total = assets.count
        Task { await runAll(assets: assets, sessionId: sessionId, userId: userId) }
    }

    // MARK: - Private

    private func runAll(assets: [PHAsset], sessionId: UUID, userId: UUID) async {
        // Up to 4 concurrent uploads. Tasks in withTaskGroup inherit @MainActor
        // but suspend during async I/O, so the main thread remains responsive.
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var iter = assets.makeIterator()

            func addNext() {
                guard let asset = iter.next() else { return }
                group.addTask { @MainActor in await self.uploadOne(asset: asset, sessionId: sessionId, userId: userId) }
                inFlight += 1
            }

            // Seed the group with the first 4 tasks
            while inFlight < 4 { addNext() }

            // As each task finishes, add the next
            for await _ in group {
                inFlight -= 1
                addNext()
            }
        }
        isComplete = true
    }

    private func uploadOne(asset: PHAsset, sessionId: UUID, userId: UUID) async {
        do {
            let data = try await ImageCompressor.compress(asset: asset)
            let filename = "\(UUID().uuidString).jpg"
            let storagePath = "\(userId.uuidString)/\(sessionId.uuidString)/\(filename)"
            try await supabase.storage
                .from("working-copies")
                .upload(storagePath, data: data, options: FileOptions(contentType: "image/jpeg"))
            _ = try await api.registerPhoto(sessionId: sessionId, storagePath: storagePath)
            completed += 1
        } catch {
            print("Upload failed for asset: \(error)")
            // Increment completed so the progress bar still advances on failure
            completed += 1
        }
    }
}
