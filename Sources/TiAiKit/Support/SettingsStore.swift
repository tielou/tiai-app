import Foundation

/// Per-server defaults the user sets once instead of per chat.
///
/// Scoped by host on purpose: a system prompt written for a home server with
/// terminal access is wrong for a work one, and pointing the app at a second
/// instance should not silently inherit the first one's instructions.
///
/// These live on the phone, not on the server. Open WebUI stores its own defaults
/// in user settings, but those are the web UI's to write and reading them back
/// means guessing at a schema; the app keeps its own so it can never overwrite
/// something the web UI owns.
public struct AppDefaults: Codable, Equatable, Sendable {
    /// Prepended to every new conversation as the system message.
    public var systemPrompt: String
    /// nil means "whatever the server picked", which is the right default: a
    /// number chosen for one model is wrong for the next one.
    public var temperature: Double?
    /// Ask to be told when an answer lands while the app is not the thing on
    /// screen. Off by default: a chat app that notifies unprompted is a
    /// notification app with a chat attached.
    public var notifyWhenFinished: Bool

    public init(
        systemPrompt: String = "", temperature: Double? = nil, notifyWhenFinished: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.notifyWhenFinished = notifyWhenFinished
    }

    public var isEmpty: Bool {
        systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && temperature == nil && !notifyWhenFinished
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var defaults: AppDefaults {
        didSet { persist() }
    }

    private var host: String

    private init() {
        host = "local"
        defaults = AppDefaults()
    }

    /// Called whenever the app points at a different server; the defaults shown
    /// are that server's, not the last one's.
    public func point(at url: URL?) {
        let next = url?.host ?? "local"
        guard next != host else { return }
        host = next
        defaults = Self.load(host: next)
    }

    private func persist() {
        let key = "tiai.defaults.\(host)"
        if defaults.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(defaults) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(host: String) -> AppDefaults {
        guard let data = UserDefaults.standard.data(forKey: "tiai.defaults.\(host)"),
              let stored = try? JSONDecoder().decode(AppDefaults.self, from: data)
        else { return AppDefaults() }
        return stored
    }
}
