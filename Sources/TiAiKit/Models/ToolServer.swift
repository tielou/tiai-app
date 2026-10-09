import Foundation

/// An MCP tool server the operator has configured on the instance.
///
/// Read from the backend, never listed in the app: what shows here is whatever
/// `GET /api/v1/configs/tool_servers` returns, so adding a server in the admin
/// UI makes it appear in the chat without an app update. Hardcoding "Sonos" and
/// "Notion" would have been the easy version and would have rotted the first
/// time a server was renamed.
///
/// The identifier sent back to the server is the **url**, not a name: that is
/// what the web client matches on when it looks a server up, and urls are what
/// the configuration is keyed by. `id` is only a fallback for a deployment that
/// configures servers without one.
public struct ToolServer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String?
    public var description: String?
    /// Whether the instance reports it as reachable. A server that fails the
    /// check is still shown — disabled rather than hidden — because an invisible
    /// tool the user expects to see is worse than a greyed-out one.
    public var reachable: Bool

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        let url = object["url"]?.stringValue
        let id = url ?? object["id"]?.stringValue ?? object["key"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        self.id = id
        self.url = url
        self.name =
            object["name"]?.stringValue
            ?? object["title"]?.stringValue
            ?? Self.shortName(of: id)
        self.description = object["description"]?.stringValue
        // Absent means unverified, not broken. Only an explicit false disables.
        self.reachable = object["error"].map { $0.isNull } ?? true
    }

    /// "sonos-mcp.home.lan" reads better in a row than a URL.
    private static func shortName(of value: String) -> String {
        if let host = URL(string: value)?.host, !host.isEmpty { return host }
        return value
    }
}
