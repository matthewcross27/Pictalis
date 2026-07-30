import SwiftUI
import UIKit

/// In-memory photo cache keyed by photo id. Signed URLs change between API
/// responses, which defeats URLCache — keying by id lets a photo downloaded
/// on one screen render instantly on the next.
final class PhotoMemoryCache: @unchecked Sendable {
    static let shared = PhotoMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 300 }

    func image(for key: UUID) -> UIImage? {
        cache.object(forKey: key.uuidString as NSString)
    }

    func store(_ image: UIImage, for key: UUID) {
        cache.setObject(image, forKey: key.uuidString as NSString)
    }
}

/// AsyncImage replacement backed by PhotoMemoryCache.
struct CachedPhotoImage<Content: View>: View {
    let url: URL
    let cacheKey: UUID
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = PhotoMemoryCache.shared.image(for: cacheKey) {
            phase = .success(Image(uiImage: cached))
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let uiImage = UIImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            guard !Task.isCancelled else { return }
            PhotoMemoryCache.shared.store(uiImage, for: cacheKey)
            phase = .success(Image(uiImage: uiImage))
        } catch {
            if !Task.isCancelled { phase = .failure(error) }
        }
    }
}

/// Grid-cell thumbnail: scales to fill, shows a placeholder icon on failure.
struct ThumbnailPhotoImage: View {
    let url: URL
    let cacheKey: UUID

    var body: some View {
        CachedPhotoImage(url: url, cacheKey: cacheKey) { phase in
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
}

/// Fullscreen tap-to-dismiss photo viewer.
struct PhotoExpandedView: View {
    let id: UUID
    let signedUrl: URL
    var background: Color = .black
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            CachedPhotoImage(url: signedUrl, cacheKey: id) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.white)
                default:
                    ProgressView().tint(.white)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}
