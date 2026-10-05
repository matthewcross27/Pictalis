import Foundation

// Whether a photo can be put on screen right now.
enum PhotoAvailability {
    case ready        // compressed copy on disk
    case pending      // still materializing
    case unavailable  // dropped or unreadable - will never be ready
}

// Read-only views over PhotoPipeline's per-photo state.
extension PhotoPipeline {
    func availability(for id: UUID) -> PhotoAvailability {
        guard let item = items[id] else { return .unavailable }
        switch item.state {
        case .pending: return .pending
        case .cancelled, .failed: return .unavailable
        default: return item.fileURL != nil ? .ready : .unavailable
        }
    }

    // Photos with a compressed copy on disk, regardless of whether they have been shown.
    var materializedCount: Int {
        items.values.reduce(0) { $0 + ($1.fileURL != nil ? 1 : 0) }
    }

    // "<id prefix>=<state>" for the first `count` photos in selection order, for diagnostics.
    func itemStateSummary(first count: Int) -> [String] {
        order.prefix(count).map { id in
            "\(id.uuidString.prefix(8))=\(items[id].map { String(describing: $0.state) } ?? "missing")"
        }
    }

    func registrationState(for id: UUID) -> PhotoRegistrationState {
        switch items[id]?.state {
        case .failed, nil: return .unavailable
        default: return .registered
        }
    }

    // True once nothing is in flight: every photo is registered, dropped, failed,
    // or parked (waiting on a retry). Unlike `isComplete`, parked photos don't hold it back.
    var isSettled: Bool {
        !order.isEmpty && !order.contains {
            switch items[$0]?.state {
            case .pending, .materialized, .uploading, .awaitingRegistration, .registering: return true
            default: return false
            }
        }
    }
}
