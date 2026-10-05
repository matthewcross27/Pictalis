import XCTest
import Sentry
@testable import Pictalis

final class SentryBreadcrumbFilterTests: XCTestCase {

    private func httpCrumb(url: String) -> Breadcrumb {
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.type = "http"
        crumb.data = ["url": url, "method": "POST", "status_code": 429]
        return crumb
    }

    func testDropsStorageUploadBreadcrumbs() {
        let crumb = httpCrumb(url: "https://ref.supabase.co/storage/v1/object/photos/uid/sid/p.jpg")
        XCTAssertNil(SentryBreadcrumbFilter.apply(crumb))
    }

    func testDropsBatchRegisterBreadcrumbs() {
        for name in ["batch-register-photos", "batch-pre-register"] {
            let crumb = httpCrumb(url: "https://ref.supabase.co/functions/v1/\(name)")
            XCTAssertNil(SentryBreadcrumbFilter.apply(crumb), name)
        }
    }

    func testKeepsOtherHttpBreadcrumbs() {
        let crumb = httpCrumb(url: "https://ref.supabase.co/functions/v1/next-pair")
        XCTAssertNotNil(SentryBreadcrumbFilter.apply(crumb))
    }

    func testKeepsNonHttpBreadcrumbsEvenWithMatchingUrl() {
        let crumb = Breadcrumb(level: .info, category: "ui.click")
        crumb.data = ["url": "https://ref.supabase.co/functions/v1/batch-register-photos"]
        XCTAssertNotNil(SentryBreadcrumbFilter.apply(crumb))
    }

    func testKeepsBreadcrumbsWithoutData() {
        XCTAssertNotNil(SentryBreadcrumbFilter.apply(Breadcrumb(level: .info, category: "http")))
    }
}
