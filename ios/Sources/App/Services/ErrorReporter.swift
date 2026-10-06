import Sentry

/// Central choke point for reporting handled errors to Sentry, so the rest of
/// the app depends on this type instead of importing Sentry directly.
enum ErrorReporter {
    static func capture(_ error: Error) {
        SentrySDK.capture(error: error)
    }

    /// For a condition that is wrong but has no error to throw (e.g. a screen that is
    /// stuck). `context` is attached as a structured snapshot of the state at that moment.
    static func capture(message: String, context: [String: String]) {
        SentrySDK.capture(message: message) { scope in
            scope.setContext(value: context, key: "state_snapshot")
        }
    }
}
