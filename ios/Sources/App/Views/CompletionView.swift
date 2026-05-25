import SwiftUI
import Photos

struct CompletionView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    let totalComparisons: Int
    var onSeeFullRankings: () -> Void

    @State private var photos: [RankedPhoto] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportAlertMessage: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.yellow)
                        Text("Your favorites are ready!")
                            .font(.title2.bold())
                        Text("\(totalComparisons) comparisons · \(photos.count) photos ranked")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    if isLoading {
                        ProgressView()
                            .padding()
                    } else if !photos.isEmpty {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(photos.prefix(10)) { photo in
                                AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                                    switch phase {
                                    case .empty:
                                        Color(.secondarySystemBackground)
                                            .aspectRatio(1, contentMode: .fill)
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(1, contentMode: .fill)
                                    case .failure:
                                        Color(.secondarySystemBackground)
                                            .aspectRatio(1, contentMode: .fill)
                                            .overlay {
                                                Image(systemName: "photo")
                                                    .foregroundStyle(.secondary)
                                            }
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal, 8)
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task { @MainActor in await exportAll() }
                        } label: {
                            Label("Export All Favorites", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(photos.isEmpty || isExporting)
                        .padding(.horizontal)

                        Button("See Full Rankings") { onSeeFullRankings() }
                            .font(.subheadline)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Done!")
            .navigationBarTitleDisplayMode(.inline)
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
