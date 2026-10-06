import XCTest
import UIKit
@testable import Pictalis

final class PairPreloaderTests: XCTestCase {

    private func makePair() throws -> NextPairResponse {
        let json = Data("""
        {"comparison_id": "\(UUID().uuidString)",
         "photo_a": {"id": "\(UUID().uuidString)", "comparison_count": 0, "signed_url": "https://example.com/a.jpg"},
         "photo_b": {"id": "\(UUID().uuidString)", "comparison_count": 0, "signed_url": "https://example.com/b.jpg"},
         "stage": null}
        """.utf8)
        return try JSONDecoder().decode(NextPairResponse.self, from: json)
    }

    private func makeJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    func testPreloadWaitsForSlowerPhotoBeforeReturning() async throws {
        // Regression test: one card used to swap in its new image before the other
        // finished loading. The pair must not be handed to the UI until both are ready.
        let pair = try makePair()
        let slowId = pair.photoB.id
        let finished = LockedSet<UUID>()

        await PairPreloader.preload(pair) { photo in
            if photo.id == slowId { try await Task.sleep(for: .milliseconds(150)) }
            finished.insert(photo.id)
        }

        XCTAssertEqual(finished.snapshot, [pair.photoA.id, pair.photoB.id])
    }

    func testPreloadReturnsEvenWhenOnePhotoFails() async throws {
        let pair = try makePair()
        let failingId = pair.photoA.id
        let finished = LockedSet<UUID>()

        await PairPreloader.preload(pair) { photo in
            if photo.id == failingId { throw URLError(.notConnectedToInternet) }
            finished.insert(photo.id)
        }

        XCTAssertEqual(finished.snapshot, [pair.photoB.id])
    }

    func testImageLoaderPopulatesCacheAndSkipsFetchOnHit() async throws {
        let key = UUID()
        let url = URL(string: "https://example.com/c.jpg")!
        let data = makeJPEG()
        let fetchCount = LockedCounter()

        _ = try await PhotoImageLoader.load(url: url, cacheKey: key) { _ in
            fetchCount.increment()
            return data
        }
        XCTAssertNotNil(PhotoMemoryCache.shared.image(for: key, thumbnail: false))

        _ = try await PhotoImageLoader.load(url: url, cacheKey: key) { _ in
            fetchCount.increment()
            return data
        }
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testImageLoaderThrowsOnUndecodableData() async {
        let key = UUID()
        do {
            _ = try await PhotoImageLoader.load(url: URL(string: "https://example.com/d.jpg")!, cacheKey: key) { _ in
                Data([0x00, 0x01])
            }
            XCTFail("expected decode failure")
        } catch {
            XCTAssertNil(PhotoMemoryCache.shared.image(for: key, thumbnail: false))
        }
    }
}

private final class LockedSet<T: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = Set<T>()
    func insert(_ item: T) { lock.lock(); items.insert(item); lock.unlock() }
    var snapshot: Set<T> { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
