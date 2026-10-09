import Foundation

/// Where the Open WebUI instance lives, and how to authenticate to it.
///
/// There is no built-in default on purpose. The app is shareable: whoever
/// installs it types their own URL, and the binary ships with no assumption
/// about where anyone's assistant lives.
///
/// Auth is the bearer path. `POST /api/v1/auths/signin` hands back a JWT that
/// goes in `Authorization: Bearer`, and a per-user API key (Settings → API
/// Keys in the web UI) is accepted in exactly the same header — which is why
/// `token` does not care which of the two it holds.
public struct Server: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String = "") {
        self.baseURL = baseURL
        self.token = token
    }

    /// A URL counts as set only if it has a host.
    ///
    /// `https://` is a perfectly valid URL and an absurd server. Treating the
    /// empty shell as one produced a connect screen reporting "Not reachable"
    /// before anyone had typed a character — a status about the user's
    /// blank field, presented as a fact about their network.
    public var hasURL: Bool { !(baseURL.host()?.isEmpty ?? true) }

    public var isConfigured: Bool { hasURL && !token.isEmpty }

    /// The same server with a different token, so a candidate token can be
    /// tested before it is written to the keychain.
    public func withToken(_ token: String) -> Server {
        var copy = self
        copy.token = token
        return copy
    }

    /// Every path in the client is written relative to the API root.
    ///
    /// Open WebUI moved its routers from `/api/...` to `/api/v1/...` in
    /// 0.11 and kept a few legacy aliases at the old prefix. Building the
    /// prefix here instead of in each call site means one place to change when
    /// (not if) it moves again.
    public func api(_ path: String, query: [String: String] = [:]) throws -> URL {
        try url(path: "/api/v1" + path, query: query)
    }

    /// Paths that are not under the versioned router — `/health`,
    /// `/api/version`, `/api/models`.
    public func raw(_ path: String, query: [String: String] = [:]) throws -> URL {
        try url(path: path, query: query)
    }

    private func url(path: String, query: [String: String]) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        // A base URL typed with a trailing slash would otherwise produce
        // "//api/v1/..." and FastAPI answers that with a 307 to a path that
        // does not exist in the router.
        components?.path = (baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path) + path
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw APIError.invalidURL(baseURL.absoluteString + path) }
        return url
    }

    /// Normalises what someone types into Settings into something URLComponents
    /// can use: bare hostnames get a scheme, everything else is validated.
    public static func parse(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme,
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
