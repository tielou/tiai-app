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

    /// Capability names Open WebUI sets today. Unknown names are kept in
    /// `capabilities` regardless — a new capability on the server should light
    /// up a toggle, not fail to decode.
    public var supportsVision: Bool { capabilities["vision"] ?? false }
    public var supportsThinking: Bool { capabilities["thinking"] ?? false }
    public var supportsTools: Bool { capabilities["tools"] ?? false }
    public var supportsCitation: Bool { capabilities["citation"] ?? false }
    public var supportsSearch: Bool { capabilities["search"] ?? false }
    public var supportsUsage: Bool { capabilities["usage"] ?? false }

    /// Whether the composer should offer a given feature toggle for this model.
    public func supports(feature: ChatFeature) -> Bool {
        switch feature {
        case .webSearch: true  // gated by server config, not by model capability
        case .memory: true
        case .thinking: supportsThinking
        case .codeInterpreter: capabilities["code_interpreter"] ?? true
        case .imageGeneration: capabilities["image_generation"] ?? true
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
public enum ChatFeature: String, CaseIterable, Codable, Sendable {
    case webSearch = "web_search"
    case memory
    case thinking
    case codeInterpreter = "code_interpreter"
    case imageGeneration = "image_generation"

    public var title: String {
        switch self {
        case .webSearch: "Web search"
        case .memory: "Memory"
        case .thinking: "Thinking"
        case .codeInterpreter: "Code interpreter"
        case .imageGeneration: "Image generation"
        }
    }
}
