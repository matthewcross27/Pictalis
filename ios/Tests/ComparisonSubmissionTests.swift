import XCTest
@testable import Pictalis

@MainActor
final class ComparisonSubmissionTests: XCTestCase {
    private final class FakeAPI: ComparisonSubmitting {
        var results: [Error?]
        private(set) var calls: [(comparisonId: UUID, winnerId: UUID)] = []

        init(results: [Error?]) { self.results = results }

        func submitComparison(comparisonId: UUID, winnerId: UUID) async throws {
            calls.append((comparisonId, winnerId))
            let next = results.isEmpty ? nil : results.removeFirst()
            if let next { throw next }
        }
    }

    private let comparisonId = UUID()
    private let winnerId = UUID()

    func testRateLimitedChoiceIsResubmittedAfterRetryAfterWithTheSameIds() async throws {
        let api = FakeAPI(results: [APIError.rateLimited(retryAfter: 2), nil])
        var waits: [Duration] = []

        try await ComparisonSubmission.submit(
            comparisonId: comparisonId, winnerId: winnerId, api: api,
            sleep: { waits.append($0) }
        )

        XCTAssertEqual(api.calls.count, 2)
        XCTAssertTrue(api.calls.allSatisfy { $0.comparisonId == comparisonId && $0.winnerId == winnerId })
        XCTAssertEqual(waits, [.seconds(2)])
    }

    func testMissingRetryAfterFallsBackToTheDefaultWait() async throws {
        let api = FakeAPI(results: [APIError.rateLimited(retryAfter: nil), nil])
        var waits: [Duration] = []

        try await ComparisonSubmission.submit(
            comparisonId: comparisonId, winnerId: winnerId, api: api,
            sleep: { waits.append($0) }
        )

        XCTAssertEqual(waits, [.seconds(ComparisonSubmission.defaultRetryWait)])
    }

    func testOversizedRetryAfterIsCapped() async throws {
        let api = FakeAPI(results: [APIError.rateLimited(retryAfter: 600), nil])
        var waits: [Duration] = []

        try await ComparisonSubmission.submit(
            comparisonId: comparisonId, winnerId: winnerId, api: api,
            sleep: { waits.append($0) }
        )

        XCTAssertEqual(waits, [.seconds(ComparisonSubmission.maxRetryWait)])
    }

    func testPersistentRateLimitGivesUpAfterTheRetryBudget() async {
        let limited = APIError.rateLimited(retryAfter: 0)
        let api = FakeAPI(results: Array(repeating: limited, count: 20))

        do {
            try await ComparisonSubmission.submit(
                comparisonId: comparisonId, winnerId: winnerId, api: api, sleep: { _ in }
            )
            XCTFail("expected the rate limit to surface once retries are spent")
        } catch {
            XCTAssertEqual((error as? APIError)?.retryAfter, 0)
        }
        XCTAssertEqual(api.calls.count, ComparisonSubmission.maxRateLimitRetries + 1)
    }

    func testOtherErrorsAreNotRetried() async {
        let api = FakeAPI(results: [APIError.httpError(statusCode: 409, body: Data()), nil])

        do {
            try await ComparisonSubmission.submit(
                comparisonId: comparisonId, winnerId: winnerId, api: api, sleep: { _ in }
            )
            XCTFail("expected the 409 to surface")
        } catch {
            guard case APIError.httpError(409, _)? = error as? APIError else {
                return XCTFail("Expected httpError 409, got \(error)")
            }
        }
        XCTAssertEqual(api.calls.count, 1)
    }
}
