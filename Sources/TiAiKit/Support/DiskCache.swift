import Foundation

/// A small JSON cache in the Caches directory.
///
/// The app had no cache of any kind: every cold launch needed the network before
/// it could name a model, list a chat, or offer a tool, so on a slow connection
/// the app looked broken when it was merely waiting. This is not an offline mode
/// — a chat client without its server is a paperweight — it is the difference
/// between "shows the last known state and updates it" and "shows a spinner".
///
/// Keys are scoped to the server host on purpose. The app can be pointed at any
/// Open WebUI, and showing the models from your test instance while you are
/// looking at the real one is worse than no cache at all.
///
/// Everything is best-effort and silent: a cache that fails is a cache, not an
/// error the user can act on.
public enum DiskCache {
    /// Days after which a cached value is ignored rather than shown. Long enough
    /// to survive a weekend in the subway, short enough that a stale model list
    /// does not outlive its usefulness.
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private struct Envelope: Codable {
        var saved: Date
        var payload: Data
    }

    private static func file(for key: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("tiai-cache").appendingPathComponent(safe + ".json")
    }

    public static func save<T: Encodable>(_ value: T, key: String) {
        guard let url = file(for: key),
              let payload = try? JSONEncoder().encode(value) else { return }
        let envelope = Envelope(saved: .now, payload: payload)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let url = file(for: key),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              Date.now.timeIntervalSince(envelope.saved) < maxAge,
              let value = try? JSONDecoder().decode(type, from: envelope.payload)
        else { return nil }
        return value
    }

    /// Namespaced key: the same path on a different server is different data.
    public static func key(_ name: String, host: String) -> String { "\(name)@\(host)" }
}
