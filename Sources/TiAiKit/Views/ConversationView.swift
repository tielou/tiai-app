import SwiftUI
#if os(iOS)
import QuickLook
#endif

/// The conversation screen.
///
/// Two behaviours are worth calling out because getting them wrong is the
/// difference between "feels native" and "feels like a website":
///
/// * It scrolls to follow the answer only while the reader is already at the
///   bottom. Auto-scroll that fights someone who scrolled up to re-read a
///   paragraph is the single most annoying thing a chat app can do.
/// * The composer stays usable while a run is in flight — the send button
///   becomes Stop, and the draft is not thrown away.
public struct ConversationView: View {
    private let session: SessionStore
    @State private var conversation: ConversationModel
    @State private var atBottom = true
    /// Read-aloud. One player for the screen, not one per message: starting a
    /// second answer while the first is speaking should take the voice, not talk
    /// over it, and the audio session belongs to the app rather than a row.
    @State private var speech: SpeechPlayer
    /// How far past the end of the content the reader has dragged, as a negative
    /// number. Zero whenever there is still content below the fold.
    @State private var overscroll: CGFloat = 0
    /// True while a finger is on the scroll view.
    @State private var interacting = false
    /// Height of the transcript's container, watched so a keyboard coming or
    /// going can be reacted to.
    @State private var containerHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    /// Tools offered by the instance — MCP servers and workspace tools. Loaded
    /// lazily and the section hidden if there are none, so an instance with no
    /// tools simply has no Tools row.
    @State private var chatTools: [ChatTool] = []
    @State private var chatToolsError: String?
    /// Said out loud rather than swallowed: without a terminal the model cannot
    /// write a file, and a silent failure here looks like a model that lies.
    @State private var terminalError: String?

    /// Sandbox files: which one is downloading, which failed, and the one handed
    /// to the share sheet.
    @State private var busyFile: String?
    @State private var failedFile: String?
    @State private var shareFile: SharedFile?
    @State private var exportFailed = false

    /// Fetch a file the model left in its terminal sandbox and hand it to the
    /// share sheet, which is how you get it into Files, Books, or a print job.
    ///
    /// The sandbox is addressed by chat, so a chat that has not been saved yet
    /// cannot have one — the server would not know whose terminal to look in.
    /// Which sandbox file is downloading, and which failed. Owned by the screen,
    /// because the screen is the one doing the fetching.
    @State private var seededTools = false

    /// Workspace tools start switched on.
    ///
    /// They are capabilities the admin installed for this instance — a PDF writer,
    /// a document reader — and a chat that cannot make a PDF because the reader
    /// had to know to dig for a toggle three levels deep is worse than one that
    /// tries. MCP servers are the exception: they need a sign-in first, so
    /// selecting them by default would put a broken tool in every request.
    ///
    /// Only seeded once, and only while nothing is selected, so switching
    /// everything off stays switched off.
    private func seedTools(_ tools: [ChatTool]) {
        guard !seededTools else { return }
        seededTools = true
        guard conversation.tools.isEmpty else { return }
        conversation.tools = tools
            .filter { !$0.id.hasPrefix("server:") && $0.available }
            .map(\.id)
    }

    /// Fetch a file the answer linked and hand it to the share sheet. The link is
    /// a `/files/{id}/content` route, which needs the app's token, so the system
    /// browser would only be shown a 401.
    private func openFileLink(_ link: FileLink) {
        busyFile = link.id
        failedFile = nil
        Task {
            defer { busyFile = nil }
            guard let data = try? await session.client.fileContent(id: link.id), !data.isEmpty
            else { failedFile = link.id; return }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(link.name.replacingOccurrences(of: "/", with: "-"))
            try? FileManager.default.removeItem(at: out)
            guard (try? data.write(to: out)) != nil else { failedFile = link.id; return }
            shareFile = SharedFile(url: out)
        }
    }

    private func openTerminalFile(_ file: TerminalFile) {
        guard let chat = conversation.chatID else {
            failedFile = file.id
            return
        }
        busyFile = file.id
        failedFile = nil
        Task {
            defer { busyFile = nil }
            guard let data = try? await session.client.terminalFile(
                selector: file.selector, path: file.path, sessionID: chat), !data.isEmpty
            else {
                failedFile = file.id
                return
            }
            // Written to a real URL: the share sheet wants a file it can hand to
            // another app, and a PDF sitting in memory is not that.
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: out)
            guard (try? data.write(to: out)) != nil else {
                failedFile = file.id
                return
            }
            shareFile = SharedFile(url: out)
        }
    }

    /// Cache keys are per server, so two instances on one phone never trade data.
    private var host: String { session.client.server.baseURL.host ?? "local" }
    /// A tool waiting on a sign-in. The browser lives here because the tool list
    /// does, and the list has to be read again the moment the browser closes.
    @State private var authorizing: AuthorizeRequest?
    /// What to run when the sign-in browser closes, set when it opens. The tool
    /// that asked to be signed into is the one that should end up selected, and
    /// the composer is the only place that knows which one it was.
    @State private var authFinished: ((Bool) -> Void)?

    /// The image-trim offer awaiting confirmation in the error banner (issue #2).
    /// Kept in the view, not the model: the model owns the offer, the view owns
    /// the dialog.
    @State private var pendingTrim: ImageTrimOffer?

    struct AuthorizeRequest: Identifiable, Hashable {
        let url: URL
        var id: String { url.absoluteString }
    }
    /// Kept for the composer and the model sheet: the conversation only needs the
    /// id to seed itself, but the UI needs the whole record to show what each
    /// model can do. Dropping this is how the model sheet renders empty.
    @State private var models: [ChatModel]

    /// Starts another chat. Set when this view is the app's home rather than a
    /// pushed screen; the alternative was opening the chat list and finding the
    /// compose button in there, which is three taps to do the most common thing.
    var onNewChat: (() -> Void)? = nil

    public init(
        session: SessionStore, chatID: String?, title: String = "New Chat",
        models: [ChatModel] = [], onNewChat: (() -> Void)? = nil,
        initialDraft: String = ""
    ) {
        self.session = session
        self.onNewChat = onNewChat
        let player = SpeechPlayer(client: session.client)
        player.setVoice(SettingsStore.shared.defaults.readAloudVoice)
        _speech = State(initialValue: player)
        self._models = State(initialValue: models)
        let model = ConversationModel(
            chatID: chatID,
            title: title,
            models: models,
            client: session.client,
            hub: session.eventHub())
        // Something shared from another app arrives as a composed prompt. It
        // lands in the composer rather than being sent: "share to my assistant"
        // is a request to be shown, not a licence to post.
        model.draft = initialDraft
        _conversation = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // No divider under the nav bar. The composer already has its own
            // outlined card, and a hairline across the top of the transcript just
            // cut the screen in two for no reason.
            transcript
            if let error = conversation.error {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    // Issue #2: the over-cap refusal used to be a dead end. The
                    // model now says which oldest images would have to go; this
                    // offers the way out. Confirm-gated because it rewrites
                    // persisted messages server-side and there is no undo.
                    if let trim = conversation.imageTrim, !conversation.phase.isBusy {
                        Button("Remove \(trim.dropTotal) oldest image\(trim.dropTotal == 1 ? "" : "s")") {
                            pendingTrim = trim
                        }
                        .font(.footnote)
                        .confirmationDialog(
                            "Remove the oldest images?",
                            isPresented: Binding(
                                get: { pendingTrim != nil },
                                set: { if !$0 { pendingTrim = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Remove \(trim.dropTotal) oldest image\(trim.dropTotal == 1 ? "" : "s")",
                                role: .destructive
                            ) {
                                pendingTrim = nil
                                Task { await conversation.trimOldestImagesToFit() }
                            }
                            Button("Cancel", role: .cancel) { pendingTrim = nil }
                        } message: {
                            Text((pendingTrim ?? trim).confirmationMessage)
                        }
                    }
                    // The one retry that can be offered honestly: the last
                    // question is known, and re-running it is the same operation
                    // the toolbar's regenerate already does. Not offered while
                    // busy, because a second run would collide with the first.
                    // And not while the draft holds text: after a failed-send
                    // rollback (issue #9) the composer carries the message that
                    // never got out, and regenerating would re-run the PREVIOUS
                    // message as a fork — the wrong action entirely. The right
                    // action there is pressing send again.
                    if !conversation.phase.isBusy,
                        conversation.draft.isEmpty,
                        conversation.turns.contains(where: \.isUser) {
                        Button("Retry") { conversation.regenerate() }
                            .font(.footnote)
                    }
                    // A banner the user has read has served its purpose; one
                    // that only goes away on the next send is a permanent
                    // smear of red (issue #9).
                    Button {
                        conversation.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.red.opacity(0.08))
            }
            ComposerView(
                conversation: conversation, models: models,
                chatTools: chatTools, chatToolsError: chatToolsError,
                onAuthorize: { url, done in
                    authFinished = done
                    authorizing = AuthorizeRequest(url: url)
                })
        }
        // A chat that is not being saved has to say so where you are looking,
        // not only in a sheet you set once at the start and never opened again.
        .inlineTitle(conversation.incognito ? "Incognito" : conversation.title)
        #if os(iOS)
        .sheet(item: $authorizing) { request in
            OAuthWebView(
                url: request.url, token: conversation.authToken,
                domain: conversation.serverHost
            ) { completed in
                // The point of signing in is that the row stops saying "not
                // signed in", so the list is read again immediately rather than
                // waiting for a foreground change that may never come.
                Task {
                    chatTools = (try? await session.client.chatTools()) ?? chatTools
                }
                authFinished?(completed)
                authFinished = nil
            }
        }
        #endif
        #if os(iOS)
        // A preview, not the share sheet: QuickLook renders a PDF properly and
        // already carries share, save, copy and print in its own bar, so putting
        // the share sheet first made the reader choose before they had seen the
        // file. Presented full screen because a page needs the room.
        .fullScreenCoverIOS(item: $shareFile) { item in
            QuickLookPreview(url: item.url)
        }
        #endif
        .toolbar { toolbar }
        .task {
            #if DEBUG
            // Diagnostics: `TIAI_DUMP_CHAT=<id>` reads one chat record into the
            // dump directory using the app's own session, so a payload can be
            // inspected without anyone pasting a token into a terminal.
            if let probe = ProcessInfo.processInfo.environment["TIAI_DUMP_CHAT"] {
                Task {
                    // A leading slash means "this exact path", so a route can be
                    // probed with the app's session; a bare id is a chat. The
                    // slash is load-bearing: `api()` concatenates, so dropping it
                    // produced `/api/v1tools/` and every probe came back null.
                    let path = probe.hasPrefix("/") ? probe : "chats/\(probe)"
                    do {
                        let json = try await session.client.rawJSON(path)
                        let data = try JSONEncoder().encode(json)
                        OWUIClient.dump(url: URL(string: "https://dump/\(path)")!,
                                        method: "PROBE", data: data)
                    } catch { OWUIClient.debugLog("probe \(path) failed: \(error)") }
                }
            }
            // Diagnostics: does this instance speak? Read-only, one short phrase.
            if let phrase = ProcessInfo.processInfo.environment["TIAI_SPEECH_PROBE"] {
                Task {
                    do {
                        let (data, type) = try await session.client.speech(text: phrase)
                        OWUIClient.debugLog("speech probe ok: \(data.count) bytes, \(type)")
                    } catch { OWUIClient.debugLog("speech probe failed: \(error)") }
                }
            }
            // Diagnostics. The sheet that normally starts a sign-in cannot be
            // driven with synthetic clicks, so this starts the first tool that
            // needs one on launch: TIAI_OAUTH_PROBE=1.
            if ProcessInfo.processInfo.environment["TIAI_OAUTH_PROBE"] != nil,
               conversation.chatID == nil {
                probeOAuth()
            }
            // Diagnostics: `TIAI_FILE_PROBE=<chat>|<selector>|<path>` fetches one
            // sandbox file and logs the result, so the terminal route can be
            // confirmed without driving the transcript to a message that has one.
            if let probe = ProcessInfo.processInfo.environment["TIAI_FILE_PROBE"] {
                Task {
                    // `file:<id>` checks the link path instead of the sandbox one.
                    if probe.hasPrefix("file:") {
                        let id = String(probe.dropFirst(5))
                        do {
                            let data = try await session.client.fileContent(id: id)
                            OWUIClient.debugLog("file probe ok: \(data.count) bytes")
                        } catch { OWUIClient.debugLog("file probe failed: \(error)") }
                        return
                    }
                    let parts = probe.split(separator: "|", omittingEmptySubsequences: false)
                    guard parts.count == 3 else {
                        OWUIClient.debugLog("file probe: expected chat|selector|path")
                        return
                    }
                    do {
                        let data = try await session.client.terminalFile(
                            selector: String(parts[1]), path: String(parts[2]),
                            sessionID: String(parts[0]))
                        OWUIClient.debugLog("file probe ok: \(data.count) bytes")
                    } catch { OWUIClient.debugLog("file probe failed: \(error)") }
                }
            }
            #endif
            await conversation.connect()
            // Cached tools and models appear immediately; the network corrects
            // them a beat later. A chat with no model to name cannot send.
            if models.isEmpty,
               let cached = DiskCache.load([ChatModel].self, key: DiskCache.key("models", host: host)) {
                models = cached
            }
            if let cached = DiskCache.load([ChatTool].self, key: DiskCache.key("tools", host: host)) {
                chatTools = cached
                seedTools(cached)
            }
            await conversation.load()
            if models.isEmpty, let fresh = try? await session.client.models(), !fresh.isEmpty {
                models = fresh
                DiskCache.save(fresh, key: DiskCache.key("models", host: host))
            }
            conversation.setModels(models)
            if conversation.terminalID == nil,
                let cached = DiskCache.load([Terminal].self, key: DiskCache.key("terminals", host: host)) {
                conversation.terminalID = cached.first?.id
            }
            do {
                let fresh = try await session.client.chatTools()
                chatTools = fresh
                DiskCache.save(fresh, key: DiskCache.key("tools", host: host))
                seedTools(fresh)
            }
            // Kept rather than swallowed: an absent Tools section is otherwise
            // indistinguishable from an instance that has no tools, and the
            // second one is normal while the first is a bug.
            catch { chatToolsError = error.localizedDescription }
            // The completion request has to name a terminal to be given its tools,
            // so this is what makes "make me a PDF" possible at all. Cached like
            // the tools: a chat opened offline still knows where its sandbox is.
            do {
                let fresh = try await session.client.terminals()
                conversation.terminalID = fresh.first?.id
                DiskCache.save(fresh, key: DiskCache.key("terminals", host: host))
            } catch { terminalError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only act on coming back. `.inactive` is Control Centre, a pulled-down
            // notification, or a glance at the app switcher — none of which kill the
            // socket — and cancelling the run there is exactly what made the app
            // shout "the server sent nothing" about a run that was still being
            // written, leaving no option but to leave the chat and come back.
            //
            // `.background` is not handled either, on purpose. iOS may kill the
            // socket, but the server keeps writing regardless, and the run's own
            // reconciliation catches up on the record when the app returns.
            guard phase == .active else { return }
            Task {
                // The socket is gone after a background sojourn and nothing
                // else would notice until a send quietly streamed into the
                // void. Retried in the background rather than awaited: the
                // radio is often still coming back at this exact moment, and
                // making the chat wait for it — or banner about it — is worse
                // than connecting a second later.
                conversation.resumeAfterBackground()
                // Coming back from a browser sign-in is the normal way this
                // changes: the tool said "not signed in", you signed in, and
                // the row should know that without a relaunch.
                if let tools = try? await session.client.chatTools() {
                    chatTools = tools
                    DiskCache.save(tools, key: DiskCache.key("tools", host: host))
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not `LazyVStack`. A lazy stack has to guess the height of rows
                // that are off-screen, and those guesses become the scroll
                // content's height. Combined with `defaultScrollAnchor(.bottom)`
                // the app lands at the bottom of a page that is mostly estimate and
                // no content — a black void, with a scrollbar saying there is a lot
                // more below, that only collapses back to reality as you scroll and
                // each row finally gets measured.
                //
                // It showed up after sending, which is exactly when the estimate is
                // worst: a new empty assistant row is appended, the app scrolls to
                // the bottom anchor, and that anchor is sitting in guessed space.
                // "Scroll up and it goes back to normal" is the tell — the same
                // tell as the void when opening a long chat. Reproduced side by side
                // by reverting this one line to `LazyVStack`.
                //
                // A transcript is tens of rows, not thousands, so laying them out
                // eagerly is the cheap side of that trade.
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.turns.isEmpty {
                        if let failure = conversation.error {
                            // A chat that will not load must not look like a chat
                            // that has nothing in it. This is what a deleted or
                            // inaccessible conversation used to look like: the
                            // greeting, the cat, and no hint that anything was
                            // wrong.
                            UnloadedChat(message: failure)
                        } else {
                            EmptyTranscript(greeting: Greeting.line(for: session.user?.name))
                        }
                    }
                    ForEach(conversation.turns) { turn in
                        MessageRow(
                            turn: turn,
                            onResolve: { call, action, answers in
                                conversation.resolve(
                                    messageID: turn.id, call: call, action: action, answers: answers)
                            },
                            onEdit: turn.isUser
                                ? { conversation.edit(messageID: turn.id, text: $0) } : nil,
                            onRate: turn.isAssistant && !turn.streaming
                                ? { conversation.rate(messageID: turn.id, rating: $0) } : nil,
                            onRegenerate: turn.isAssistant && !turn.streaming
                                && conversation.turns.last?.id == turn.id
                                ? { conversation.regenerate() } : nil,
                            rating: conversation.ratings[turn.id],
                            sibling: conversation.siblingPage(of: turn.id),
                            onSibling: { conversation.selectSibling(of: turn.id, direction: $0) },
                            fileLoader: { await conversation.fileData(id: $0) },
                            speech: speech,
                            onOpenFile: openTerminalFile,
                            onOpenLink: openFileLink,
                            fileBusy: busyFile,
                            fileFailed: failedFile
                        )
                            .equatable()
                            .id(turn.id)
                    }
                    // Reserves room so the last line is not hidden behind the
                    // composer, and gives the scroll anchor something to hit.
                    Color.clear.frame(height: 8).id(BottomAnchor.id)
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            // The platform's own "stick to the bottom as content grows" behaviour.
            // Scrolling to the bottom by hand is always a frame late: the delta
            // arrives, the view scrolls to where the bottom *was*, and the line
            // that just rendered lands below the fold. On the last token of a
            // message that is permanent, which is how answers were ending up
            // hidden behind the composer.
            .defaultScrollAnchor(.bottom)
            // A brand new chat holds one short message. Without this the whole
            // thread can be dragged away from the top of the screen, which is
            // where the void comes from before there is enough content to fill
            // the page. Once content overflows, bouncing behaves normally.
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: ScrollFacts.self) { geometry in
                // Positive: room still to scroll. Negative: dragged past the end.
                let edge = geometry.contentOffset.y + geometry.containerSize.height
                return ScrollFacts(shortfall: geometry.contentSize.height - edge)
            } action: { _, facts in
                // The old test was `shortfall < 120`, which is also true when the
                // shortfall is minus four hundred — so dragging past the end read
                // as "at the bottom" and every streamed token kept re-scrolling
                // into the empty space the finger had just revealed.
                atBottom = facts.shortfall < 120
                overscroll = min(facts.shortfall, 0)
            }
            // Two things this buys. Programmatic scrolls are suppressed while a
            // finger is down, so a token arriving mid-drag no longer fights the
            // drag. And a gesture that ends past the end of the content snaps
            // back to it, instead of leaving the reader in a black void with no
            // idea the last message is a flick above.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, new in
                containerHeight = new
            }
            // The keyboard leaving is a container that just grew by ~300 points.
            // Nothing re-anchors the transcript when that happens, so the bottom
            // of the conversation ends up sitting a keyboard-height above where
            // it can reach — which is the void, and why one scroll up made it go
            // away: the scroll forced the layout pass that should have happened
            // on its own.
            .onChange(of: containerHeight) { _, _ in
                guard atBottom, !interacting else { return }
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
            }
            .onScrollPhaseChange { _, phase in
                interacting = (phase == .interacting)
                guard phase == .idle, overscroll < -24 else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                }
            }
            .onChange(of: conversation.turns.last?.text) { _, _ in
                guard atBottom, !interacting else { return }
                // After layout, not during it — see defaultScrollAnchor above.
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
            }
            .onChange(of: conversation.turns.count) { _, _ in
                guard !interacting else { return }
                atBottom = true
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
            }
            .onChange(of: conversation.phase.isBusy) { _, busy in
                // The last token is also the one most likely to land below the
                // fold: there is no following delta to trigger the next scroll.
                // When the run ends, settle once more after layout has finished.
                // (Observed as a Bool: `onChange(of: conversation.phase)` inside
                // a ScrollView resolves to a scroll-phase overload and fails.)
                guard !busy, atBottom else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                // Scrolled up to re-read something, there is no obvious way back:
                // the newest message can be a screen and a half below the fold and
                // nothing on screen says so. The dot only exists while it is true.
                if !atBottom && !conversation.turns.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                        }
                        atBottom = true
                    } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: .circle)
                        .overlay(Circle().stroke(.quaternary))
                    }
                    .buttonStyle(.plain)
                    // Centred, floating, with a shadow: flush against the trailing
                    // edge it read like a stray control glued to the side of the
                    // screen, and off-centre it is not where the eye looks for
                    // "where did the conversation get to". The shadow is what makes
                    // it safe to sit over a line of text — it reads as above the
                    // page rather than printed on it.
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .padding(.bottom, 14)
                    .accessibilityLabel("Scroll to the latest message")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.snappy(duration: 0.18), value: atBottom)
        }
    }

    #if DEBUG
    /// Diagnostics only: start the first tool sign-in the instance offers, so the
    /// OAuth hand-off can be watched end to end without driving the sheet that
    /// normally triggers it.
    private func probeOAuth() {
        Task {
            let tools = (try? await session.client.chatTools()) ?? chatTools
            chatTools = tools
            guard let tool = tools.first(where: { $0.authorizeURL(base: conversation.serverURL) != nil }),
                  let url = tool.authorizeURL(base: conversation.serverURL) else {
                OWUIClient.debugLog("oauth probe: no tool is waiting on a sign-in")
                return
            }
            OWUIClient.debugLog("oauth probe: \(tool.name) -> \(url)")
            authorizing = AuthorizeRequest(url: url)
        }
    }
    #endif

    /// Write the conversation out as a Markdown file and open it, so a chat can
    /// leave the app in one action instead of six copy-pastes.
    private func exportTranscript() {
        let markdown = TranscriptMarkdown.render(
            title: conversation.title,
            turns: conversation.turns,
            model: conversation.model,
            server: session.client.server.baseURL)
        let name = (conversation.title.isEmpty ? "conversation" : conversation.title)
            .replacingOccurrences(of: "/", with: "-")
            .prefix(40)
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name).md")
        do {
            try markdown.data(using: .utf8)?.write(to: out, options: .atomic)
            shareFile = SharedFile(url: out)
        } catch {
            exportFailed = true
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Only once there is something to export: on an empty chat the button
            // would produce a file with a heading and nothing in it.
            if !conversation.turns.isEmpty {
                Button(action: exportTranscript) {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("exportChat")
            }
            if let onNewChat {
                Button(action: onNewChat) {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("newChat")
                // Already staring at an empty chat: the button would only clear a
                // draft nobody asked to lose.
                .disabled(conversation.turns.isEmpty && conversation.draft.isEmpty)
            }
            // The one setting that decides whether this conversation is kept at
            // all. It spent a while inside the `+` sheet and then in the composer
            // row; both put it where you only look for it after the fact.
            Button { conversation.incognito.toggle() } label: {
                Label(
                    "Incognito",
                    systemImage: conversation.incognito ? "eye.slash.fill" : "eye.slash")
            }
            .accessibilityIdentifier("incognito")
            // Turning it on halfway through a saved chat cannot undo the messages
            // already written, and turning it off cannot bring a discarded chat
            // back. So it is a choice for the start of a conversation, which is
            // also how the web UI treats it.
            .disabled(!conversation.canChangeIncognito)
            .accessibilityLabel(
                conversation.incognito
                    ? "Incognito is on. This chat is not saved to your history."
                    : "Incognito is off. Tap to stop saving this chat to your history.")
            if conversation.phase.isBusy {
                Button {
                    conversation.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            }
        }
    }
}

private enum BottomAnchor { static let id = "transcript-bottom" }

/// A chat that opened onto nothing because the server would not give it up.
private struct UnloadedChat: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("This conversation did not load")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 140)
        .frame(maxWidth: .infinity)
    }
}

private struct EmptyTranscript: View {
    /// "Good afternoon, Thilo" — the user, not the model. The model is already
    /// on the composer chip; what an empty screen should answer is "who is this
    /// for", not "which engine is loaded".
    var greeting: String

    var body: some View {
        VStack(spacing: 18) {
            GreetingCat(size: 118)
            Text(greeting)
                .font(.title2.weight(.regular))
                .foregroundStyle(.primary)
        }
        // Not `containerRelativeFrame`: inside this ScrollView it filled the
        // viewport and the transcript came out blank. A generous fixed offset
        // puts the greeting where the eye lands and cannot fight the scroll view.
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
        .padding(.bottom, 60)
    }
}

/// What the scroll geometry has to say about where the reader is.
///
/// A struct rather than a Bool because `onScrollGeometryChange` compares the
/// value it computed last time with the value now, and a Bool would only fire on
/// the at-bottom edge — the amount of overscroll changes constantly and the view
/// needs to see it change.
private struct ScrollFacts: Equatable {
    var shortfall: CGFloat
}
