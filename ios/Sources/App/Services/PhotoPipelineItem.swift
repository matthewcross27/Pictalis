import Foundation

// The per-photo records PhotoPipeline's state machine runs over.
extension PhotoPipeline {
    enum ItemState: Equatable {
        case pending       // waiting to materialize
        case materialized  // compressed JPEG on disk, queued for upload
        case uploading     // an upload worker owns it
        case awaitingRegistration  // bytes in storage, queued for the next batch register call
        case registering   // part of an in-flight batch register call
        case uploaded      // bytes in storage, server row has upload_status='uploaded'
        case cancelled     // dropped — upload skipped or aborted; server has is_suppressed=true
        case parked        // retries exhausted; retried on a backoff timer, on connectivity, or by the user
        case failed        // local asset could not be read — terminal
    }

    struct Item {
        let loader: any PhotoDataLoading
        var state: ItemState = .pending
        var isKept = false
        var didUpload = false
        var fileURL: URL?
        var materializeAttempts = 0
    }
}
