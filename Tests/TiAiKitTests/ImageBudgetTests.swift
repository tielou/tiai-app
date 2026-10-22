import Foundation
import Testing

@testable import TiAiKit

// The engine hard-rejects a completion carrying more than 64 images ("IMG count
// outside 0..64", an opaque litellm 500), and the client cannot trim the
// history the server rebuilds from the chat tree. So the client counts the
// images the next request would put in front of the engine and refuses — with
// numbers and a way out — before touching anything.

@MainActor
private func waitUntilBudget(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw ProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum ProbeFailure: Error { case timeout }

private func testServer() -> Server {
    Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
}

/// A transport whose uploads never answer — the window in which a photo is
/// picked, visible in the composer, and *not yet in* `attachments` because the
/// file id does not exist until the server replies.
private final class HangingTransport: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _completionBodies: [Data] = []
    private let hangUploads: Bool

    init(hangUploads: Bool) { self.hangUploads = hangUploads }

    var completionBodies: [Data] {
        lock.lock(); defer { lock.unlock() }; return _completionBodies
    }

    /// Locking lives in a synchronous function: `NSLock` is unavailable from an
    /// async context, and the transport methods are async.
    private func record(_ body: Data) {
        lock.lock(); defer { lock.unlock() }; _completionBodies.append(body)
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if hangUploads, path.hasSuffix("/files") || path.hasSuffix("/files/") {
            // `try await`: if the upload is ever cancelled the sleep throws and
            // the upload fails — a cancelled upload must not silently
            // "succeed" with file-1. `attach()`'s catch turns that into an
            // ordinary attach error. Uncancelled, the sleep never ends inside
            // a test, and the trailing throw keeps "never answers" true even
            // if the sleep ever returned.
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        return (
            Data(#"{"id":"file-1","filename":"p.png","type":"image/png","updated_at":1}"#.utf8),
            Self.response(for: request, 200)
        )
    }

    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        record(request.httpBody ?? Data())
        let stream = ByteStream {
            AsyncThrowingStream<Data, any Error> { _ in }
        }
        return (stream, Self.response(for: request, 200))
    }

    private static func response(for request: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// A chat detail whose loaded branch contains `images` user turns, each with
/// exactly one unique `data:` image and an assistant answer after it. The
/// chain is a proper parentId/childrenIds line with `currentId` on the last
/// answer, because `apply()` walks the branch and a seeded message the branch
/// does not reach is a message that does not exist.
private func imageChatDetail(chatID: String, images: Int) -> Data {
    var entries: [String] = []
    var previousAssistant: String?
    var lastID = ""
    for i in 1...max(images, 1) {
        let user = "user-\(i)"
        let assistant = "assistant-\(i)"
        let userParent = previousAssistant.map { "\"\($0)\"" } ?? "null"
        entries.append(
            """
            "\(user)":{"id":"\(user)","role":"user","done":true,"parentId":\(userParent),"childrenIds":["\(assistant)"],\
            "content":[{"type":"text","text":"pic \(i)"},{"type":"image_url","image_url":{"url":"data:image/png;base64,IMG\(i)"}}]}
            """)
        entries.append(
            """
            "\(assistant)":{"id":"\(assistant)","role":"assistant","done":true,"parentId":"\(user)","childrenIds":[],"content":"answer \(i)"}
            """)
        previousAssistant = assistant
        lastID = assistant
    }
    return Data(
        """
        {"id":"\(chatID)","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"\(lastID)","messages":{\(entries.joined(separator: ","))}}}}
        """.utf8)
}

@MainActor
private func makeConversation(
    chatID: String?, transport: any APITransport
) -> ConversationModel {
    ConversationModel(
        chatID: chatID,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: testServer(), transport: transport),
        hub: ChatEventHub(server: testServer()))
}

// MARK: - the counting helper

@Test func imageCountUnionsFilesAndContentAndAddsOutgoing() {
    // The same `data:` URL in the file list (as `messageAttachments` surfaces
    // it) and in a content block is one image, not two.
    var sameImageTwice = Turn(id: "a", role: "user", text: "x")
    sameImageTwice.attachments = [
        MessageAttachment(id: "data:image/png;base64,AAA", name: "image", isImage: true,
                          dataURL: "data:image/png;base64,AAA")
    ]
    sameImageTwice.contentImageURLs = ["data:image/png;base64,AAA"]

    // A file entry and the content block that points at the same file id —
    // `file_id://X` must normalise to the file id `X` to dedup.
    var fileAndFileIDBlock = Turn(id: "b", role: "user", text: "y")
    fileAndFileIDBlock.attachments = [MessageAttachment(id: "file-9", name: "shot.png", isImage: true)]
    fileAndFileIDBlock.contentImageURLs = ["file_id://file-9"]

    // A non-`data:` image_url block counts; `attachments` never shows it.
    var remoteImage = Turn(id: "c", role: "user", text: "z")
    remoteImage.contentImageURLs = ["https://example.invalid/x.png"]

    // A non-image file is not an image.
    var document = Turn(id: "d", role: "user", text: "w")
    document.attachments = [MessageAttachment(id: "file-1", name: "notes.txt", isImage: false)]

    // Two identical photos in one message are two `image_url` blocks, and the
    // engine counts both — collapsing them into a set would count below what it
    // sees. No file entry matches them, so nothing dedups.
    var samePhotoTwice = Turn(id: "e", role: "user", text: "v")
    samePhotoTwice.contentImageURLs = [
        "data:image/png;base64,SAME", "data:image/png;base64,SAME",
    ]

    // The same block twice, with the file it came from: the file absorbs one
    // block and the second still counts.
    var oneFileTwoIdenticalBlocks = Turn(id: "f", role: "user", text: "u")
    oneFileTwoIdenticalBlocks.attachments = [MessageAttachment(id: "file-9", name: "shot.png", isImage: true)]
    oneFileTwoIdenticalBlocks.contentImageURLs = ["file_id://file-9", "file_id://file-9"]

    #expect(ConversationModel.imageCount(in: [sameImageTwice], outgoing: []) == 1,
            "one picture stored in both places counts once")
    #expect(ConversationModel.imageCount(in: [fileAndFileIDBlock], outgoing: []) == 1,
            "file_id:// content block dedups against the file entry")
    #expect(ConversationModel.imageCount(in: [remoteImage], outgoing: []) == 1,
            "non-data image_url blocks are counted")
    #expect(ConversationModel.imageCount(in: [document], outgoing: []) == 0)
    #expect(ConversationModel.imageCount(in: [samePhotoTwice], outgoing: []) == 2,
            "two identical image blocks in one message are two images")
    #expect(ConversationModel.imageCount(in: [oneFileTwoIdenticalBlocks], outgoing: []) == 2,
            "a file dedups one matching block, not every copy of it")
    #expect(ConversationModel.imageCount(
        in: [sameImageTwice, fileAndFileIDBlock, remoteImage, document], outgoing: []) == 3)

    let one = ConversationModel.PendingAttachment(
        id: "f-1", name: "a.png", mimeType: "image/png", data: Data([0xFF]))
    let two = ConversationModel.PendingAttachment(
        id: "f-2", name: "b.png", mimeType: "image/png", data: Data([0xFF]))
    let textFile = ConversationModel.PendingAttachment(
        id: "f-3", name: "notes.txt", mimeType: "text/plain", data: Data())
    #expect(ConversationModel.imageCount(in: [sameImageTwice], outgoing: [one, two, textFile]) == 3,
            "history plus the images the message being sent adds")
}

// MARK: - send

@Test @MainActor func sendIsRefusedWhenTheBranchWouldCrossTheImageCap() async throws {
    let transport = ScriptedTransport()
    // Each test seeds a different history under its own chat id: the loaded
    // detail is cached on disk under `chat-<id>`, and sharing one id between
    // tests that seed 50 vs 51 images makes the cache order-dependent.
    let conversation = makeConversation(chatID: "chat-budget-refuse", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-refuse",
                                                   images: ConversationModel.maxImagesPerRequest)
    await conversation.load()
    #expect(conversation.turns.count == 2 * ConversationModel.maxImagesPerRequest,
            "the seeded branch did not load")

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "one.png", mimeType: "image/png")
    try await waitUntilBudget { conversation.attachments.count == 1 }
    conversation.draft = "and this one?"
    conversation.send()
    // Give a wrongly-started run a chance to put anything on the wire.
    try await Task.sleep(for: .milliseconds(300))

    let message = try #require(conversation.error)
    #expect(message.contains("\(ConversationModel.maxImagesPerRequest + 1)"),
            "the refusal has to name the actual count: \(message)")
    #expect(message.contains("\(ConversationModel.maxImagesPerRequest)"),
            "and the cap: \(message)")
    #expect(message.lowercased().contains("start a new chat"),
            "and the only way out: \(message)")
    #expect(transport.completionBodies.isEmpty, "a refused send must not reach the server")
    #expect(conversation.phase == .ready)
    // Nothing was consumed, so nothing has to be restored: the composer keeps
    // its text and its picture.
    #expect(conversation.draft == "and this one?")
    #expect(conversation.attachments.count == 1)
}

@Test @MainActor func sendIsAllowedAtExactlyTheImageCap() async throws {
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: "chat-budget-exact", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-exact",
                                                   images: ConversationModel.maxImagesPerRequest)
    await conversation.load()

    conversation.draft = "text only, exactly at the cap"
    conversation.send()
    try await transport.awaitCompletion()
    #expect(conversation.error == nil)
    #expect(transport.completionBodies.count == 1)
}

@Test @MainActor func photosStillUploadingCountAgainstTheCap() async throws {
    // The window the composer cannot see: photos picked, visible, and not yet
    // in `attachments` because the upload has not answered. Pressing send inside
    // it used to count nothing and put the whole batch on the wire.
    let transport = HangingTransport(hangUploads: true)
    let conversation = makeConversation(chatID: nil, transport: transport)
    for i in 0...ConversationModel.maxImagesPerRequest {
        conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "p\(i).png", mimeType: "image/png")
    }
    // Deliberately no wait for the uploads — that is the point of the test.
    conversation.draft = "all of these"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))

    #expect(conversation.attachments.isEmpty, "the uploads never answered")
    let message = try #require(conversation.error)
    #expect(message.contains("\(ConversationModel.maxImagesPerRequest + 1) images"),
            "the in-flight uploads have to be in the projected count: \(message)")
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.phase == .ready)
    #expect(conversation.draft == "all of these")
}

@Test @MainActor func aBlindModelRefusesPhotosStillUploading() async throws {
    // The blind guard counts the same outgoing set the cap guard counts: a
    // photo still on the wire is an outgoing photo. The attach busy-guard is
    // not in play here — uploads do not make the phase busy — so the send
    // reaches the guard and the refusal is the blind one, not a cap hit.
    let transport = HangingTransport(hangUploads: true)
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-deep", caps: ["vision": false])],
        client: OWUIClient(server: testServer(), transport: transport),
        hub: ChatEventHub(server: testServer()))
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "p.png", mimeType: "image/png")
    #expect(conversation.phase == .ready, "uploads in flight do not make the phase busy")
    conversation.draft = "look at this"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))

    let message = try #require(conversation.error)
    #expect(message.contains("can't see images"), "\(message)")
    #expect(transport.completionBodies.isEmpty, "a refused send must not post")
    #expect(conversation.phase == .ready)
    #expect(conversation.draft == "look at this", "nothing was consumed")
}

@Test @MainActor func aTextOnlySendInAnOverCapBranchIsRefusedToo() async throws {
    // No text-only bypass: the history alone exceeds the cap, because the
    // server rebuilds the engine's messages from the persisted tree — the
    // outgoing `messages` are not where the images come from.
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: "chat-budget-overcap-text", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-overcap-text",
                                                   images: ConversationModel.maxImagesPerRequest + 1)
    await conversation.load()

    conversation.draft = "just a question"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))

    #expect(conversation.error != nil)
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.phase == .ready)
}

@Test @MainActor func aFreshChatWithTooManyAttachmentsIsRefusedBeforeTheChatIsCreated() async throws {
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: nil, transport: transport)
    for i in 0...ConversationModel.maxImagesPerRequest {
        conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "p\(i).png", mimeType: "image/png")
    }
    try await waitUntilBudget(timeout: .seconds(5)) {
        conversation.attachments.count == ConversationModel.maxImagesPerRequest + 1
    }
    conversation.draft = "all of these"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))

    #expect(conversation.error != nil)
    #expect(!transport.paths.contains { $0.hasSuffix("/chats/new") },
            "the refusal comes before the chat is created: \(transport.paths)")
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.phase == .ready)
    #expect(conversation.draft == "all of these")
}

// MARK: - regenerate

@Test @MainActor func regenerateIsAllowedAtExactlyTheImageCap() async throws {
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: "chat-budget-regen-exact", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-regen-exact",
                                                   images: ConversationModel.maxImagesPerRequest)
    await conversation.load()
    #expect(conversation.turns.count == 2 * ConversationModel.maxImagesPerRequest)

    conversation.regenerate()
    try await transport.awaitCompletion()
    #expect(conversation.error == nil)
    #expect(transport.completionBodies.count == 1)
}

@Test @MainActor func regenerateIsRefusedWithoutTruncatingTheBranch() async throws {
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: "chat-budget-regen-refuse", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-regen-refuse",
                                                   images: ConversationModel.maxImagesPerRequest + 1)
    await conversation.load()
    let before = conversation.turns.count
    #expect(before == 2 * (ConversationModel.maxImagesPerRequest + 1))

    conversation.regenerate()
    try await Task.sleep(for: .milliseconds(300))

    #expect(conversation.error != nil)
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.turns.count == before,
            "a refused regenerate must not have eaten the answer it was only meant to re-run")
    #expect(conversation.phase == .ready)
}

// MARK: - edit

@Test @MainActor func editIsAllowedAtExactlyTheImageCap() async throws {
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: "chat-budget-edit-exact", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-edit-exact",
                                                   images: ConversationModel.maxImagesPerRequest)
    await conversation.load()

    conversation.edit(messageID: "user-1", text: "still exactly at the cap")
    try await transport.awaitCompletion()
    #expect(conversation.error == nil)
    #expect(transport.completionBodies.count == 1)
    #expect(conversation.turns.first?.text == "still exactly at the cap")
}

@Test @MainActor func editIsRefusedBeforeTouchingTheServerOrTheTranscript() async throws {
    let transport = ScriptedTransport()
    let conversation = makeConversation(chatID: "chat-budget-edit-refuse", transport: transport)
    transport.chatDetailOverride = imageChatDetail(chatID: "chat-budget-edit-refuse",
                                                   images: ConversationModel.maxImagesPerRequest + 1)
    await conversation.load()
    let before = conversation.turns.count

    conversation.edit(messageID: "user-1", text: "actually: the first picture again")
    try await Task.sleep(for: .milliseconds(300))

    #expect(conversation.error != nil)
    #expect(!transport.paths.contains { $0.contains("/messages/user-1") },
            "the refusal comes before the updateMessage call: \(transport.paths)")
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.turns.count == before)
    #expect(conversation.turns.first?.text == "pic 1", "the local text was not rewritten either")
    #expect(conversation.phase == .ready)
}
