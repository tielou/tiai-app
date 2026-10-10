import Foundation

/// Every failure the app can show, in terms that survive being read on a phone.
///
/// Exactly one status is special: 401, the only one that should swap the screen
/// to a login prompt. Everything else is "the server said no, here is the
/// reason", and rendering that as "signed out" is how a 500 makes someone
/// retype a password they already have.
///
/// `unreachable` is deliberately not merged into `http`: a phone on hotel wifi
/// that cannot resolve the home hostname is a different conversation with the
/// user than a server that answered.
public enum APIError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case unreachable(String)
    case http(status: Int, message: String)
    case decoding(String)
    case invalidURL(String)
    case cancelled

    public var isUnauthorized: Bool { self == .unauthorized }

    /// Worth another attempt, as opposed to the request being wrong.
    ///
    /// A 404 retried is a 404 twice; a home server that blinks on a flaky link
    /// is the case the user cannot fix and should not have to notice. 429 is
    /// included because a rate limit is a request to wait, not a rejection.
    public var isTransient: Bool {
        switch self {
        case let .http(status, _): status == 408 || status == 429 || status >= 500
        case .unreachable: true
        case .notConfigured, .unauthorized, .decoding, .invalidURL, .cancelled: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No server configured."
        case .unauthorized: "Signed out — the server rejected the credentials."
        case let .unreachable(message): "Can't reach the server: \(message)"
        case let .http(status, message): "Server error \(status): \(message)"
        case let .decoding(message): "Unexpected response: \(message)"
        case let .invalidURL(message): "Bad URL: \(message)"
        case .cancelled: "Stopped."
        }
    }
}
