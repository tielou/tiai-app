import Foundation
import Testing

@testable import TiAiKit

// Issue #2: a long image-heavy chat used to dead-end once the image guard
// blocked sends. The guard now also offers a trim: the oldest persisted images
// are replaced (server-side, via updateMessage) with a text placeholder so the
// chat keeps working. These tests drive the offer, the trim mechanics, and the
// "stop as soon as it fits" rule against a shrunk cap knob.

@MainActor
private func waitTrim(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw TrimProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum TrimProbeFailure: Error { case timeout }

private func trimServer() -> Server {
    Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
}

/// A chat detail whose loaded branch contains `images` user turns, each with
/// exactly one unique `data:` image and a text part, plus an assistant answer
/// after it. `imageOnlyAt` makes those user messages carry *no* text part
/// (image blocks alone); `extraBlockAt` adds a distinctive non-image block to
/// those user messages so the "non-image content is preserved verbatim" rule
/// can be pinned.
private func trimChatDetail(
    chatID: String,
    images: Int,
    imageOnlyAt: Set<Int> = [],
    extraBlockAt: Set<Int> = []
) -> Data {
    var entries: [String] = []
    var previousAssistant: String?
    var lastID = ""
    for i in 1...max(images, 1) {
        let user = "user-\(i)"
        let assistant = "assistant-\(i)"
        let userParent = previousAssistant.map { "\"\($0)\"" } ?? "null"
        var blocks: [String] = []
        if !imageOnlyAt.contains(i) {
            blocks.append("{\"type\":\"text\",\"text\":\"pic \(i)\"}")
        }
        blocks.append(
            "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,IMG\(i)\"}}")
        if extraBlockAt.contains(i) {
            blocks.append("{\"type\":\"custom_keep\",\"keep\":\(i)}")
        }
        entries.append(
            """
            "\(user)":{"id":"\(user)","role":"user","done":true,"parentId":\(userParent),"childrenIds":["\(assistant)"],\
            "content":[\(blocks.joined(separator: ","))]}
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
private func makeTrimConversation(
    chatID: String?, transport: any APITransport, cap: Int? = nil
) -> ConversationModel {
    let conversation = ConversationModel(
        chatID: chatID,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: trimServer(), transport: transport),
        hub: ChatEventHub(server: trimServer()))
    conversation.maxImagesPerRequestOverride = cap
    return conversation
}

/// The JSON body of one recorded `updateMessage` POST.
private func updateBody(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The `content` of an update body as blocks, whether the server-side shape was
/// a bare string or a block array.
private func contentBlocks(_ body: [String: Any]) -> [[String: Any]] {
    (body["content"] as? [[String: Any]]) ?? []
}

private func contentText(_ body: [String: Any]) -> String? {
    body["content"] as? String
}

// MARK: - (a) the offer

@Test @MainActor func overCapSendOffersTrimWithOldestTargets() async throws {
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-offer", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(chatID: "chat-trim-offer", images: 5)
    await conversation.load()
    #expect(conversation.turns.count == 10, "the seeded branch did not load")

    conversation.draft = "one more question"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))

    // The send is still blocked — the engine would 500 otherwise.
    #expect(conversation.error != nil)
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.phase == .ready)

    let offer = try #require(conversation.imageTrim)
    // 5 images in chat, cap 3 → the two oldest must go.
    #expect(offer.imagesInChat == 5)
    #expect(offer.cap == 3)
    #expect(offer.dropTotal == 2)
    #expect(offer.targets.map(\.messageID) == ["user-1", "user-2"],
            "targets are oldest-first: \(offer.targets.map(\.messageID))")
    #expect(offer.targets.allSatisfy { $0.dropCount == 1 })
    // The confirmation preview names each dropped image.
    #expect(offer.targets.allSatisfy { !$0.preview.isEmpty })
    #expect(offer.targets[0].preview.contains("pic 1"))
    #expect(offer.targets[1].preview.contains("pic 2"))
    #expect(offer.confirmationMessage.contains("pic 1"))
    #expect(offer.confirmationMessage.contains("pic 2"))
}

@Test @MainActor func offerCountsTheOutgoingImageAgainstTheCap() async throws {
    // The projection the offer must close includes the pending send: 5 in chat
    // + 1 being sent, cap 3 → three oldest must go, not two.
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-offer-outgoing", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(chatID: "chat-trim-offer-outgoing", images: 5)
    await conversation.load()

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "one.png", mimeType: "image/png")
    try await waitTrim { conversation.attachments.count == 1 }
    conversation.draft = "and this one?"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))

    let offer = try #require(conversation.imageTrim)
    #expect(offer.imagesInChat == 6)
    #expect(offer.dropTotal == 3)
    #expect(offer.targets.map(\.messageID) == ["user-1", "user-2", "user-3"])
}

// MARK: - (b) the trim: exactly the targets, oldest-first, stops when it fits

@Test @MainActor func trimUpdatesExactlyTheTargetedMessagesOldestFirst() async throws {
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-run", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(chatID: "chat-trim-run", images: 5)
    await conversation.load()

    conversation.draft = "one more question"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    #expect(conversation.imageTrim != nil)

    await conversation.trimOldestImagesToFit()

    // Exactly two updateMessage calls — the two oldest image messages — and
    // not one more: the trim stops as soon as the projection fits.
    let updatePaths = transport.paths.filter {
        $0.hasPrefix("/api/v1/chats/chat-trim-run/messages/")
    }
    #expect(updatePaths == [
        "/api/v1/chats/chat-trim-run/messages/user-1",
        "/api/v1/chats/chat-trim-run/messages/user-2",
    ], "got: \(updatePaths)")
    #expect(transport.messageUpdateBodies.count == 2)

    // Each body: placeholder content and an explicit empty `files` array —
    // the server overwrites the row with exactly what the body says, so an
    // omitted `files` is the silent-delete trap; the empty array is the
    // explicit "no files".
    for body in transport.messageUpdateBodies {
        let json = try updateBody(body)
        let files = try #require(json["files"] as? [Any])
        #expect(files.isEmpty, "files must be the explicit empty array")
        let blocks = contentBlocks(json)
        #expect(!blocks.isEmpty)
        let texts = blocks.compactMap { $0["text"] as? String }
        #expect(texts.contains(ConversationModel.imageTrimPlaceholder))
        #expect(!blocks.contains { ($0["type"] as? String) == "image_url" },
                "no image blocks survive the trim")
    }

    // (d) after the trim the guard no longer refuses, and the send proceeds.
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    #expect(conversation.error == nil)
    #expect(conversation.imageTrim == nil)
    #expect(transport.completionBodies.count == 1)

    // The local state converged with the server: the trimmed turns show the
    // placeholder and carry no images any more.
    let trimmed = conversation.turns.filter {
        $0.text.contains(ConversationModel.imageTrimPlaceholder)
    }
    #expect(trimmed.count == 2)
    #expect(trimmed.allSatisfy { $0.contentImageURLs.isEmpty && $0.attachments.isEmpty })
}

// MARK: - (c) text and non-image blocks survive verbatim

@Test @MainActor func trimPreservesTextAndNonImageBlocks() async throws {
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-keep", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(
        chatID: "chat-trim-keep", images: 5, extraBlockAt: [1])
    await conversation.load()

    conversation.draft = "one more question"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    await conversation.trimOldestImagesToFit()

    #expect(transport.messageUpdateBodies.count == 2)
    let first = try updateBody(transport.messageUpdateBodies[0])
    let blocks = contentBlocks(first)
    // The text part is preserved verbatim, the placeholder is added, and the
    // distinctive non-image block survives untouched.
    let texts = blocks.compactMap { $0["text"] as? String }
    #expect(texts.contains("pic 1"))
    #expect(texts.contains(ConversationModel.imageTrimPlaceholder))
    let kept = blocks.first { ($0["type"] as? String) == "custom_keep" }
    #expect(kept?["keep"] as? Int == 1, "non-image blocks must be preserved verbatim")
    // The second trimmed message had no extra block — only text + placeholder.
    let second = try updateBody(transport.messageUpdateBodies[1])
    #expect(contentBlocks(second).compactMap { $0["text"] as? String }.contains("pic 2"))
    #expect(!contentBlocks(second).contains { ($0["type"] as? String) == "custom_keep" })
}

// MARK: - (e) an image-only message becomes the placeholder alone

@Test @MainActor func imageOnlyTrimmedMessageBecomesPlaceholderAlone() async throws {
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-only", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(
        chatID: "chat-trim-only", images: 5, imageOnlyAt: [1])
    await conversation.load()

    conversation.draft = "one more question"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    await conversation.trimOldestImagesToFit()

    #expect(transport.messageUpdateBodies.count == 2)
    let first = try updateBody(transport.messageUpdateBodies[0])
    // No text existed, so the content is the placeholder and nothing else.
    if let text = contentText(first) {
        #expect(text == ConversationModel.imageTrimPlaceholder)
    } else {
        let blocks = contentBlocks(first)
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == ConversationModel.imageTrimPlaceholder)
    }
}

// MARK: - (f) nothing is touched at or below the cap

@Test @MainActor func noTrimOfferOrCallsAtOrBelowCap() async throws {
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-below", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(chatID: "chat-trim-below", images: 3)
    await conversation.load()

    conversation.draft = "exactly at the cap"
    conversation.send()
    try await transport.awaitCompletion()
    #expect(conversation.error == nil)
    #expect(conversation.imageTrim == nil)
    #expect(transport.completionBodies.count == 1)

    // A trim called anyway is a no-op: nothing to drop, nothing on the wire.
    await conversation.trimOldestImagesToFit()
    #expect(transport.messageUpdateBodies.isEmpty)
    #expect(conversation.imageTrim == nil)
}

// MARK: - failure mid-trim

@Test @MainActor func failureMidTrimStopsWithPartialTrimAndRecomputedOffer() async throws {
    let transport = ScriptedTransport()
    let conversation = makeTrimConversation(
        chatID: "chat-trim-fail", transport: transport, cap: 3)
    transport.chatDetailOverride = trimChatDetail(chatID: "chat-trim-fail", images: 5)
    await conversation.load()

    conversation.draft = "one more question"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    #expect(conversation.imageTrim?.dropTotal == 2)

    // The first update lands, the second one fails.
    transport.messageUpdateFailureAfter = 1
    await conversation.trimOldestImagesToFit()

    // Error surfaced through the existing channel; the applied trim stays
    // applied (each update is independently consistent) and the offer is
    // recomputed against the new state: one image down, one more to go.
    #expect(conversation.error != nil)
    #expect(transport.messageUpdateBodies.count == 1)
    #expect(conversation.turns[0].contentImageURLs.isEmpty)
    #expect(conversation.turns[2].contentImageURLs.isEmpty == false)
    let offer = try #require(conversation.imageTrim)
    #expect(offer.imagesInChat == 4)
    #expect(offer.dropTotal == 1)
    #expect(offer.targets.map(\.messageID) == ["user-2"])
}
