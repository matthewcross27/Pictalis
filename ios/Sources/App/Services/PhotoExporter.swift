import Foundation
import Photos
import UIKit

/// Downloads a ranked photo from its signed URL and saves it to the user's Photos library.
enum PhotoExporter {
    enum ExportError: Error {
        case invalidImageData
    }

    static func exportPhoto(signedUrl: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: signedUrl)
        guard let image = UIImage(data: data) else { throw ExportError.invalidImageData }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }

    /// Exports each photo, logging (not throwing) individual failures, and returns the count saved.
    @discardableResult
    static func exportAll(_ photos: [RankedPhoto]) async -> Int {
        var saved = 0
        for photo in photos {
            do {
                try await exportPhoto(signedUrl: photo.signedUrl)
                saved += 1
            } catch {
                print("Export failed: \(error)")
            }
        }
        return saved
    }

    /// A pluralized "N photo(s) saved to your library." confirmation message.
    static func savedMessage(count: Int) -> String {
        let noun = count == 1 ? "photo" : "photos"
        return "\(count) \(noun) saved to your library."
    }
}
