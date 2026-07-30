import SwiftUI

struct ResultsView: View {
    @Environment(APIClient.self) private var api

    let sessionId: UUID
    var onBack: (() -> Void)? = nil
    /// Photos already fetched by a previous screen — rendered immediately
    /// while the full list loads.
    var initialPhotos: [RankedPhoto] = []

    @State private var photos: [RankedPhoto] = []
    @State private var isLoading = true
    @State private var expandedPhoto: RankedPhoto?
    @State private var errorMessage: String?
    @State private var exportingId: UUID?
    @State private var exportAlertMessage: String?
    @State private var sessionStage: RankingStage?
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
                                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                    photoCell(photo: photo, rank: index + 1)
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
                    } else if let sessionStage {
                        StageBadge(stage: sessionStage, isComplete: isSessionComplete)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export All") { exportAll() }
                        .font(.labelSerif)
                        .foregroundStyle(Color.amber)
                        .disabled(photos.isEmpty)
                        .accessibilityLabel("Save to Photos library")
                        .accessibilityHint("Save all ranked photos to your Photos library")
                }
            }
        }
        .task {
            if photos.isEmpty, !initialPhotos.isEmpty {
                photos = initialPhotos
                isLoading = false
            }
            await fetchResults()
        }
        .fullScreenCover(item: $expandedPhoto) { photo in
            PhotoExpandedView(id: photo.id, signedUrl: photo.signedUrl) { expandedPhoto = nil }
        }
        .savedToPhotosAlert(message: $exportAlertMessage)
    }

    // MARK: - Private

    @ViewBuilder
    private func photoCell(photo: RankedPhoto, rank: Int) -> some View {
        Color.grainPaper
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
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
            .overlay(alignment: .bottomTrailing) {
                Button {
                    Task { @MainActor in
                        if await exportPhoto(photo: photo) {
                            exportAlertMessage = "Photo saved to your library."
                        }
                    }
                } label: {
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
                .accessibilityLabel("Save photo to library")
                .accessibilityHint("Save this photo to your Photos library")
                .padding(8)
                .disabled(exportingId != nil)
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
            .contentShape(RoundedRectangle(cornerRadius: .photoRadius))
            .onTapGesture { expandedPhoto = photo }
            .accessibilityLabel("Photo ranked number \(rank)")
            .accessibilityHint("View full screen")
    }

    private func fetchResults() async {
        isLoading = photos.isEmpty
        do {
            let response = try await api.results(sessionId: sessionId)
            photos = response.photos
            sessionStage = (response.session?.stage).flatMap { RankingStage(rawValue: $0) }
            isSessionComplete = response.session?.isComplete ?? false
        } catch {
            // Keep showing initial photos if the full fetch fails.
            if photos.isEmpty {
                errorMessage = "Failed to load results: \(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    @discardableResult
    private func exportPhoto(photo: RankedPhoto) async -> Bool {
        exportingId = photo.id
        defer { exportingId = nil }
        do {
            try await PhotoExporter.exportPhoto(signedUrl: photo.signedUrl)
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
                exportAlertMessage = PhotoExporter.savedMessage(count: saved)
            }
        }
    }
}
