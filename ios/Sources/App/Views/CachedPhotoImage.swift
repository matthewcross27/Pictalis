import SwiftUI
import UIKit
import ImageIO

/// In-memory photo cache keyed by photo id. Signed URLs change between API
/// responses, which defeats URLCache — keying by id lets a photo downloaded
/// on one screen render instantly on the next.
///
/// Thumbnails and full-quality images are kept in separate NSCaches: grid
/// cells decode+cache a downsampled copy (see `downsample`) so up to ~300
/// on-screen thumbnails don't each retain a full 1920px decoded bitmap
/// (~11MB apiece, multiple GB across a session) for a ~180pt cell. Both
/// caches also set `totalCostLimit` (cost = decoded byte size), since a
/// full ranking session can page through most/all of a session's photos in
/// ComparisonView/PhotoExpandedView, and `countLimit` alone doesn't bound
/// fullCache's worst case (up to 300 * ~11MB ≈ 3.3GB).
final class PhotoMemoryCache: @unchecked Sendable {
    static let shared = PhotoMemoryCache()
    private let fullCache = NSCache<NSString, UIImage>()
    private let thumbnailCache = NSCache<NSString, UIImage>()

    private init() {
        fullCache.countLimit = 300
        fullCache.totalCostLimit = 200 * 1024 * 1024
        thumbnailCache.countLimit = 300
        thumbnailCache.totalCostLimit = 150 * 1024 * 1024
    }

    func image(for key: UUID, thumbnail: Bool) -> UIImage? {
        cache(thumbnail).object(forKey: key.uuidString as NSString)
    }

    func store(_ image: UIImage, for key: UUID, thumbnail: Bool) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache(thumbnail).setObject(image, forKey: key.uuidString as NSString, cost: cost)
    }

    private func cache(_ thumbnail: Bool) -> NSCache<NSString, UIImage> {
        thumbnail ? thumbnailCache : fullCache
    }
}

/// Fetches, decodes and caches a photo in PhotoMemoryCache. Shared by
/// CachedPhotoImage (on demand) and PairPreloader (ahead of a pair swap) so
/// both paths populate the same cache entry.
enum PhotoImageLoader {
    typealias Fetch = @Sendable (URL) async throws -> Data

    static let networkFetch: Fetch = { url in
        try await URLSession.shared.data(from: url).0
    }

    /// Returns the cached image when present, otherwise downloads, decodes (downsampled
    /// when `thumbnailMaxPixelSize` is set) and caches it.
    static func load(
        url: URL,
        cacheKey: UUID,
        thumbnailMaxPixelSize: CGFloat? = nil,
        fetch: Fetch = networkFetch
    ) async throws -> UIImage {
        let isThumbnail = thumbnailMaxPixelSize != nil
        if let cached = PhotoMemoryCache.shared.image(for: cacheKey, thumbnail: isThumbnail) {
            return cached
        }
        let data = try await fetch(url)
        let uiImage: UIImage?
        if let maxPixelSize = thumbnailMaxPixelSize {
            uiImage = downsample(data: data, maxPixelSize: maxPixelSize)
        } else {
            uiImage = UIImage(data: data)
        }
        guard let uiImage else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        PhotoMemoryCache.shared.store(uiImage, for: cacheKey, thumbnail: isThumbnail)
        return uiImage
    }

    /// Decodes directly at (approximately) the target pixel size via ImageIO,
    /// avoiding the full-resolution decode a plain UIImage(data:) would incur.
    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// AsyncImage replacement backed by PhotoMemoryCache. When `thumbnailMaxPixelSize`
/// is set, the decoded image is downsampled to that size before caching/display,
/// keeping grid-cell memory use proportional to what's actually on screen.
///
/// A cache hit is applied in `init`, so the very first render already shows the
/// image. Callers that swap the photo for a slot should also key the view by the
/// photo id (`.id(photo.id)`) so a stale `phase` is never carried across photos.
struct CachedPhotoImage<Content: View>: View {
    let url: URL
    let cacheKey: UUID
    var thumbnailMaxPixelSize: CGFloat?
    /// Called once the decoded image is available (cache hit or download), so a
    /// parent can size itself to the photo's real aspect ratio.
    var onLoaded: ((CGSize) -> Void)?
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase

    init(
        url: URL,
        cacheKey: UUID,
        thumbnailMaxPixelSize: CGFloat? = nil,
        onLoaded: ((CGSize) -> Void)? = nil,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.cacheKey = cacheKey
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize
        self.onLoaded = onLoaded
        self.content = content
        let cached = PhotoMemoryCache.shared.image(for: cacheKey, thumbnail: thumbnailMaxPixelSize != nil)
        _phase = State(initialValue: cached.map { .success(Image(uiImage: $0)) } ?? .empty)
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        do {
            let uiImage = try await PhotoImageLoader.load(
                url: url, cacheKey: cacheKey, thumbnailMaxPixelSize: thumbnailMaxPixelSize
            )
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: uiImage))
            onLoaded?(uiImage.size)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                ErrorReporter.capture(error)
                phase = .failure(error)
            }
        }
    }
}

/// Makes a pair appear as one step: both full-size images are loaded into
/// PhotoMemoryCache before the pair is handed to the UI, so neither card has to
/// load (and later swap in) its image after the other.
enum PairPreloader {
    /// Waits for both photos to finish loading. A photo that fails to load does not
    /// block the pair (its card shows the failure placeholder), so this never throws.
    static func preload(
        _ pair: NextPairResponse,
        load: @escaping @Sendable (PairPhoto) async throws -> Void = { photo in
            _ = try await PhotoImageLoader.load(url: photo.signedUrl, cacheKey: photo.id)
        }
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for photo in [pair.photoA, pair.photoB] {
                group.addTask { try? await load(photo) }
            }
        }
    }
}

/// Grid-cell thumbnail: scales to fill, shows a placeholder icon on failure.
struct ThumbnailPhotoImage: View {
    let url: URL
    let cacheKey: UUID

    var body: some View {
        // 3x the largest grid cell size (~180pt) covers Retina displays with
        // headroom for scaledToFill cropping, while staying far below full-res.
        CachedPhotoImage(url: url, cacheKey: cacheKey, thumbnailMaxPixelSize: 540) { phase in
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
