import Foundation
import Supabase

/// Central choke point mapping caught errors to short, generic, user-facing
/// text. No raw backend/SDK error text (status bodies, Supabase messages,
/// localizedDescription) should ever reach UI copy directly - always go
/// through here, and still call `ErrorReporter.capture(error)` with the
/// original error for diagnostics.
enum ErrorPresentation {
    /// `isNetworkPathSatisfied` is the device's current reachability. When it is
    /// satisfied, a lost connection or timeout is a failed request on a working
    /// network (not "offline"), so it gets the retry copy instead. `nil`
    /// (unknown) keeps the offline copy.
    static func message(
        for error: Error,
        isNetworkPathSatisfied: Bool? = NetworkPathStatus.shared.isSatisfied
    ) -> String {
        if isOffline(error) {
            if isNetworkPathSatisfied == true, isRequestFailureOnWorkingNetwork(error) {
                return "Could not reach Pictalis. Try again."
            }
            return "You're offline. Check your connection and try again."
        }
        if isRateLimited(error) {
            return "Too many requests right now - please try again in a moment."
        }
        return "Something went wrong. Please try again."
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private static func isRequestFailureOnWorkingNetwork(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .networkConnectionLost || urlError.code == .timedOut
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        if case APIError.rateLimited = error {
            return true
        }
        if case let APIError.httpError(statusCode, _) = error {
            return statusCode == 429
        }
        if let authError = error as? AuthError, case let .api(_, _, _, underlyingResponse) = authError {
            // 402: Supabase project-level quota/billing restriction.
            // 429: standard rate limiting.
            return underlyingResponse.statusCode == 402 || underlyingResponse.statusCode == 429
        }
        return false
    }
}
