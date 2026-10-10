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
    /// Opens a tool's sign-in page. Handed down from the conversation, which owns
    /// the tool list and so is the place that can refresh it afterwards.
    var onAuthorize: (URL) -> Void = { _ in }

    @State private var sheet: Sheet?
    @State private var pending: Pending?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingFiles = false
    @State private var cameraRequest = false

    private enum Sheet: Identifiable {
        case add, models
        var id: Int { hashValue }
    }

    /// A picker the `+` sheet asked for, held until this sheet is gone.
    private enum Pending { case camera, photos, files }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !conversation.attachments.isEmpty { attachmentStrip }

            TextField("Message", text: $conversation.draft, axis: .vertical)
                .lineLimit(1...8)
                .onSubmit { conversation.send() }

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
                    toolsError: chatToolsError, onAuthorize: onAuthorize,
                    onCamera: { hand(.camera) }, onPhotos: { hand(.photos) },
                    onFiles: { hand(.files) })
            case .models:
                ModelPickerSheet(conversation: conversation, models: models)
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: Binding(get: { pending == .photos }, set: { if !$0 { pending = nil } }), selection: $photoItems, matching: .images)
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
    private static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
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
            }
        }
    }

    private var sendButton: some View {
        Button {
            if conversation.phase.isBusy { conversation.stop() } else { conversation.send() }
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

    /// The model, always visible, and the way into the model sheet.
    private var modelChip: some View {
        Button { sheet = .models } label: {
            HStack(spacing: 5) {
                Text(models.first(where: { $0.id == conversation.model })?.name.nonEmpty ?? conversation.model)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let hint = chipHint {
                    Text(hint).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
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

    /// What is on for this message, in the chip's secondary slot — the same slot
    /// Claude uses for "Medium".
    private var chipHint: String? {
        let on = ChatFeature.allCases.filter { conversation.features[$0.rawValue] ?? false }
        return on.isEmpty ? nil : on.map(\.shortTitle).joined(separator: " · ")
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
    var onAuthorize: (URL) -> Void = { _ in }
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
                            Toggle(isOn: toolBinding(tool)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name)
                                    // The id is noise for an MCP server ("server:mcp:1"),
                                    // so it only appears when there is nothing better.
                                    if let detail = tool.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if tool.authenticated == false {
                                        // Says it, because the alternative is a tool that
                                        // is switched on and silently does nothing.
                                        Label("Not signed in", systemImage: "lock")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
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
                if let url = tool.authorizeURL(base: conversation.serverURL) {
                    onAuthorize(url)
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
