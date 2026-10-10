import Foundation

/// A tool the chat can be given — an MCP server or a workspace tool, both of
/// which arrive from the same place.
///
/// Read from the backend, never listed in the app: what shows here is whatever
/// `GET /api/v1/tools/` returns, so connecting a server in the web UI makes it
/// appear in the chat without an app update. Hardcoding "Sonos" and "Notion"
/// would have been the easy version and would have rotted the first time a
/// server was renamed.
///
/// The identifier sent back to the server is the `id` from that list. For an MCP
/// server it is opaque — `server:mcp:1`, `server:mcp:2` — and **not** the url.
/// An earlier version keyed on url, because the admin registry at
/// `/configs/tool_servers` is keyed that way; that list has no names in it, so
/// it cannot be what the picker is showing. Both guesses are recorded here
/// because both were made.
public struct ChatTool: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A short line under the name, when the instance provides one.
    public var detail: String?
    /// `false` on an OAuth server the user has not signed into yet. `nil` means
    /// the deployment does not say, which is different from "no".
    public var authenticated: Bool?
    /// Greyed rather than hidden: a tool the user expects to see and cannot find
    /// is worse than one they can see and not use.
    public var available: Bool

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        guard let id = object["id"]?.stringValue ?? object["url"]?.stringValue,
            !id.isEmpty
        else { return nil }
        self.id = id
        self.name =
            object["name"]?.stringValue
            ?? object["title"]?.stringValue
            ?? Self.shortName(of: id)
        // Empty string means no description, not a description that is blank.
        let meta = object["meta"]
        let text = meta?["description"]?.stringValue ?? object["description"]?.stringValue
        self.detail = (text?.isEmpty == false) ? text : nil
        self.authenticated = object["authenticated"]?.boolValue
        // Absent means unverified, not broken. Only an explicit false disables.
        self.available = object["error"].map { $0.isNull } ?? true
    }

    /// A url reads better in a row than a url, and some entries have no name.
    private static func shortName(of value: String) -> String {
        if let host = URL(string: value)?.host, !host.isEmpty { return host }
        return value
    }

    /// The url that starts a sign-in for this tool, or nil when it needs none.
    ///
    /// Shape taken from the web client, which builds
    /// `{base}/oauth/clients/{type}:{n}/authorize` and navigates to it when you
    /// switch an unauthenticated server on. The `{type}:{n}` is this tool's id
    /// with its `server:` prefix dropped, so `server:mcp:1` authorises at
    /// `/oauth/clients/mcp:1/authorize` — and note that is at the site root,
    /// not under `/api/v1`.
    public func authorizeURL(base: URL) -> URL? {
        guard authenticated == false, id.hasPrefix("server:") else { return nil }
        let tail = id.dropFirst("server:".count)
        guard !tail.isEmpty else { return nil }
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: "\(root)/oauth/clients/\(tail)/authorize")
    }
}
