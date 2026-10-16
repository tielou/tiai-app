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
    /// Set while a delete is in flight, so the list says so rather than sitting
    /// on a row that is already gone server-side.
    @State private var deleting: String?
    @State private var deleteFailed: String?

    /// When set, tapping a chat calls this instead of pushing a conversation.
    /// The app opens on a chat rather than on a list, so the list is presented
    /// over the top and picking one has to hand the choice back and close.
    /// Nil keeps the old pushed-onto-a-stack behaviour for any other host.
    var onPick: ((String?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// The row's content, shared by the pushed and the picking presentations.
    @ViewBuilder private func rowLabel(_ chat: ChatSummary) -> some View {
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
        // A Button in a List row only reacts to its text otherwise; the whole row
        // has to be the hit target, as it is for a NavigationLink.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Swiping to delete is the confirmation. A dialog on top of it asked the same
    /// question twice, and the row animating out behind the prompt made the whole
    /// thing look broken.
    private func delete(_ chat: ChatSummary) {
        guard deleting == nil else { return }
        deleting = chat.id
        Task {
            do {
                try await session.client.deleteChat(id: chat.id)
                // Refetch rather than splice: the list is the server's, and a
                // locally removed row that the server still has reappears on the
                // next refresh looking like a bug.
                await chats.refresh()
            } catch {
                deleteFailed = error.localizedDescription
            }
            deleting = nil
        }
    }

    public init(session: SessionStore, onPick: ((String?) -> Void)? = nil) {
        self.session = session
        self.onPick = onPick
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
                            Group {
                                if let onPick {
                                    Button { onPick(chat.id) } label: { rowLabel(chat) }
                                        .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: chat.id) { rowLabel(chat) }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                // Not `role: .destructive`: that makes SwiftUI
                                // slide the row out the instant it is tapped,
                                // before the server has agreed to anything, so a
                                // failed delete left a row that had already
                                // vanished. The row now leaves when the list comes
                                // back without it.
                                Button {
                                    delete(chat)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .chatListStyle()
                    // iOS 26 floats the search field over the bottom of the list
                    // and does not inset the content for it, so the last chat sat
                    // permanently under the field. Reserve the space by hand.
                    .contentMargins(.bottom, 64, for: .scrollContent)
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
            // Asked for the bar placement. iOS 26 still floats the field over
            // the bottom of a list shown in a sheet regardless, so the list also
            // reserves the space itself below; this is the intent, that is the
            // workaround.
            .searchable(text: $query, placement: .toolbar)
            // The search field existed but nothing ever filled `searchResults`, so
            // typing anything produced an empty list — a control that only ever
            // answered "nothing found". Debounced, because one request per
            // keystroke against a home server is rude and the results are the same.
            .task(id: query) {
                guard !query.isEmpty else {
                    searchResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let text = query
                if let found = try? await session.client.searchChats(text), !Task.isCancelled {
                    searchResults = found
                }
            }
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
                // Presented over a chat, the list needs a way back that is not a
                // swipe gesture nobody thinks to try.
                if onPick != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let onPick {
                        Button {
                            // nil means "start another one"; the home view treats
                            // it as a fresh chat.
                            onPick(nil)
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                    } else {
                        NavigationLink {
                            ConversationView(session: session, chatID: nil, models: models)
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
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
/// The app's home is a chat, not a list of them.
///
/// The list was the front door, which made the app feel like a file manager you
/// had to open before you could say anything. Now the app opens on an empty chat
/// with a greeting, and the list is one tap away — which is how the Claude client
/// works, and the reason the user asked for it in those terms.
///
/// `chatID` is nil for "a chat that has not been created yet". `ConversationView`
/// is re-created on change via `.id`, because its whole model is built at init and
/// reloading in place would mean threading a reset through every piece of state it
/// holds — the composer draft, parked tool calls, scroll position. Recreating it
/// is blunter and much harder to get subtly wrong.
public struct ChatHomeView: View {
    @Bindable private var session: SessionStore
    @State private var models: [ChatModel] = []
    @State private var chatID: String?
    /// Bumped every time a fresh chat is asked for. A new chat has no id, so
    /// `chatID` alone cannot tell "a chat that has not been created yet" apart
    /// from *that same* unsaved chat — and asking for another one while sitting in
    /// one left the identity unchanged, so nothing was rebuilt and the screen just
    /// kept showing the conversation you were already looking at.
    @State private var draft = 0
    @State private var showingChats = false

    private var host: String { session.client.server.baseURL.host ?? "local" }

    public init(session: SessionStore) {
        self.session = session
    }

    /// A fresh chat. `chatID` is already nil on one that has not been saved yet,
    /// so the draft counter is what actually makes the view rebuild.
    private func startNewChat() {
        chatID = nil
        draft += 1
    }

    public var body: some View {
        NavigationStack {
            ConversationView(
                session: session, chatID: chatID, models: models,
                onNewChat: { startNewChat() })
                .id("\(chatID ?? "new")-\(draft)")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { showingChats = true } label: {
                            Label("Chats", systemImage: "line.3.horizontal")
                        }
                    }
                }
                .sheet(isPresented: $showingChats) {
                    // No NavigationStack here: ChatListView brings its own, and
                    // nesting one inside another put its search field at the
                    // bottom of the screen instead of under the title.
                    ChatListView(session: session) { picked in
                        chatID = picked
                        if picked == nil { startNewChat() }
                        showingChats = false
                    }
                }
        }
        .task {
            // Cached first so the model chip is right on the first frame; the
            // network copy follows and corrects it.
            if let cached = DiskCache.load([ChatModel].self, key: DiskCache.key("models", host: host)) {
                models = cached
            }
            if let fresh = try? await session.client.models(), !fresh.isEmpty {
                models = fresh
                DiskCache.save(fresh, key: DiskCache.key("models", host: host))
            }
        }
    }
}

public struct RootView: View {
    @Bindable private var session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    public var body: some View {
        Group {
            if session.isSignedIn {
                ChatHomeView(session: session)
            } else {
                ConnectView(session: session)
            }
        }
        .task { await session.probe() }
    }
}
