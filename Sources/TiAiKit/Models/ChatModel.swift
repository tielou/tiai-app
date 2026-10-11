import Foundation

/// A model in the picker, as returned by `GET /api/v1/models`.
///
/// The response is `{"data": [...]}` of OpenAI-shaped objects with an extra
/// `info` object holding the curated Open WebUI record. Two shapes in one
/// payload is why this is hand-decoded: `id`/`name`/`owned_by` sit at the top
/// level while the things the app actually needs — capabilities, the base
/// model, whether thinking is available — live under `info.meta`.
public struct ChatModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var ownedBy: String
    public var preset: Bool
    public var capabilities: [String: Bool]
    public var baseModelID: String?
    public var description: String?
    public var tags: [String]
    /// The model's own default feature ids (`meta.defaultFeatureIds`) — this
    /// is where "web search is on for this model by default" is stored, and it
    /// lives in the database rather than in any config file. The composer must
    /// seed its toggles from it, or the phone and the browser disagree about
    /// whether a message is about to hit a search engine.
    public var defaultFeatureIDs: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        ownedBy = (try? c.decode(String.self, forKey: .ownedBy)) ?? ""
        preset = (try? c.decode(Bool.self, forKey: .preset)) ?? false

        if let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            baseModelID = try? info.decode(String.self, forKey: .baseModelID)
            if let meta = try? info.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta) {
                capabilities = (try? meta.decode([String: Bool].self, forKey: .capabilities)) ?? [:]
                description = try? meta.decode(String.self, forKey: .description)
                defaultFeatureIDs = (try? meta.decode([String].self, forKey: .defaultFeatureIDs)) ?? []
                tags = (try? meta.decode([String].self, forKey: .tags)) ?? []
            } else {
                capabilities = [:]
                description = nil
                defaultFeatureIDs = []
                tags = []
            }
        } else {
            baseModelID = nil
            capabilities = [:]
            description = nil
            defaultFeatureIDs = []
            tags = []
        }
        if tags.isEmpty, let top = try? c.decode([String].self, forKey: .tags) {
            tags = top
        }
    }

    /// Capability names as the server spells them, observed on 0.11.4:
    /// `builtin_tools`, `citations`, `code_interpreter`, `file_context`,
    /// `file_upload`, `image_generation`, `memory`, `status_updates`,
    /// `terminal`, `vision`, `web_search`. Note they are not the names the
    /// feature toggles use, and there is no `thinking` at all — thinking is a
    /// per-model route (local-personal vs local-fast), not a capability.
    public func supports(_ capability: String) -> Bool { capabilities[capability] ?? false }

    public var supportsVision: Bool { supports("vision") }
    public var supportsTools: Bool { supports("builtin_tools") }
    public var supportsCitation: Bool { supports("citations") }
    public var supportsWebSearch: Bool { supports("web_search") }
    public var supportsMemory: Bool { supports("memory") }
    public var supportsCodeInterpreter: Bool { supports("code_interpreter") }
    public var supportsImageGeneration: Bool { supports("image_generation") }
    public var supportsFileUpload: Bool { supports("file_upload") }
    /// Whether the server will emit status events for this model at all.
    public var supportsStatusUpdates: Bool { supports("status_updates") }

    /// Whether the composer should offer a feature toggle for this model.
    ///
    /// An empty capability map means "no metadata", not "no features" — the
    /// fast and quick routes advertise nothing, and hiding web search there
    /// would be a feature removal invented by a missing dict. When the server
    /// does describe itself, its answer wins.
    public func supports(_ feature: ChatFeature) -> Bool {
        if capabilities.isEmpty { return true }
        return switch feature {
        case .webSearch: supportsWebSearch
        case .memory: supportsMemory
        case .codeInterpreter: supportsCodeInterpreter
        case .imageGeneration: supportsImageGeneration
        }
    }

    enum Keys: String, CodingKey {
        case id, name, info, tags
        case ownedBy = "owned_by"
        case preset
    }

    enum InfoKeys: String, CodingKey {
        case meta
        case baseModelID = "base_model_id"
    }

    enum MetaKeys: String, CodingKey {
        case capabilities, description, tags
        case defaultFeatureIDs = "defaultFeatureIds"
    }
}

/// The per-message feature toggles, and the wire names Open WebUI expects in
/// `features` (a dict of booleans, not the list of strings older versions took).
///
/// Deliberately short. A toggle here is a promise that the server changes
/// something when it flips, and only these four do. Thinking is *not* one of
/// them: reasoning arrives from the model on its own (the transcript's
/// "Thoughts" block is proof), the server has no `features.thinking` handler,
/// and the real knob is `reasoning_effort`, a per-model parameter sitting next
/// to temperature — not a per-message switch. Offering it as one was a control
/// that did nothing.
public enum ChatFeature: String, CaseIterable, Codable, Sendable {
    case webSearch = "web_search"
    case memory
    case codeInterpreter = "code_interpreter"
    case imageGeneration = "image_generation"

    /// The chip-sized label, for the composer where "Web search" is too wide.
    public var shortTitle: String {
        switch self {
        case .webSearch: "search"
        case .memory: "memory"
        case .codeInterpreter: "code"
        case .imageGeneration: "images"
        }
    }

    public var title: String {
        switch self {
        case .webSearch: "Web search"
        case .memory: "Memory"
        case .codeInterpreter: "Code interpreter"
        case .imageGeneration: "Image generation"
        }
    }

    /// The composer chip shows these as glyphs, because four words after the
    /// model name is a sentence where a glance should do. `title` stays the
    /// thing VoiceOver reads, so the icons cost nothing in meaning.
    public var symbol: String {
        switch self {
        case .webSearch: "magnifyingglass"
        case .memory: "brain"
        case .codeInterpreter: "curlybraces"
        case .imageGeneration: "photo"
        }
    }
}
