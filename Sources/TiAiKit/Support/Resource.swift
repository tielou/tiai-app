import Foundation

/// A polled resource with the states a chat list actually needs.
///
/// Ported from tiControl's `useApi`, including the distinction that matters
/// most: `isStale` (data on screen while a refresh is in flight) is not
/// `isLoading` (nothing on screen yet). Collapsing them is how a list blanks
/// itself on every pull-to-refresh.
///
/// `unauthorized` is tracked apart from `error` because it is the one failure
/// that changes the screen rather than the row. A 401 means the JWT hit its
/// four-week expiry and the user needs to sign in; a timeout means the phone
/// is on bad wifi and the cached list should stay exactly where it is.
@MainActor
@Observable
public final class Resource<T: Sendable> {
    public private(set) var data: T?
    public private(set) var error: (any Error)?
    public private(set) var isLoading: Bool
    public private(set) var isStale = false
    public private(set) var unauthorized = false
    public private(set) var lastUpdated: Date?

    private let load: () async throws -> T
    private var hasData = false

    public init(load: @escaping () async throws -> T) {
        self.load = load
        self.isLoading = true
    }

    public func refresh() async {
        if hasData { isStale = true } else { isLoading = true }
        do {
            data = try await load()
            hasData = true
            error = nil
            unauthorized = false
            lastUpdated = .now
        } catch let apiError as APIError where apiError.isUnauthorized {
            unauthorized = true
            error = nil
        } catch {
            self.error = error
        }
        isLoading = false
        isStale = false
    }
}
