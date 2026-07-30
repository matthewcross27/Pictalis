import Sentry
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

/// AsyncImage replacement backed by PhotoMemoryCache. When `thumbnailMaxPixelSize`
/// is set, the decoded image is downsampled to that size before caching/display,
/// keeping grid-cell memory use proportional to what's actually on screen.
struct CachedPhotoImage<Content: View>: View {
    let url: URL
    let cacheKey: UUID
    var thumbnailMaxPixelSize: CGFloat? = nil
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    private var isThumbnail: Bool { thumbnailMaxPixelSize != nil }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = PhotoMemoryCache.shared.image(for: cacheKey, thumbnail: isThumbnail) {
            phase = .success(Image(uiImage: cached))
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let uiImage: UIImage?
            if let maxPixelSize = thumbnailMaxPixelSize {
                uiImage = Self.downsample(data: data, maxPixelSize: maxPixelSize)
            } else {
                uiImage = UIImage(data: data)
            }
            guard let uiImage else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            guard !Task.isCancelled else { return }
            PhotoMemoryCache.shared.store(uiImage, for: cacheKey, thumbnail: isThumbnail)
            phase = .success(Image(uiImage: uiImage))
        } catch {
            if !Task.isCancelled {
                SentrySDK.capture(error: error)
                phase = .failure(error)
            }
        }
    }

    /// Decodes directly at (approximately) the target pixel size via ImageIO,
    /// avoiding the full-resolution decode a plain UIImage(data:) would incur.
    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
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
