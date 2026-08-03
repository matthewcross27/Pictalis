import XCTest
import Supabase
@testable import Pictalis

final class ErrorPresentationTests: XCTestCase {
    func testQuotaExceededMapsToRateLimitedMessage() {
        // Real shape observed from a Supabase project over its usage quota:
        // HTTP 402 with a plain {"message": ...} body (no structured error code).
        let response = HTTPURLResponse(
            url: URL(string: "https://example.supabase.co/auth/v1/signup")!,
            statusCode: 402,
            httpVersion: nil,
            headerFields: nil
        )!
        let error = AuthError.api(
            message: "Service for this project is restricted due to the following violations: exceed_storage_size_quota.",
            errorCode: .unknown,
            underlyingData: Data(),
            underlyingResponse: response
        )

        let message = ErrorPresentation.message(for: error)

        XCTAssertEqual(message, "Too many requests right now - please try again in a moment.")
        XCTAssertFalse(message.contains("quota"))
        XCTAssertFalse(message.contains("Supabase"))
    }

    func testAppRateLimitMapsToRateLimitedMessage() {
        let error = APIError.httpError(statusCode: 429, body: Data())

        XCTAssertEqual(
            ErrorPresentation.message(for: error),
            "Too many requests right now - please try again in a moment."
        )
    }

    func testOfflineMapsToOfflineMessage() {
        let error = URLError(.notConnectedToInternet)

        XCTAssertEqual(
            ErrorPresentation.message(for: error),
            "You're offline. Check your connection and try again."
        )
    }

    func testUnrelatedErrorMapsToGenericFallback() {
        let error = APIError.unauthenticated

        XCTAssertEqual(
            ErrorPresentation.message(for: error),
            "Something went wrong. Please try again."
        )
    }

    func testHttpErrorBodyNeverAppearsInAnyMessage() {
        let sensitiveBody = Data("internal-diagnostic-detail-should-never-leak".utf8)
        let error = APIError.httpError(statusCode: 500, body: sensitiveBody)

        let message = ErrorPresentation.message(for: error)

        XCTAssertFalse(message.contains("internal-diagnostic-detail-should-never-leak"))
    }
}
