import Foundation
import Network
import os

/// Latest `NWPathMonitor` reachability, readable synchronously. Lets error copy
/// tell "the device has no network" apart from "the network is fine but this
/// request failed" (e.g. a dropped pooled connection).
final class NetworkPathStatus: @unchecked Sendable {
    static let shared = NetworkPathStatus()

    private struct State {
        var monitor: NWPathMonitor?
        var isSatisfied: Bool?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `nil` until the monitor has reported its first path (or before `start()`).
    var isSatisfied: Bool? { state.withLock { $0.isSatisfied } }

    /// Idempotent. Call once at launch so a value is available by the first request.
    func start() {
        state.withLock { state in
            guard state.monitor == nil else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.state.withLock { $0.isSatisfied = (path.status == .satisfied) }
            }
            monitor.start(queue: DispatchQueue(label: "NetworkPathStatus", qos: .utility))
            state.monitor = monitor
        }
    }
}
