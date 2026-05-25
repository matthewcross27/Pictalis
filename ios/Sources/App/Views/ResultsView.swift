import SwiftUI
import Photos

struct ResultsView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID

    @State private var photos: [RankedPhoto] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var exportingId: UUID?
    @State private var exportAlertMessage: String?
    @State private var sessionStage: String?
    @State private var isSessionComplete = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading results…")
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).padding()
                } else if photos.isEmpty {
                    Text("No photos ranked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(photos) { photo in
                                photoCell(photo: photo)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .navigationTitle("Your Favorites")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sessionStage != nil {
                        Text(isSessionComplete ? "Complete" : "In Progress")
                            .font(.caption.bold())
                            .foregroundStyle(isSessionComplete ? .green : .orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(isSessionComplete ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export All") { exportAll() }
                        .disabled(photos.isEmpty)
                }
            }
        }
        .task { await fetchResults() }
        .alert("Saved to Photos", isPresented: Binding(
            get: { exportAlertMessage != nil },
            set: { if !$0 { exportAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    // MARK: - Private

    @ViewBuilder
    private func photoCell(photo: RankedPhoto) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .background(Color(.secondarySystemBackground))
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 180)
                        .clipped()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .background(Color(.secondarySystemBackground))
                @unknown default:
                    EmptyView()
                }
            }

            // Export button overlay
            Button {
                Task { @MainActor in
                    if await exportPhoto(photo: photo) {
                        exportAlertMessage = "Photo saved to your library."
                    }
                }
            } label: {
                Group {
                    if exportingId == photo.id {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
                .background(.black.opacity(0.5))
                .clipShape(Circle())
            }
            .padding(8)
            .disabled(exportingId != nil)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fetchResults() async {
        isLoading = true
        do {
            let response = try await api.results(sessionId: sessionId)
            photos = response.photos
            sessionStage = response.session?.stage
            isSessionComplete = response.session?.isComplete ?? false
        } catch {
            errorMessage = "Failed to load results: \(error.localizedDescription)"
        }
        isLoading = false
    }

    @discardableResult
    private func exportPhoto(photo: RankedPhoto) async -> Bool {
        guard let url = URL(string: photo.signedUrl) else { return false }
        exportingId = photo.id
        defer { exportingId = nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return false }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            print("Export failed: \(error)")
            return false
        }
    }

    private func exportAll() {
        Task { @MainActor in
            var saved = 0
            for photo in photos {
                if await exportPhoto(photo: photo) { saved += 1 }
            }
            if saved > 0 {
                let noun = saved == 1 ? "photo" : "photos"
                exportAlertMessage = "\(saved) \(noun) saved to your library."
            }
        }
    }
}
