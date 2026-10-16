import PhotosUI
import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif
#if os(iOS)
import UIKit
#endif

/// The composer, shaped like the Claude app's: one card holding the text, and a
/// row underneath with a `+` for everything that is not typing, a chip naming
/// the model, and send.
///
/// The shape is the point. A chip keeps "which model is answering me" on screen
/// at all times instead of hidden in a toolbar, and putting attachments and
/// toggles behind `+` stops the keyboard from pushing a wall of controls around.
///
/// Every picker lives here rather than in the `+` sheet: a sheet cannot reliably
/// present a second sheet, so the sheet only says which one it wants and closes.
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    var models: [ChatModel] = []
    /// Tools offered by the instance, passed through to the `+` sheet.
    var chatTools: [ChatTool] = []
    var chatToolsError: String? = nil
    /// Opens a tool's sign-in page, with a closure to run once it is finished.
    /// Handed down from the conversation, which owns the tool list and so is the
    /// place that can refresh it afterwards.
    var onAuthorize: (URL, @escaping (Bool) -> Void) -> Void = { _, _ in }

    /// So sending can put the keyboard away. Left alone it stays up after the
    /// message goes out, and the transcript underneath is left with a gap the
    /// size of the keyboard that only a scroll-up makes the app notice.
    @FocusState private var inputFocused: Bool

    @State private var sheet: Sheet?
    @State private var pending: Pending?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingFiles = false
    @State private var cameraRequest = false
    #if os(iOS)
    @State private var voice = VoiceRecorder()
    @State private var pressStart: Date? = nil
    @State private var startedByPress = false
    #endif

    private enum Sheet: Identifiable {
        case add, models
        var id: Int { hashValue }
    }

    /// Something the `+` sheet asked for, held until this sheet is gone.
    // Not Equatable any more: the authorize case now carries the follow-up to run
    // once sign-in ends, and a closure cannot be compared.
    private enum Pending {
        case camera, photos, files, authorize(URL, (Bool) -> Void)

        // The picker binding only needs to know "is this the photo case", and a
        // hand-written test beats conforming to Equatable for a case that holds a
        // closure.
        var isPhotos: Bool {
            if case .photos = self { return true }
            return false
        }
    }

    /// Sending is a deliberate end of typing: the keyboard should go with it, so
    /// the answer is not being read through a 300-point window.
    private func send() {
        inputFocused = false
        conversation.send()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !conversation.attachments.isEmpty { attachmentStrip }

            TextField("Message", text: $conversation.draft, axis: .vertical)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { send() }

            #if os(iOS)
            voiceNote
            #endif

            HStack(spacing: 8) {
                Button { sheet = .add } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.quaternary.opacity(0.7), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add to chat")

                modelChip
                Spacer(minLength: 4)
                if conversation.uploading { ProgressView().controlSize(.small) }
                incognitoChip
                #if os(iOS)
                micControls
                #endif
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.quaternary))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .sheet(item: $sheet) { which in
            switch which {
            case .add:
                AddToChatSheet(
                    conversation: conversation, models: models, tools: chatTools,
                    toolsError: chatToolsError,
                    onAuthorize: { url, done in hand(.authorize(url, done)) },
                    onCamera: { hand(.camera) }, onPhotos: { hand(.photos) },
                    onFiles: { hand(.files) })
            case .models:
                ModelPickerSheet(conversation: conversation, models: models)
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: Binding(get: { pending?.isPhotos == true }, set: { if !$0 { pending = nil } }), selection: $photoItems, matching: .images)
        .sheet(isPresented: $cameraRequest) {
            CameraPicker { data, name, mime in conversation.attach(data: data, name: name, mimeType: mime) }
        }
        .onChange(of: photoItems) { _, items in
            Task {
                for item in items {
                    let name = (item.itemIdentifier ?? "photo")
                        .replacingOccurrences(of: "/", with: "-") + ".jpg"
                    if let data = await photoData(item) {
                        conversation.attach(data: data, name: name, mimeType: "image/jpeg")
                    } else {
                        // Said out loud rather than skipped: a photo that
                        // vanished with no explanation reads as the app being
                        // broken, and the user cannot tell it from a network fault.
                        conversation.attachmentFailed(name)
                    }
                }
                photoItems = []
            }
        }
        #endif
        .fileImporter(
            isPresented: $showingFiles,
            allowedContentTypes: [.data, .content, .image, .pdf, .text, .plainText, .commaSeparatedText],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { urls.forEach(importFile) }
        }
    }

#if os(iOS)
    /// Bytes for a picked photo.
    ///
    /// Plain `Data` comes back nil for a lot of photos people actually take —
    /// HEIC especially — so the item is re-encoded through UIImage as a second
    /// attempt. Without that the picker closed, nothing was attached, and
    /// nothing said why.
    private func photoData(_ item: PhotosPickerItem) async -> Data? {
        if let data = try? await item.loadTransferable(type: Data.self),
            let jpeg = Self.jpeg(from: data) { return jpeg }
        if let bytes = try? await item.loadTransferable(type: ImageBytes.self),
            let jpeg = Self.jpeg(from: bytes.data) { return jpeg }
        return nil
    }

    /// Decodes whatever container the photo is in and re-encodes it as JPEG.
    ///
    /// HEIC is the default on iPhones, and a gateway fronting a model is not
    /// promised to read it. ImageIO decodes HEIC fine, so the app normalises on
    /// the way out rather than hoping the server copes.
    /// EXIF orientation to UIKit's. The two enums agree on numbers 1-4 and then
    /// diverge, so the last four have to be translated rather than cast.
    private static func uiOrientation(_ raw: UInt32) -> UIImage.Orientation {
        switch raw {
        case 1: return .up
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    /// Longest side an image is sent at.
    ///
    /// The picture travels inside the message as a data url, so its size is
    /// paid for in the request body and again in whatever stores the message.
    /// Vision models resample to roughly this scale anyway.
    private static let maxEdge: CGFloat = 1568

    private static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // A phone-stored photo is landscape pixels plus an orientation flag, and
        // `CGImageSourceCreateImageAtIndex` hands you the pixels. Re-encoding
        // without applying that flag sends the picture sideways - which is exactly
        // what this used to do.
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let oriented = UIImage(
            cgImage: image, scale: 1,
            orientation: Self.uiOrientation(
                (properties[kCGImagePropertyOrientation as String] as? UInt32)
                ?? CGImagePropertyOrientation.up.rawValue))

        let width = CGFloat(image.width), height = CGFloat(image.height)
        let oversized = max(width, height) > maxEdge
        // Only the oversized path used to draw, and `jpegData` on a UIImage whose
        // orientation is a *flag* rather than rotated pixels writes the raw
        // pixels and drops the flag. So a phone photo that happened to be small
        // enough went out sideways while a big one came out upright — which is
        // the "it looked right in the app but the model said it was turned 90
        // degrees". Anything not already upright gets drawn, whatever its size.
        guard oversized || oriented.imageOrientation != .up else {
            return oriented.jpegData(compressionQuality: 0.9)
        }
        let scale = oversized ? maxEdge / max(width, height) : 1
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // Draws in the orientation, so the output is upright and flag-free.
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            oriented.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: oversized ? 0.85 : 0.9)
    }

#endif

    /// Opens a picker after the `+` sheet has finished closing. Presenting during
    /// the dismiss animation is silently ignored, which looks like a dead button.
    private func hand(_ which: Pending) {
        pending = which
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            switch which {
            case .camera:
                cameraRequest = true
                pending = nil
            case .photos:
                // Left alone on purpose. The picker's own binding clears
                // `pending` when the user finishes; clearing it here opened the
                // photo grid and shut it again in the same frame, so it flashed
                // and vanished before a finger could land on a picture.
                break
            case .files:
                showingFiles = true
                pending = nil
            case let .authorize(url, done):
                // Same reason as the pickers: the sign-in browser is presented by
                // the conversation behind this sheet, and asking for it while the
                // `+` sheet is still on screen means it waits until that sheet
                // happens to close — which is what made the browser look like it
                // only appeared after dismissing the menu by hand.
                onAuthorize(url, done)
                pending = nil
            }
        }
    }

    #if os(iOS)
    /// Dictation, with two gestures on one control because people expect both.
    ///
    /// A tap starts recording and it keeps going until you tap again — good when
    /// you are dictating at length and want to look at what you have said. A
    /// press-and-hold records for as long as the finger is down and releases
    /// when you let go, which is faster for a single sentence and needs no
    /// second aim at a small button.
    ///
    /// The two are told apart by how long the press lasted, which means the
    /// recording starts on touch-down: waiting to see which gesture it was would
    /// clip the first syllable, and the first syllable is usually the word that
    /// matters.
    private var micControls: some View {
        let recording = voice.phase == .recording
        return HStack(spacing: 6) {
            // Width reserved even when empty, so nothing in the row shifts when
            // recording starts. See the note on `micCircle`.
            micTimer.frame(width: 30, alignment: .trailing)
            micCircle
                .gesture(micGesture)
        }
        .animation(.snappy(duration: 0.18), value: recording)
    }

    /// The button itself, deliberately inert: same frame, same view tree, same
    /// everything in every state, with only opacity and fill colour differing.
    ///
    /// This is not fastidiousness. The first version swapped a circle for a
    /// wider capsule when recording began, and SwiftUI tore the view down mid
    /// press and cancelled the drag with it — `onEnded` never fired, so letting
    /// go did nothing and the only way out was a second tap. A gesture must not
    /// be attached to a view that changes underneath it.
    private var micCircle: some View {
        let recording = voice.phase == .recording
        let busy = voice.phase == .transcribing || voice.phase == .starting
        return ZStack {
            Image(systemName: "mic").opacity(recording || busy ? 0 : 1)
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .opacity(recording ? 1 : 0)
            ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(recording ? Color.white : Color.secondary)
        .frame(width: 34, height: 34)
        .background(Circle().fill(recording ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary.opacity(0.7))))
        .contentShape(.circle)
        .accessibilityLabel(recording ? "Stop dictation" : "Dictate")
    }

    /// What happened to the last recording, on its own line where the sentence
    /// fits. It used to be a red capsule floating over the text field, which
    /// truncated "No speech recognised" to "No speech…" and made an ordinary
    /// empty result look like a crash.
    @ViewBuilder private var voiceNote: some View {
        switch voice.phase {
        case .empty:
            Label("No speech heard", systemImage: "waveform.slash")
                .modifier(VoiceNoteStyle(tint: .secondary))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .modifier(VoiceNoteStyle(tint: .red))
        default:
            EmptyView()
        }
    }

    /// Elapsed seconds, drawn outside the button so the button never resizes.
    private var micTimer: some View {
        Text(voice.phase == .recording ? "\(Int(voice.elapsed))s" : " ")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var micGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                // The press is always timed, even when it will not start a
                // recording: a tap while already recording has to be measured
                // too, or the release cannot tell a tap that means "stop" from
                // anything else.
                guard pressStart == nil, !conversation.phase.isBusy else { return }
                pressStart = Date()
                startedByPress = !voice.isBusy
                if startedByPress {
                    haptic(.light)
                    Task { await voice.start() }
                }
            }
            .onEnded { _ in
                let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                pressStart = nil
                defer { startedByPress = false }
                // Not `isBusy`: that is true while recording, which is exactly
                // the state a release has to act on.
                guard voice.phase != .transcribing, voice.phase != .starting else { return }
                // A short tap that started the recording leaves it running;
                // everything else — a long hold, or any press while already
                // recording — ends it and transcribes.
                if startedByPress && held < Self.holdThreshold { return }
                haptic(.medium)
                Task {
                    await voice.stop(client: conversation.client) { text in
                        let existing = conversation.draft.trimmingCharacters(in: .whitespaces)
                        conversation.draft = existing.isEmpty ? text : existing + " " + text
                    }
                }
            }
    }

    /// Below this a press was a tap, not a hold.
    static let holdThreshold: TimeInterval = 0.35

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    #endif

    private var sendButton: some View {
        Button {
            if conversation.phase.isBusy { conversation.stop() } else { send() }
        } label: {
            Image(systemName: conversation.phase.isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(conversation.phase.isBusy || conversation.canSend ? .white : .secondary)
                .frame(width: 34, height: 34)
                .background(
                    conversation.phase.isBusy ? AnyShapeStyle(.red)
                        : conversation.canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!conversation.phase.isBusy && !conversation.canSend)
        .accessibilityLabel(conversation.phase.isBusy ? "Stop" : "Send")
    }

    /// Incognito, where you can actually see it.
    ///
    /// It used to live only inside the `+` sheet, which is a strange place to hide
    /// the one setting that decides whether the conversation is saved at all — you
    /// either never notice it or go looking for it mid-chat. A mask next to the
    /// model chip is visible at a glance and one tap from the keyboard.
    private var incognitoChip: some View {
        Button { conversation.incognito.toggle() } label: {
            // `mask` is not an SF Symbol (it is `facemask`), so the earlier version
            // of this drew an empty circle. `eye.slash` is older, always present,
            // and says "this is not being watched or kept", which is the setting.
            Image(systemName: conversation.incognito ? "eye.slash.fill" : "eye.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(conversation.incognito ? Color.primary : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    conversation.incognito
                        ? AnyShapeStyle(.quaternary.opacity(0.95))
                        : AnyShapeStyle(.quaternary.opacity(0.4)),
                    in: .circle)
        }
        .buttonStyle(.plain)
        // Turning it on halfway through a saved chat cannot undo the messages
        // already written, and turning it off cannot bring a discarded chat back.
        // So it is a choice for the start of a conversation, which is also how the
        // web UI treats it.
        .disabled(!conversation.canChangeIncognito)
        .accessibilityLabel(
            conversation.incognito
                ? "Incognito is on. This chat is not saved to your history."
                : "Incognito is off. Tap to stop saving this chat to your history.")
    }

    /// The model, always visible, and the way into the model sheet.
    private var modelChip: some View {
        Button { sheet = .models } label: {
            HStack(spacing: 5) {
                Text(models.first(where: { $0.id == conversation.model })?.name.nonEmpty ?? conversation.model)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if !featuresOn.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(featuresOn, id: \.self) { feature in
                            Image(systemName: feature.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .accessibilityLabel(feature.title)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(conversation.phase.isBusy)
        .accessibilityLabel("Model \(conversation.model)")
    }

    /// Which capabilities are on for this message, in the chip's secondary slot.
    private var featuresOn: [ChatFeature] {
        ChatFeature.allCases.filter { conversation.features[$0.rawValue] ?? false }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conversation.attachments) { attachment in
                    AttachmentChip(attachment: attachment) { conversation.detach(attachment) }
                }
            }
        }
    }

    private func importFile(_ url: URL) {
        // Not optional for a security-scoped URL: without the call the read
        // returns nothing and the user sees a file that silently never attached.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            conversation.attachmentFailed(url.lastPathComponent)
            return
        }
        conversation.attach(
            data: data, name: url.lastPathComponent, mimeType: MIME.type(forPath: url.pathExtension))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct AttachmentChip: View {
    let attachment: ConversationModel.PendingAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .font(.caption)
            Text(attachment.name).font(.caption).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.7), in: .capsule)
    }
}

/// The `+` sheet: a picture, a file, then the switches that change how the model
/// answers.
struct AddToChatSheet: View {
    @Bindable var conversation: ConversationModel
    var models: [ChatModel]
    /// Tools offered by the instance. Empty hides the section entirely: a
    /// "Tools" heading with nothing under it reads as a bug, not as "none".
    var tools: [ChatTool] = []
    var toolsError: String? = nil
    var onAuthorize: (URL, @escaping (Bool) -> Void) -> Void = { _, _ in }
    var onCamera: () -> Void
    var onPhotos: () -> Void
    var onFiles: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        #if os(iOS)
                        Tile(title: "Camera", systemImage: "camera", action: send(onCamera))
                        #endif
                        Tile(title: "Photos", systemImage: "photo.on.rectangle", action: send(onPhotos))
                        Tile(title: "Files", systemImage: "folder", action: send(onFiles))
                        Spacer()
                    }
                    .frame(height: 78)
                }

                if tools.isEmpty, let toolsError {
                    Section("Tools") {
                        Label(toolsError, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !tools.isEmpty {
                    Section {
                        ForEach(tools) { tool in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name)
                                    // The id is noise for an MCP server ("server:mcp:1"),
                                    // so it only appears when there is nothing better.
                                    if let detail = tool.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if tool.authenticated == false {
                                        // Not just a caption under the switch: an
                                        // explicit way to sign in. Leaving it as a
                                        // side effect of the toggle meant the only
                                        // way to start sign-in was to switch on a tool
                                        // you could not yet use, which reads as a bug
                                        // and is easy to never discover.
                                        Button { startSignIn(tool) } label: {
                                            Label("Sign in to use", systemImage: "lock")
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                Spacer(minLength: 12)
                                Toggle("", isOn: toolBinding(tool))
                                    .labelsHidden().fixedSize()
                            }
                            .disabled(!tool.available)
                        }
                    } header: {
                        Text("Tools")
                    } footer: {
                        // Says where they come from, because "why is Notion here"
                        // and "why is Notion missing" are both answered by the
                        // same fact: the instance decides, not the app.
                        Text("From your server. Off here means this chat does not offer them.")
                    }
                }

                Section("Capabilities") {
                    ForEach(ChatFeature.allCases, id: \.self) { feature in
                        Toggle(isOn: binding(for: feature)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                if let model = currentModel, !model.supports(feature) {
                                    Text("Not offered by \(conversation.model)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(currentModel.map { !$0.supports(feature) } ?? false)
                    }
                }
                // Incognito used to have a section here. It moved to the composer,
                // beside the model chip, where it is visible instead of two taps
                // deep — and one control for one setting beats two that have to be
                // kept in sync.
            }
            .inlineTitle("Add to Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Closes this sheet before handing off, because the composer cannot present
    /// a picker while this one is still on screen.
    private func send(_ action: @escaping () -> Void) -> () -> Void {
        { dismiss(); action() }
    }

    private var currentModel: ChatModel? { models.first { $0.id == conversation.model } }

    /// Starts a tool's OAuth sign-in and, if it completes, selects the tool.
    ///
    /// Signing in and then having to flip the switch a second time is the part
    /// that made this feel broken: the browser closed, the row still said "not
    /// signed in", and the tool was still off. So the tap that started the
    /// sign-in is remembered and completes itself when the browser returns.
    private func startSignIn(_ tool: ChatTool) {
        guard let url = tool.authorizeURL(base: conversation.serverURL) else { return }
        let picked = tool.id
        send {
            onAuthorize(url) { finished in
                if finished, !conversation.tools.contains(picked) {
                    conversation.tools.append(picked)
                }
            }
        }()
    }

    private func toolBinding(_ tool: ChatTool) -> Binding<Bool> {
        Binding(
            get: { conversation.tools.contains(tool.id) },
            set: { on in
                guard on else {
                    conversation.tools.removeAll { $0 == tool.id }
                    return
                }
                // An unauthenticated server cannot serve anything, so switching
                // it on starts the sign-in instead of pretending it is enabled.
                // Before this the row went green while the tool was still dead,
                // and the chat quietly had no tool at all.
                if tool.authorizeURL(base: conversation.serverURL) != nil {
                    startSignIn(tool)
                    return
                }
                conversation.tools.append(tool.id)
            })
    }

    private func binding(for feature: ChatFeature) -> Binding<Bool> {
        Binding(
            get: { conversation.features[feature.rawValue] ?? false },
            set: { conversation.features[feature.rawValue] = $0 })
    }
}

private struct Tile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption)
            }
            .frame(width: 78, height: 78)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 16))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

/// The model sheet: name, what it is for, what it can do, a tick on the one in
/// use.
struct ModelPickerSheet: View {
    @Bindable var conversation: ConversationModel
    var models: [ChatModel]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(models, id: \.id) { model in
                        Button {
                            conversation.select(model: model.id, from: models)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name.isEmpty ? model.id : model.name)
                                    // Only when the server actually described the
                                    // model. Repeating the id underneath its own
                                    // name is noise that looks like a bug.
                                    if let description = model.description, !description.isEmpty {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Badges(model: model)
                                }
                                Spacer()
                                if model.id == conversation.model {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Capabilities are what the server reports. A model that reports none is not limited — it just did not say.")
                }
            }
            .inlineTitle("Select model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct Badges: View {
    let model: ChatModel
    // Only what a user would notice. `file_upload` and `memory` are plumbing;
    // vision, tools and search change what they can ask for.
    var body: some View {
        HStack(spacing: 5) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: .capsule)
            }
        }
    }

    private var names: [String] {
        [("vision", model.supportsVision), ("tools", model.supportsTools),
         ("search", model.supportsWebSearch), ("code", model.supportsCodeInterpreter)]
            .filter(\.1).map(\.0)
    }
}

#if os(iOS)
/// Camera capture bridged to SwiftUI. Absent on a Mac, and on the simulator the
/// source is unavailable — the button is there so the flow is testable on device.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data, String, String) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) { picker.sourceType = .camera }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data, String, String) -> Void
        init(_ onCapture: @escaping (Data, String, String) -> Void) { self.onCapture = onCapture }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.85)
            {
                onCapture(data, "camera-\(Int(Date.now.timeIntervalSince1970)).jpg", "image/jpeg")
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
#endif

/// MIME types the server needs and the picker does not always supply.
enum MIME {
    static func type(forPath ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain"
        case "csv": "text/csv"
        case "json": "application/json"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: "application/octet-stream"
        }
    }
}

#if os(iOS)
/// Gallery bytes read by content type rather than by file extension, so a HEIC
/// photo is still accepted where a `.jpeg`-only representation would fail.
private struct ImageBytes: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { ImageBytes(data: $0) }
    }
}
#endif

#if os(iOS)
/// One line of feedback about the last recording: small, left aligned, allowed
/// to wrap, and never a floating badge over something else.
private struct VoiceNoteStyle: ViewModifier {
    var tint: Color

    func body(content: Content) -> some View {
        content
            .font(.caption2)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }
}
#endif
