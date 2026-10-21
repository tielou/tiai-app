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
    @Environment(\.scenePhase) private var scenePhase
    /// Set while a delete is in flight, so the list says so rather than sitting
    /// on a row that is already gone server-side.
    @State private var deleting: String?
    @State private var deleteFailed: String?

    /// When set, the Notes row calls this instead of pushing inside this view's
    /// own navigation stack. The drawer is 84% of the screen wide, and Notes is a
    /// document, not a menu — reading it in a strip was the wrong shape.
    var onOpenNotes: (() -> Void)? = nil

    /// When set, a "Chats" row in the list opens the whole thing full screen.
    var onExpand: (() -> Void)? = nil
    /// Opens the account and defaults screen. Nil in the full-screen list, where
    /// the row would be a way to open the thing you are already looking at.
    var onOpenSettings: (() -> Void)? = nil

    /// Whether the Notes and Memory rows belong here.
    ///
    /// Off in the full-screen chat list: you tapped "Chats" to look at chats, and
    /// being handed the menu again in a bigger font is not what you asked for.
    var showsLibrary = true

    /// Bumped by the host to ask for a refresh. A chat started on this phone does
    /// not exist in the list until something asks again, and the drawer is now
    /// permanently mounted so its own `.task` only ever runs once.
    var refreshBadge: Int = 0

    /// Called after the server has agreed to a delete, with the id.
    ///
    /// Deleting the conversation you are standing in used to leave you standing in
    /// it: the row vanished from the list, the transcript stayed on screen, and
    /// sending into it wrote to a chat that no longer existed.
    var onDeleted: ((String) -> Void)? = nil

    /// Declared last so the trailing closure at every call site still lands here.
    ///
    /// When set, tapping a chat calls this instead of pushing a conversation.
    /// The app opens on a chat rather than on a list, so the list is presented
    /// over the top and picking one has to hand the choice back and close.
    /// Nil keeps the old pushed-onto-a-stack behaviour for any other host.
    var onPick: ((String?) -> Void)? = nil

    /// The row's content, shared by the pushed and the picking presentations.
    @ViewBuilder private func rowLabel(_ chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chat.title).lineLimit(1)
                if chat.pinned {
                    // The title already reads as pinned to anyone looking; the
                    // badge is decoration and a screen reader would only repeat it.
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(since(chat.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // A Button in a List row only reacts to its text otherwise; the whole row
        // has to be the hit target, as it is for a NavigationLink.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "4 hrs, 15 min" is a lot of noise under every row. The only thing the
    /// timestamp answers is roughly how old, so it says that and stops.
    private func since(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<60: return "just now"
        case ..<3_600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3_600)h"
        case ..<604_800: return "\(s / 86_400)d"
        default: return "\(s / 604_800)w"
        }
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
                onDeleted?(chat.id)
            } catch {
                deleteFailed = error.localizedDescription
            }
            deleting = nil
        }
    }

    public init(
        session: SessionStore,
        onOpenNotes: (() -> Void)? = nil,
        onExpand: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        refreshBadge: Int = 0,
        showsLibrary: Bool = true,
        onDeleted: ((String) -> Void)? = nil,
        onPick: ((String?) -> Void)? = nil
    ) {
        self.session = session
        self.onOpenNotes = onOpenNotes
        self.onExpand = onExpand
        self.onOpenSettings = onOpenSettings
        self.refreshBadge = refreshBadge
        self.showsLibrary = showsLibrary
        self.onDeleted = onDeleted
        self.onPick = onPick
        #if os(iOS)
        // The system's 34pt large title is sized for a title labelling a whole
        // screen of content. This one labels a drawer, and at full size it
        // outweighed the list under it.
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 27, weight: .bold),
        ]
        #endif
        // Writing through to the disk on every successful refresh means the next
        // launch has a list to show before the network has answered at all.
        let key = DiskCache.key("chats", host: session.client.server.baseURL.host ?? "local")
        _chats = State(initialValue: Resource(load: {
            let list = try await session.client.chatList()
            DiskCache.save(list, key: key)
            return list
        }))
    }

    public var body: some View {
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
                    // Where the things that are not chats live. Tried pills, and
                    // the rows were better: two labels with icons in a list is
                    // what every iOS sidebar does, and the pills drew more
                    // attention to themselves than to what they open.
                    if showsLibrary {
                        Section {
                            // Only offered where it is not self-referential: in the
                            // full-screen list this row would open the screen you are
                            // already on.
                            if let onExpand {
                                Button(action: onExpand) {
                                    Label("Chats", systemImage: "bubble.left.and.bubble.right")
                                }
                            }
                            if let onOpenNotes {
                                Button(action: onOpenNotes) {
                                    Label("Notes", systemImage: "note.text")
                                }
                            } else {
                                NavigationLink {
                                    NotesView(client: session.client)
                                } label: {
                                    Label("Notes", systemImage: "note.text")
                                }
                            }
                            Button { showingMemory = true } label: {
                                Label("Memory", systemImage: "brain.head.profile")
                            }
                            Button(action: { onOpenSettings?() }) {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }
                    }

                    Section("Recents") {
                        ForEach(visible) { chat in
                            Group {
                                if let onPick {
                                    Button { onPick(chat.id) } label: { rowLabel(chat) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("chatRow-\(chat.id)")
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
                }
                .chatListStyle()
                // iOS 26 floats the search field over the bottom of the list
                // and does not inset the content for it, so the last chat sat
                // permanently under the field. Reserve the space by hand — the
                // field plus its shadow is taller than it looks.
                .contentMargins(.bottom, 96, for: .scrollContent)
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
        .navigationTitle(showsLibrary ? "tiAi" : "Chats")
        .navigationDestination(for: String.self) { id in
            ConversationView(session: session, chatID: id, models: models)
        }
        // Left at the system placement on purpose. Asking for `.toolbar` did not
        // move the field on iOS 26 — it floats over the bottom of the list either
        // way — but it did reserve a band of empty space under the title for a bar
        // that was not going to appear there.
        .searchable(text: $query)
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
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is when the list has most likely gone stale —
            // a chat started in the browser, one deleted elsewhere — and it is
            // already open on screen, so the refresh is invisible rather than a
            // spinner in front of an empty drawer.
            guard phase == .active else { return }
            Task { await chats.refresh() }
        }
        .task(id: refreshBadge) {
            // Cached first, network second: the list and the model name come
            // up at once and correct themselves a moment later, instead of
            // the app looking broken while a slow server thinks.
            if let cached = DiskCache.load([ChatSummary].self,
                                           key: DiskCache.key("chats", host: host)) {
                chats.seed(cached)
            }
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
            // Two controls, not five. Notes and memory moved into the list where
            // they have labels; a strip of unlabelled glyphs above a menu is the
            // part that made this look unfinished.
            // `.navigation` rather than `.topBarLeading`: the kit builds for
            // macOS too, where the latter does not exist.
            ToolbarItem(placement: .navigation) {
                AppearancePicker()
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
    /// Something shown over the whole screen rather than inside the drawer: the
    /// full chat list, or Notes. Both are things you read, and a document in a
    /// 330-point strip is the wrong shape.
    enum Fullscreen: String, Identifiable { case chats, notes, settings; var id: String { rawValue } }
    @State private var fullscreen: Fullscreen?
    /// Bumped every time the drawer opens, so the list asks the server again.
    /// A chat started on this phone did not exist the last time it looked.
    @State private var refreshBadge = 0
    /// Live drag offset while closing the drawer by hand. Negative, in points.
    @State private var drag: CGFloat = 0

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

    private func closeChats() {
        drag = 0
        showingChats = false
    }

    /// Opening the drawer is the moment to re-ask: it is what you do when you
    /// expect the list to have changed, and the cached rows are already on screen
    /// so the refresh is invisible rather than a spinner.
    private func openChats() {
        showingChats = true
        refreshBadge += 1
    }

    #if DEBUG
    /// Diagnostics: `TIAI_OPEN_CHAT=<id>` opens one chat on launch, so a specific
    /// message can be screenshotted without driving a flaky list to it.
    private func probeOpenChat() {
        if let id = ProcessInfo.processInfo.environment["TIAI_OPEN_CHAT"] { chatID = id }
    }
    #endif

    /// A chat the server has just removed. If it is the one on screen, leave it —
    /// staying in a deleted conversation means the next message goes somewhere
    /// that no longer exists, and the transcript on screen is a copy of nothing.
    private func chatWasDeleted(_ id: String) {
        guard id == chatID else { return }
        startNewChat()
        fullscreen = nil
        closeChats()
    }

    public var body: some View {
        GeometryReader { proxy in
            let panelWidth = proxy.size.width * 0.84
            // Where the panel is right now: fully out, fully in, or partway
            // through a drag. Driving an offset from state, rather than inserting
            // and removing the view with a transition, is what makes it slide out
            // as well as in — a removal transition was being dropped on the floor
            // and the drawer simply vanished.
            let x = (showingChats ? 0 : -panelWidth) + min(drag, 0)
            ZStack(alignment: .leading) {
                NavigationStack {
                    ConversationView(
                        session: session, chatID: chatID, models: models,
                        onNewChat: { startNewChat() })
                        .id("\(chatID ?? "new")-\(draft)")
                        // Tapping the Live Activity should land in the chat that is
                        // generating, not wherever the app happens to reopen.
                        .onOpenURL { url in
                            guard url.scheme == "tiai", url.host == "chat",
                                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                      .queryItems?
                                      .first(where: { $0.name == "id" })?.value,
                                  !id.isEmpty
                            else { return }
                            chatID = id
                            showingChats = false
                        }
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button { openChats() } label: {
                                    Label("Chats", systemImage: "line.3.horizontal")
                                }
                                .accessibilityIdentifier("drawerToggle")
                            }
                        }
                }

                // The rest of the screen, dimmed, and a tap on it closes.
                Color.black
                    .opacity(showingChats ? 0.45 * max(0, 1 + Double(drag / panelWidth)) : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeChats() }
                    .allowsHitTesting(showingChats)

                // A drawer, not a push. The button that opens it is on the left,
                // so it has to arrive from the left. The conversation stays partly
                // visible behind it, which is what tells you this is an overlay
                // and not another screen.
                NavigationStack {
                    ChatListView(
                        session: session,
                        onOpenNotes: { fullscreen = .notes },
                        onExpand: { fullscreen = .chats },
                        onOpenSettings: { fullscreen = .settings },
                        refreshBadge: refreshBadge,
                        onDeleted: { chatWasDeleted($0) }
                    ) { picked in
                        chatID = picked
                        if picked == nil { startNewChat() }
                        closeChats()
                    }
                }
                // Background and shadow before the width frame, not after: applied
                // to the full-width positioning frame they painted the panel across
                // the whole screen, covering the dim strip and swallowing the tap
                // that was meant to close it.
                .opaqueBackground()
                .shadow(color: .black.opacity(0.35), radius: 16, x: 6)
                .frame(width: panelWidth)
                .offset(x: x)
                .allowsHitTesting(showingChats)
                // Drags shut under the finger, the way a real drawer does, and
                // snaps back if you let go early.
                .gesture(
                    DragGesture()
                        .onChanged { drag = min($0.translation.width, 0) }
                        .onEnded { value in
                            let travel = min(value.translation.width, 0)
                            drag = 0
                            if travel < -panelWidth * 0.3
                                || value.predictedEndTranslation.width < -panelWidth * 0.7 {
                                closeChats()
                            }
                        }
                )
            }
            .task {
                #if DEBUG
                probeOpenChat()
                #endif
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: showingChats)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: drag)
            // Both of these are things you read, so they get the whole screen and
            // the drawer steps aside behind them.
            .fullScreenCoverIOS(item: $fullscreen) { which in
                NavigationStack {
                    Group {
                        switch which {
                        case .chats:
                            ChatListView(
                                session: session,
                                onOpenNotes: { fullscreen = .notes },
                                refreshBadge: refreshBadge,
                                showsLibrary: false,
                                onDeleted: { chatWasDeleted($0) }
                            ) { picked in
                                chatID = picked
                                if picked == nil { startNewChat() }
                                fullscreen = nil
                                closeChats()
                            }
                        case .notes:
                            NotesView(client: session.client)
                        case .settings:
                            SettingsView(session: session) {
                                // Closing the cover first: the sign-out drops the
                                // token and the root swaps to the sign-in screen,
                                // and a cover left over the swap looks like a
                                // crash rather than a sign-out.
                                fullscreen = nil
                                session.signOut()
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { fullscreen = nil }
                        }
                    }
                }
            }
            // Swipe right from the left edge to open, the way every other drawer
            // on the platform works. A simultaneous gesture rather than a
            // high-priority one, so a vertical scroll inside the transcript still
            // wins and the horizontal case is the only one that fires.
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        guard !showingChats,
                            value.startLocation.x < 40,
                            value.translation.width > 70,
                            abs(value.translation.height) < 70
                        else { return }
                        withAnimation(.snappy(duration: 0.28)) { showingChats = true }
                    }
            )
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
