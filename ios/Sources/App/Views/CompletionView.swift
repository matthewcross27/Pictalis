import SwiftUI
import Photos

struct CompletionView: View {
    @Environment(APIClient.self) private var api

    let sessionId: UUID
    let totalComparisons: Int
    var onSeeFullRankings: ([RankedPhoto]) -> Void
    var onStartOver: () -> Void

    @State private var photos: [RankedPhoto] = []
    @State private var expandedPhoto: RankedPhoto?
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
                            ForEach(Array(photos.prefix(10).enumerated()), id: \.element.id) { index, photo in
                                Color.grainPaper
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        CachedPhotoImage(url: photo.signedUrl, cacheKey: photo.id) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFill()
                                            case .failure:
                                                Image(systemName: "photo")
                                                    .foregroundStyle(Color.secondaryText)
                                            default:
                                                EmptyView()
                                            }
                                        }
                                    }
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
                                    .contentShape(RoundedRectangle(cornerRadius: .photoRadius))
                                    .onTapGesture { expandedPhoto = photo }
                                    .accessibilityLabel("Photo ranked number \(index + 1)")
                                    .accessibilityHint("View full screen")
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
                        .accessibilityLabel("Save to Photos library")
                        .accessibilityHint("Save all favorite photos to your Photos library")

                        Button("See Full Rankings") { onSeeFullRankings(photos) }
                            .buttonStyle(GhostButtonStyle())
                            .accessibilityLabel("See Full Rankings")
                            .accessibilityHint("View the complete ranked list of your photos")

                        Button("Start Over") { onStartOver() }
                            .font(.captionSerif)
                            .foregroundStyle(Color.secondaryText)
                            .padding(.vertical, 10)
                            .accessibilityLabel("Start Over")
                            .accessibilityHint("Begin a new curation session")
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .task { await fetchTopPhotos() }
        .fullScreenCover(item: $expandedPhoto) { photo in
            PhotoExpandedView(photo: photo) { expandedPhoto = nil }
        }
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
