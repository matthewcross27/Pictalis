import Foundation

@MainActor
protocol ComparisonSubmitting {
    func submitComparison(comparisonId: UUID, winnerId: UUID) async throws
}

extension APIClient: ComparisonSubmitting {}

enum ComparisonSubmission {
    /// Used when a 429 carries no Retry-After; matches the server's polling-tier refill.
    static let defaultRetryWait: TimeInterval = 1
    /// A tap stuck behind the limiter this many times in a row is given up on.
    static let maxRateLimitRetries = 5
    static let maxRetryWait: TimeInterval = 10

    /// Submits one choice, and when the server rate-limits it waits out Retry-After and
    /// resubmits the same comparison and winner. The server rejects a 429 before it
    /// touches the comparison, so the repeat is not a duplicate submit and the user's tap
    /// is never lost. Any other error, or exhausting the retries, is thrown to the caller.
    static func submit(
        comparisonId: UUID,
        winnerId: UUID,
        api: some ComparisonSubmitting,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        var retries = 0
        while true {
            do {
                try await api.submitComparison(comparisonId: comparisonId, winnerId: winnerId)
                return
            } catch let error as APIError {
                guard case let .rateLimited(retryAfter) = error, retries < maxRateLimitRetries else {
                    throw error
                }
                retries += 1
                let wait = min(retryAfter ?? defaultRetryWait, maxRetryWait)
                try await sleep(.seconds(wait))
            }
        }
    }
}
