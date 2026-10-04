import Sentry

/// Drops the automatic `http` breadcrumbs for per-photo upload traffic. Every photo
/// produces a Storage upload and a register-photo call (plus retries and 429s), which
/// flushes Sentry's fixed-size breadcrumb ring in about a minute and pushes out the
/// breadcrumbs that explain an error.
enum SentryBreadcrumbFilter {
    private static let noisyPathFragments = ["/storage/v1/object/", "/functions/v1/register-photo"]

    static func apply(_ crumb: Breadcrumb) -> Breadcrumb? {
        isNoisyUploadRequest(crumb) ? nil : crumb
    }

    static func isNoisyUploadRequest(_ crumb: Breadcrumb) -> Bool {
        guard crumb.category == "http", let url = crumb.data?["url"] as? String else { return false }
        return noisyPathFragments.contains { url.contains($0) }
    }
}
