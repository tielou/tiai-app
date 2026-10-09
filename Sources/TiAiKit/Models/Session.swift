import Foundation

/// The signed-in user, as returned by `/api/v1/auths/signin` and `/api/v1/auths/`.
///
/// Field names are Open WebUI's snake_case; the client maps them with explicit
/// `CodingKey`s rather than a global `.convertToSnakeCase` strategy, because
/// the same response also contains camelCase payloads (chat history) and one
/// strategy would silently mis-decode the other. That mixture is not an
/// oversight on their side — the router models are snake_case, the chat blob
/// is a JavaScript-shaped document written by the Svelte client.
public struct SessionUser: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var email: String
    public var role: String
    public var token: String?
    public var profileImageURL: String?
    public var permissions: JSONValue?

    public init(
        id: String, name: String, email: String, role: String,
        token: String? = nil, profileImageURL: String? = nil, permissions: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.token = token
        self.profileImageURL = profileImageURL
        self.permissions = permissions
    }

    public var isAdmin: Bool { role == "admin" }

    enum Keys: String, CodingKey {
        case id, name, email, role, token, permissions
        case profileImageURL = "profile_image_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        email = try c.decode(String.self, forKey: .email)
        role = (try? c.decode(String.self, forKey: .role)) ?? "user"
        token = try? c.decode(String.self, forKey: .token)
        profileImageURL = try? c.decode(String.self, forKey: .profileImageURL)
        permissions = try? c.decode(JSONValue.self, forKey: .permissions)
    }
}

/// `GET /api/version` — the version handshake.
///
/// Read at sign-in and shown in Settings. The app never refuses to run on an
/// unknown version (this is a homelab, the server moves), but it does say so:
/// "server is 0.12.1, this app is tested against 0.11.x" turns a mysterious
/// breakage into a known one.
public struct ServerVersion: Codable, Equatable, Sendable {
    public var version: String
    public var deploymentID: String?

    enum Keys: String, CodingKey {
        case version
        case deploymentID = "deployment_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = (try? c.decode(String.self, forKey: .version)) ?? "unknown"
        deploymentID = try? c.decode(String.self, forKey: .deploymentID)
    }
}

/// `GET /api/config`, narrowed to the handful of flags that change what the
/// app offers. Everything else is ignored on purpose: the response is large,
/// mostly presentation, and re-decoding it on a phone buys nothing.
public struct ServerConfig: Codable, Equatable, Sendable {
    public var version: String?
    public var name: String?
    public var enableWebsocket: Bool
    public var enableSignup: Bool
    public var features: JSONValue?

    enum Keys: String, CodingKey {
        case version, name, features
    }

    enum FeatureKeys: String, CodingKey {
        case enableWebsocket = "enable_websocket"
        case enableSignup = "enable_signup"
        case slim
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try? c.decode(String.self, forKey: .version)
        name = try? c.decode(String.self, forKey: .name)
        features = try? c.decode(JSONValue.self, forKey: .features)

        // `enable_websocket` and `enable_signup` live inside the `features`
        // object, not at the top level — reading them from the root silently
        // reports false and would make the app think there is no side channel.
        if let features = try? c.nestedContainer(keyedBy: FeatureKeys.self, forKey: .features) {
            enableWebsocket = (try? features.decode(Bool.self, forKey: .enableWebsocket)) ?? false
            enableSignup = (try? features.decode(Bool.self, forKey: .enableSignup)) ?? false
        } else {
            enableWebsocket = false
            enableSignup = false
        }
    }
}
