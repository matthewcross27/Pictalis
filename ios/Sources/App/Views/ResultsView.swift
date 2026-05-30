import SwiftUI
import Photos

struct ResultsView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    var onBack: (() -> Void)? = nil

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
            ZStack {
                Color.filmWhite.ignoresSafeArea()

                Group {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView().tint(Color.amber)
                            Text("Loading results…")
                                .font(.captionSerif)
                                .foregroundStyle(Color.secondaryText)
                        }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.bodySerif)
                            .foregroundStyle(Color.amber)
                            .padding(.horizontal, 32)
                    } else if photos.isEmpty {
                        Text("No photos ranked yet.")
                            .font(.bodySerif)
                            .foregroundStyle(Color.secondaryText)
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
            }
            .navigationTitle("Your Favorites")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.ink)
                        }
                    } else if sessionStage != nil {
                        StageBadge(stage: sessionStage ?? "", isComplete: isSessionComplete)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export All") { exportAll() }
                        .font(.labelSerif)
                        .foregroundStyle(Color.amber)
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
                    Color.grainPaper
                        .frame(maxWidth: .infinity, maxHeight: 180)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
                        .clipped()
                case .failure:
                    Color.grainPaper
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(Color.secondaryText)
                        }
                @unknown default:
                    EmptyView()
                }
            }

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
                .font(.system(size: 12, weight: .medium))
                .padding(8)
                .background(Color.photoOverlay)
                .clipShape(Capsule())
            }
            .padding(8)
            .disabled(exportingId != nil)
        }
        .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
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
