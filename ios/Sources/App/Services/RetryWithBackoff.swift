import Foundation

// Retries `operation` after each entry in `delays` is exhausted by a throw, adding
// random jitter from `jitter` (if given) to each wait. Cancellation is never treated
// as a transient failure to retry - it rethrows immediately. On final exhaustion,
// rethrows the last error.
func retryWithBackoff<T>(
    delays: [Duration],
    jitter: ClosedRange<Int>? = nil,
    operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard attempt < delays.count else { throw error }
            var delay = delays[attempt]
            if let jitter { delay += Duration.milliseconds(Int.random(in: jitter)) }
            try await Task.sleep(for: delay)
            attempt += 1
        }
    }
}
