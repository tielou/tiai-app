import SwiftUI

/// The first screen, and the one that makes the app shareable: nothing about
/// anyone's server is baked into the binary.
public struct ConnectView: View {
    @Bindable private var session: SessionStore
    @State private var urlText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var reachable: Bool?

    public init(session: SessionStore) {
        self.session = session
        _urlText = State(initialValue: session.hasServerURL ? session.server.baseURL.absoluteString : "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $urlText)
                        .textContentType(.URL)
                        .urlInput()
                        .autocorrectionDisabled()
                        .onChange(of: urlText) { _, new in
                            session.setURL(new)
                            reachable = nil
                        }

                    // Always present rather than added once a URL exists: a row
                    // that appears mid-typing makes the form jump, and an `if`
                    // around a Form row is also how you get a phantom empty row
                    // left behind when the condition flips.
                    LabeledContent("Status") {
                        switch reachable {
                        case .some(true): Label("Reachable", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .some(false): Label("Not reachable", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        case nil: Text("—").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your Open WebUI instance, e.g. https://chat.example.co. If it is only reachable on your home network, you need to be on that network — or on your VPN.")
                }

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .emailInput()
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    // In the body, not the footer: a control in a footer renders
                    // outside the grouped box, which reads as a stray switch
                    // floating under the form.
                    Toggle("Stay signed in", isOn: $session.remembersPassword)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("Open WebUI tokens expire after a few weeks and cannot be refreshed. Turning this on keeps your password in this phone's keychain so the app can sign itself back in instead of interrupting you.")
                }

                if let error = session.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("tiAi")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        Task { await session.signIn(email: email, password: password) }
                    }
                    .disabled(urlText.isEmpty || email.isEmpty || password.isEmpty || session.checking)
                }
            }
            .overlay {
                if session.checking { ProgressView("Signing in…") }
            }
            .task { await check() }
        }
    }

    /// Checks reachability before anyone types a password, so "wrong URL" and
    /// "server down" are two different messages instead of one failed login.
    private func check() async {
        guard session.hasServerURL else { return }
        do {
            _ = try await session.client.health()
            reachable = true
            if let version = try? await session.client.version() { serverVersionLabel = version.version }
        } catch {
            reachable = false
        }
    }

    @State private var serverVersionLabel: String?
}

/// The conversation list.
///
/// Renders from cache first and revalidates, because this is the screen people
/// hammer and "instant then correct" is most of what makes an app feel native
/// rather than like a website.
public struct ChatListView: View {
    @Bindable private var session: SessionStore
    @State private var chats: Resource<[ChatSummary]>
    @State private var models: [ChatModel] = []

    /// Cache keys are per server: the app can point at any Open WebUI, and
    /// showing one instance's models while you look at another is worse than
    /// no cache at all.
    private var host: String { session.client.server.baseURL.host ?? "local" }
    @State private var query = ""
    @State private var searchResults: [ChatSummary] = []
    @State private var showingMemory = false
    /// A chat the user has swiped to delete and is being asked to confirm.
    @State private var pendingDelete: ChatSummary?
    @State private var deleting: String?
    @State private var deleteFailed: String?

    public init(session: SessionStore) {
        self.session = session
        _chats = State(initialValue: Resource(load: { try await session.client.chatList() }))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if chats.isLoading && chats.data == nil {
                    ContentUnavailableView("Loading…", systemImage: "ellipsis")
                } else if let error = chats.error, chats.data == nil {
                    ContentUnavailableView {
                        Label("Could not load your chats", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button("Retry") { Task { await chats.refresh() } }
                    }
                } else {
                    List {
                        ForEach(visible) { chat in
                            NavigationLink(value: chat.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(chat.title).lineLimit(1)
                                        if chat.pinned {
                                            Image(systemName: "pin.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(chat.updatedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = chat
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .chatListStyle()
                    .confirmationDialog(
                        "Delete this chat?",
                        isPresented: Binding(
                            get: { pendingDelete != nil },
                            set: { if !$0 { pendingDelete = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            if let chat = pendingDelete {
                                pendingDelete = nil
                                deleting = chat.id
                                Task {
                                    do {
                                        try await session.client.deleteChat(id: chat.id)
                                        // Refetch rather than splice: the list is
                                        // the server's, and a locally removed row
                                        // that the server still has reappears on
                                        // the next refresh looking like a bug.
                                        await chats.refresh()
                                    } catch {
                                        deleteFailed = error.localizedDescription
                                    }
                                    deleting = nil
                                }
                            }
                        }
                        Button("Keep", role: .cancel) { pendingDelete = nil }
                    } message: {
                        Text(pendingDelete.map { "\"\($0.title)\" goes with it." } ?? "")
                    }
                    .overlay {
                        if deleting != nil {
                            ProgressView().controlSize(.large)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .alert("Could not delete the chat", isPresented: Binding(
                        get: { deleteFailed != nil },
                        set: { if !$0 { deleteFailed = nil } })
                    ) {
                        Button("OK", role: .cancel) { deleteFailed = nil }
                    } message: {
                        Text(deleteFailed ?? "")
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { id in
                ConversationView(session: session, chatID: id, models: models)
            }
            .searchable(text: $query)
            .refreshable { await chats.refresh() }
            .task {
                // Cached first, network second: the list and the model name come
                // up at once and correct themselves a moment later, instead of
                // the app looking broken while a slow server thinks.
                if models.isEmpty,
                   let cached = DiskCache.load([ChatModel].self,
                                               key: DiskCache.key("models", host: host)) {
                    models = cached
                }
                await chats.refresh()
                if let fresh = try? await session.client.models(), !fresh.isEmpty {
                    models = fresh
                    DiskCache.save(fresh, key: DiskCache.key("models", host: host))
                }
                #if DEBUG
                // Diagnostics only, and only with the dump directory set. Fetching
                // the newest chat means its stored payload lands on disk without
                // anyone having to tap anything — which matters when the thing
                // under investigation is a message the app rendered wrongly and
                // the only copy is on the server.
                if ProcessInfo.processInfo.environment["TIAI_DEBUG_DUMP"] != nil {
                    for chat in chats.data?.prefix(5) ?? [] {
                        _ = try? await session.client.chat(id: chat.id)
                    }
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ConversationView(session: session, chatID: nil, models: models)
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
                // `.navigation` rather than `.topBarLeading`: the kit builds for
                // macOS too, where the latter does not exist.
                ToolbarItem(placement: .navigation) {
                    AppearancePicker()
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NotesView(client: session.client)
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingMemory = true } label: {
                        Label("Memory", systemImage: "brain")
                    }
                }
            }
            .sheet(isPresented: $showingMemory) {
                MemorySheet(client: session.client)
            }
            .overlay {
                if chats.unauthorized {
                    ContentUnavailableView(
                        "Signed out", systemImage: "lock",
                        description: Text("The server no longer recognises this device."))
                }
            }
        }
    }

    private var visible: [ChatSummary] {
        query.isEmpty ? (chats.data ?? []) : searchResults
    }
}

/// The app's root: connect, or the list.
public struct RootView: View {
    @Bindable private var session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    public var body: some View {
        Group {
            if session.isSignedIn {
                ChatListView(session: session)
            } else {
                ConnectView(session: session)
            }
        }
        .task { await session.probe() }
    }
}
