import Foundation
import PhotosUI
import SwiftUI

// Abstracts PhotosPickerItem so PhotoPipeline can be unit-tested with fixture data.
protocol PhotoDataLoading: Sendable {
    func loadData() async throws -> Data
}

struct PickerItemLoader: PhotoDataLoading {
    let item: PhotosPickerItem

    func loadData() async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CompressionError.noImageData
        }
        return data
    }
}

struct PendingPhoto: Identifiable, Sendable {
    let id: UUID
    let loader: any PhotoDataLoading

    init(id: UUID = UUID(), loader: any PhotoDataLoading) {
        self.id = id
        self.loader = loader
    }
}
