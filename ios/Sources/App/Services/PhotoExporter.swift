import Foundation
import Photos
import Sentry
import UIKit

/// Downloads a ranked photo from its signed URL and saves it to the user's Photos library.
enum PhotoExporter {
    enum ExportError: Error {
        case invalidImageData
    }

    private static func downloadImage(from url: URL) async throws -> UIImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else { throw ExportError.invalidImageData }
        return image
    }

    static func exportPhoto(signedUrl: URL) async throws {
        let image = try await downloadImage(from: signedUrl)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }

    /// Downloads every photo concurrently, then saves all successful downloads in a single
    /// Photos library transaction (instead of one round trip + one transaction per photo),
    /// logging individual download failures. Returns the count saved.
    @discardableResult
    static func exportAll(_ photos: [RankedPhoto]) async -> Int {
        let images: [UIImage] = await withTaskGroup(of: UIImage?.self) { group in
            for photo in photos {
                group.addTask {
                    do {
                        return try await downloadImage(from: photo.signedUrl)
                    } catch {
                        SentrySDK.capture(error: error)
                        return nil
                    }
                }
            }
            var results: [UIImage] = []
            for await image in group {
                if let image { results.append(image) }
            }
            return results
        }
        guard !images.isEmpty else { return 0 }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetCreationRequest.creationRequestForAsset(from: image)
                }
            }
            return images.count
        } catch {
            SentrySDK.capture(error: error)
            return 0
        }
    }

    /// A pluralized "N photo(s) saved to your library." confirmation message.
    static func savedMessage(count: Int) -> String {
        let noun = count == 1 ? "photo" : "photos"
        return "\(count) \(noun) saved to your library."
    }
}
