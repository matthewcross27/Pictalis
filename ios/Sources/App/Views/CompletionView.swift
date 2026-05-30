import SwiftUI
import Photos

struct CompletionView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    let totalComparisons: Int
    var onSeeFullRankings: () -> Void
    var onStartOver: () -> Void

    @State private var photos: [RankedPhoto] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportAlertMessage: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your favorites\nare ready.")
                            .font(.displaySerif)
                            .foregroundStyle(Color.ink)
                            .tracking(-0.72)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(photos.isEmpty ? "Here are your top picks." : "Here are your top \(photos.count).")
                            .font(.bodySerif)
                            .foregroundStyle(Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 48)
                    .padding(.bottom, 32)

                    // Photo grid
                    if isLoading {
                        ProgressView()
                            .tint(Color.amber)
                            .padding(.vertical, 40)
                    } else if !photos.isEmpty {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(photos.prefix(10)) { photo in
                                AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                                    switch phase {
                                    case .empty:
                                        Color.grainPaper.aspectRatio(1, contentMode: .fill)
                                    case .success(let image):
                                        image.resizable().aspectRatio(1, contentMode: .fill)
                                    case .failure:
                                        Color.grainPaper
                                            .aspectRatio(1, contentMode: .fill)
                                            .overlay {
                                                Image(systemName: "photo")
                                                    .foregroundStyle(Color.secondaryText)
                                            }
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 32)
                    }

                    // Action buttons
                    VStack(spacing: 8) {
                        Button {
                            Task { @MainActor in await exportAll() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down")
                                Text("Export All Favorites")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(photos.isEmpty || isExporting)
                        .padding(.horizontal, 24)

                        Button("See Full Rankings") { onSeeFullRankings() }
                            .buttonStyle(GhostButtonStyle())

                        Button("Start Over") { onStartOver() }
                            .font(.captionSerif)
                            .foregroundStyle(Color.secondaryText)
                            .padding(.vertical, 10)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .task { await fetchTopPhotos() }
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

    private func fetchTopPhotos() async {
        isLoading = true
        if let response = try? await api.results(sessionId: sessionId, limit: 10) {
            photos = response.photos
        }
        isLoading = false
    }

    private func exportAll() async {
        isExporting = true
        var saved = 0
        for photo in photos.prefix(10) {
            guard let url = URL(string: photo.signedUrl) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { continue }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAsset(from: image)
                }
                saved += 1
            } catch {
                print("Export failed: \(error)")
            }
        }
        isExporting = false
        if saved > 0 {
            let noun = saved == 1 ? "photo" : "photos"
            exportAlertMessage = "\(saved) \(noun) saved to your library."
        }
    }
}
