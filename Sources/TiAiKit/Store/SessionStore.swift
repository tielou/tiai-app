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

    /// The app's one socket.
    ///
    /// One connection for every screen because the server emits to the room
    /// `user:<id>` — all chats arrive on a single connection and each screen
    /// filters. It is rebuilt when the server changes (sign-in, URL edit) so a
    /// stale socket cannot outlive the token it authenticated with.
    public func eventHub() -> ChatEventHub {
        if let hub, hubServer == server { return hub }
        let hub = ChatEventHub(server: server)
        self.hub = hub
        hubServer = server
        return hub
    }

    @ObservationIgnored private var hub: ChatEventHub?
    @ObservationIgnored private var hubServer: Server?

    /// The session's feature/tool intent, shared by every chat (issue #35).
    ///
    /// Mirrors `eventHub()`'s caching shape but keys on `server.baseURL`
    /// only, not the whole `Server`: a token refresh must not throw away
    /// what the user switched on, while a server switch must — one
    /// instance's tools and features are not another's.
    public func runPreferences() -> RunPreferences {
        if let prefs, prefsServer == server.baseURL { return prefs }
        let prefs = RunPreferences()
        self.prefs = prefs
        prefsServer = server.baseURL
        return prefs
    }

    @ObservationIgnored private var prefs: RunPreferences?
    @ObservationIgnored private var prefsServer: URL?

    /// The per-chat send-while-generating queues (issue #37), one store per
    /// instance.
    ///
    /// Same shape and same reasoning as `runPreferences()`: the queue has to
    /// outlive the model that showed it, because leaving a chat and coming back
    /// builds a fresh model and a queue that dies with the screen eats messages.
    /// Keyed on the base URL rather than the whole `Server` — a token refresh
    /// keeps what is waiting, a server switch must not carry one instance's
    /// half-sent messages into another.
    public func messageQueues() -> MessageQueueStore {
        if let queues, queuesServer == server.baseURL { return queues }
        let queues = MessageQueueStore()
        self.queues = queues
        queuesServer = server.baseURL
        return queues
    }

    @ObservationIgnored private var queues: MessageQueueStore?
    @ObservationIgnored private var queuesServer: URL?

    /// The per-chat offline outbox (issue #38), one store per instance.
    ///
    /// Same shape and same reasoning as `messageQueues()`, with one difference
    /// that matters: this one is durable. A queued message that dies with the
    /// app is an inconvenience; an offline send that dies with the app is a
    /// lost message, which is the whole thing the outbox exists to prevent.
    /// Keyed on the base URL for the same reason — messages typed against one
    /// instance do not belong to another — and stored in the session's own
    /// defaults rather than the shared ones, so a test on a private suite is
    /// hermetic and a second signed-in profile cannot read the first's drafts.
    public func outbox() -> OutboxStore {
        if let stored = outboxStore, outboxServer == server.baseURL { return stored }
        let box = OutboxStore(defaults: defaults, host: server.baseURL.host ?? "local")
        self.outboxStore = box
        outboxServer = server.baseURL
        return box
    }

    @ObservationIgnored private var outboxStore: OutboxStore?
    @ObservationIgnored private var outboxServer: URL?

    /// Whether the phone can reach anything, shared by every screen.
    ///
    /// One monitor for the app rather than one per chat: it is a system-wide
    /// question, and a monitor is a live resource. The outbox uses the
    /// satisfied transition as the cue to try again — the case nothing else
    /// catches is the network returning while the app sits open on the chat.
    /// The cue is acted on by whichever chat is on screen (see
    /// `ConversationView`); a pending message in a chat nobody has opened waits
    /// for the moment it is opened, which is when anybody could see it go out.
    public var reachability: Reachability {
        if let monitor = reachabilityMonitor { return monitor }
        let monitor = Reachability()
        self.reachabilityMonitor = monitor
        return monitor
    }

    @ObservationIgnored private var reachabilityMonitor: Reachability?

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
            // The token expired; the person using the app did not choose to
            // leave. Anything they typed and could not send stays.
            signOut(preserveOutbox: true)
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

    /// Ends the session.
    ///
    /// Two callers end it for two different reasons, and the outbox has to
    /// tell them apart (issue #38). An explicit sign-out means leaving the
    /// instance, and messages addressed to a server you have left are nobody's
    /// — clearing them is honest. A 401 is not that: the token expired, the
    /// app signed itself out to say so, and the message someone typed thirty
    /// seconds ago is still a message they meant to send. Vaporising it on a
    /// token expiry is a worse bug than keeping it for a server they never
    /// return to, so the automatic path preserves the outbox.
    public func signOut(preserveOutbox: Bool = false) {
        credentials.clearAll()
        server = Server(baseURL: server.baseURL)
        user = nil
        // Messages waiting to be sent belong to a chat on the instance being
        // left. Signed out, they are nobody's; keeping them means the next
        // sign-in opens to a strip of text addressed to a server it is not on.
        queues = nil
        if preserveOutbox { return }
        outboxStore?.removeAll()
        outboxStore = nil
    }
}
