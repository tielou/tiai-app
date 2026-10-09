import Foundation

/// Who we are signed in to, where that lives, and for how long.
///
/// The JWT Open WebUI hands out expires after `JWT_EXPIRES_IN` (four weeks by
/// default) and there is no refresh endpoint, so "signed in" is always a
/// countdown rather than a state. Two consequences the design follows:
///
/// * The password may be kept in the keychain (opt-in) so the app can sign in
///   again silently when the token dies, instead of interrupting someone
///   mid-message four weeks after setup.
/// * A 401 is the only thing that ends the session. An unreachable server is
///   not — otherwise a phone on hotel wifi throws away a working transcript
///   and asks for a password it already has.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var server: Server
    public private(set) var user: SessionUser?
    public private(set) var serverVersion: String?
    public private(set) var checking = false
    public private(set) var lastError: String?

    /// Remember the password so an expired token can be exchanged silently.
    /// Off by default: the default posture is that a phone holds a token, not
    /// a credential.
    public var remembersPassword: Bool {
        didSet { defaults.set(remembersPassword, forKey: "rememberPassword") }
    }

    private let credentials: any CredentialStore
    private let defaults: UserDefaults
    private let urlKey = "serverURL"

    public init(
        credentials: any CredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.defaults = defaults
        let stored = defaults.string(forKey: urlKey).flatMap(Server.parse) ?? URL(string: "https://")!
        self.server = Server(baseURL: stored, token: credentials.readToken() ?? "")
        self.remembersPassword = defaults.bool(forKey: "rememberPassword")
    }

    public var isSignedIn: Bool { server.isConfigured }
    public var hasServerURL: Bool { server.hasURL }

    public var client: OWUIClient { OWUIClient(server: server) }

    // MARK: - connecting

    public func setURL(_ text: String) {
        guard let url = Server.parse(text) else { return }
        server = Server(baseURL: url, token: server.token)
        defaults.set(url.absoluteString, forKey: urlKey)
    }

    /// Signs in and only then commits the token, so a wrong password cannot
    /// leave a broken session behind.
    public func signIn(email: String, password: String) async {
        let url = server.baseURL
        checking = true
        defer { checking = false }
        do {
            let candidate = OWUIClient(server: Server(baseURL: url))
            let signedIn = try await candidate.signin(email: email, password: password)
            guard let token = signedIn.token, !token.isEmpty else {
                lastError = "The server did not return a token."
                return
            }
            server = Server(baseURL: url, token: token)
            credentials.writeToken(token)
            if remembersPassword { credentials.writePassword(password) }
            user = signedIn
            lastError = nil
            await probe()
        } catch let error as APIError {
            lastError = error.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Validates the stored token and picks up the user record. Called at
    /// launch; a failure that is not a 401 leaves the session alone.
    public func probe() async {
        guard server.isConfigured else { return }
        do {
            user = try await client.session()
            serverVersion = try? await client.version().version
            lastError = nil
        } catch let error as APIError where error.isUnauthorized {
            signOut()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Silent re-login using the remembered password, for the four-week
    /// expiry. Returns whether it worked so the caller can retry the request
    /// that failed.
    public func renewIfNeeded() async -> Bool {
        guard let password = credentials.readPassword(), let email = user?.email else { return false }
        await signIn(email: email, password: password)
        return isSignedIn
    }

    public func signOut() {
        credentials.clearAll()
        server = Server(baseURL: server.baseURL)
        user = nil
    }
}
