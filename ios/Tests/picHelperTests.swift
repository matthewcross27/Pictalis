import XCTest
import UIKit
@testable import Pictalis

final class ModelsTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testCreateSessionResponseDecodes() throws {
        let json = """
        {"session":{"id":"550e8400-e29b-41d4-a716-446655440000","created_at":"2026-05-17T00:00:00Z","expires_at":"2026-05-18T00:00:00Z","status":"active","photo_count":10}}
        """.data(using: .utf8)!
        let response = try decoder.decode(CreateSessionResponse.self, from: json)
        XCTAssertEqual(response.session.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(response.session.status, "active")
        XCTAssertEqual(response.session.photoCount, 10)
    }

    func testNextPairResponseDecodes() throws {
        let json = """
        {"comparison_id":"aaaabbbb-e29b-41d4-a716-446655440000","photo_a":{"id":"11112222-e29b-41d4-a716-446655440000","storage_path":"uid/sid/a.jpg","thumbnail_path":null,"elo_rating":1200.0,"comparison_count":0,"signed_url":"https://example.com/a.jpg"},"photo_b":{"id":"33334444-e29b-41d4-a716-446655440000","storage_path":"uid/sid/b.jpg","thumbnail_path":null,"elo_rating":1200.0,"comparison_count":0,"signed_url":"https://example.com/b.jpg"}}
        """.data(using: .utf8)!
        let response = try decoder.decode(NextPairResponse.self, from: json)
        XCTAssertEqual(response.comparisonId, UUID(uuidString: "aaaabbbb-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(response.photoA.signedUrl, URL(string: "https://example.com/a.jpg")!)
        XCTAssertEqual(response.photoB.comparisonCount, 0)
    }

    func testResultsResponseDecodes() throws {
        let json = """
        {"photos":[{"id":"11112222-e29b-41d4-a716-446655440000","storage_path":"uid/sid/a.jpg","thumbnail_path":null,"elo_rating":1350.0,"uncertainty":null,"comparison_count":5,"is_suppressed":false,"cluster_id":null,"quality_flags":null,"signed_url":"https://example.com/a.jpg"}]}
        """.data(using: .utf8)!
        let response = try decoder.decode(ResultsResponse.self, from: json)
        XCTAssertEqual(response.photos.count, 1)
        XCTAssertEqual(response.photos[0].eloRating, 1350.0)
        XCTAssertFalse(response.photos[0].isSuppressed)
    }

    func testAPIErrorResponseDecodes() throws {
        let json = """
        {"error":"Comparison not found"}
        """.data(using: .utf8)!
        let response = try decoder.decode(APIErrorResponse.self, from: json)
        XCTAssertEqual(response.error, "Comparison not found")
    }

    func testSessionStatusDecodes() throws {
        let json = """
        {"stage":"stage2","is_complete":false,"top_photo_count":20,"total_comparisons":47}
        """.data(using: .utf8)!
        let status = try decoder.decode(SessionStatus.self, from: json)
        XCTAssertEqual(status.stage, "stage2")
        XCTAssertFalse(status.isComplete)
        XCTAssertEqual(status.topPhotoCount, 20)
        XCTAssertEqual(status.totalComparisons, 47)
    }

    func testResultsResponseDecodesWithSession() throws {
        let json = """
        {"photos":[{"id":"11112222-e29b-41d4-a716-446655440000","storage_path":"uid/sid/a.jpg","thumbnail_path":null,"elo_rating":1350.0,"uncertainty":null,"comparison_count":5,"is_suppressed":false,"cluster_id":null,"signed_url":"https://example.com/a.jpg"}],"session":{"stage":"complete","is_complete":true}}
        """.data(using: .utf8)!
        let response = try decoder.decode(ResultsResponse.self, from: json)
        XCTAssertEqual(response.photos.count, 1)
        XCTAssertEqual(response.session?.stage, "complete")
        XCTAssertEqual(response.session?.isComplete, true)
    }

    func testNextPairResponseDecodesWithStage() throws {
        let json = """
        {"comparison_id":"aaaabbbb-e29b-41d4-a716-446655440000","stage":"stage2","photo_a":{"id":"11112222-e29b-41d4-a716-446655440000","storage_path":"uid/sid/a.jpg","thumbnail_path":null,"elo_rating":1200.0,"comparison_count":0,"signed_url":"https://example.com/a.jpg"},"photo_b":{"id":"33334444-e29b-41d4-a716-446655440000","storage_path":"uid/sid/b.jpg","thumbnail_path":null,"elo_rating":1200.0,"comparison_count":0,"signed_url":"https://example.com/b.jpg"}}
        """.data(using: .utf8)!
        let response = try decoder.decode(NextPairResponse.self, from: json)
        XCTAssertEqual(response.stage, "stage2")
    }
}

final class APIClientTests: XCTestCase {
    func testAPIErrorCarriesStatusCode() throws {
        let error = APIError.httpError(statusCode: 404, body: Data())
        if case .httpError(let code, _) = error {
            XCTAssertEqual(code, 404)
        } else {
            XCTFail("Expected httpError")
        }
    }
}

final class ImageCompressorTests: XCTestCase {
    func testCompressionScalesLargeImage() async throws {
        let image = TestImage.make(width: 3000, height: 2000, color: .systemBlue)
        let data = try ImageCompressor.compressImage(image)
        let compressed = UIImage(data: data)!
        // Longest edge must be ≤ 1920
        XCTAssertLessThanOrEqual(max(compressed.size.width, compressed.size.height), 1920)
        // Must be smaller than an uncompressed 3000×2000 JPEG
        XCTAssertLessThan(data.count, 3_000 * 2_000 * 3)
    }

    func testCompressionPreservesSmallImage() async throws {
        let image = TestImage.make(width: 800, height: 600, color: .systemRed)
        let data = try ImageCompressor.compressImage(image)
        let compressed = UIImage(data: data)!
        // Small image must not be upscaled
        XCTAssertLessThanOrEqual(max(compressed.size.width, compressed.size.height), 1920)
        XCTAssertGreaterThan(data.count, 0)
    }
}
