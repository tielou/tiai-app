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
