import Sentry

/// Central choke point for reporting handled errors to Sentry, so the rest of
/// the app depends on this type instead of importing Sentry directly.
enum ErrorReporter {
    static func capture(_ error: Error) {
        SentrySDK.capture(error: error)
    }
}
