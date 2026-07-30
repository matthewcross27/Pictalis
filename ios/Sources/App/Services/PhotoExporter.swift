import Foundation
import Photos
import UIKit

/// Downloads a ranked photo from its signed URL and saves it to the user's Photos library.
enum PhotoExporter {
    enum ExportError: Error {
        case invalidURL
        case invalidImageData
    }

    static func exportPhoto(signedUrl: String) async throws {
        guard let url = URL(string: signedUrl) else { throw ExportError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
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
}
