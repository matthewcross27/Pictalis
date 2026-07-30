import Foundation
import Network

// Shared boilerplate for bridging NWPathMonitor into an AsyncStream that yields
// once whenever the path transitions to satisfied. PhotoPipeline and SyncService
// both use this in production; tests inject their own controlled AsyncStream
// instead of touching NWPathMonitor at all.
enum ConnectivityMonitor {
    static func makeStream(label: String) -> (stream: AsyncStream<Void>, monitor: NWPathMonitor) {
        let monitor = NWPathMonitor()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { continuation.yield() }
        }
        monitor.start(queue: DispatchQueue(label: label, qos: .background))
        return (stream, monitor)
    }
}
