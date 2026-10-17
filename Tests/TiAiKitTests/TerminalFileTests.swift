import Foundation
import Testing
@testable import TiAiKit

/// The `display_file` shape is not obvious: the call and its result are two
/// entries in `output` joined by `call_id`, and the result is JSON wrapped in a
/// string inside an `input_text` part. Pinned against the real record from a chat
/// where the model built a PDF with weasyprint in its terminal.
/// Builds a stored message the way the server stores one.
private func decode(output: [JSONValue]) throws -> ChatMessage {
    let body: [String: JSONValue] = [
        "id": .string("m1"), "role": .string("assistant"),
        "content": .string("done"), "done": .bool(true), "output": .array(output),
    ]
    return try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(body))
}

@Test func filesTheModelOfferedFromItsTerminalAreVisible() throws {
    let meta = """
    {"path":"/home/user/Berlin_Daytime_Plan.pdf","exists":true,"type":"file",\
    "source":"open_terminal","terminal_selector":"sandbox","terminal_id":"sandbox",\
    "session_id":"314cbd16","full_path":"/home/user/Berlin_Daytime_Plan.pdf",\
    "name":"Berlin_Daytime_Plan.pdf","mime_type":"application/pdf",\
    "content_type":"application/pdf"}
    """
    // The arguments arrive as a JSON string, not an object.
    let args = "{\"path\":\"/home/user/Berlin_Daytime_Plan.pdf\"}"
    let output: [JSONValue] = [
        .object([
            "type": .string("function_call"), "name": .string("display_file"),
            "call_id": .string("c1"),
            "arguments": .string(args),
        ]),
        .object([
            "type": .string("function_call_output"), "call_id": .string("c1"),
            "output": .array([.object([
                "type": .string("input_text"),
                "text": .string(meta),
            ])]),
        ]),
    ]
    let message = try decode(output: output)
    let files = message.terminalFiles

    #expect(files.count == 1)
    let file = try #require(files.first)
    #expect(file.name == "Berlin_Daytime_Plan.pdf")
    #expect(file.path == "/home/user/Berlin_Daytime_Plan.pdf")
    #expect(file.selector == "sandbox")
    #expect(file.mimeType == "application/pdf")
    #expect(file.extension == "pdf")
}

/// A model that claims a file it never wrote must not offer a card for it.
@Test func aFileThatDoesNotExistIsNotOffered() throws {
    func json(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }
    let output: [JSONValue] = [
        .object([
            "type": .string("function_call"), "name": .string("display_file"),
            "call_id": .string("c1"),
            "arguments": .string("{\"path\":\"/home/user/ghost.pdf\"}"),
        ]),
        .object([
            "type": .string("function_call_output"), "call_id": .string("c1"),
            "output": .array([.object([
                "type": .string("input_text"),
                "text": .string("{\"path\":\"/home/user/ghost.pdf\",\"exists\":false}"),
            ])]),
        ]),
    ]
    let message = try decode(output: output)
    #expect(message.terminalFiles.isEmpty)
}

/// Other tool calls must not be mistaken for file offers.
@Test func otherToolCallsOfferNoFiles() throws {
    let output: [JSONValue] = [
        .object([
            "type": .string("function_call"), "name": .string("run_command"),
            "call_id": .string("c1"), "arguments": .string("{\"command\":\"ls\"}"),
        ]),
    ]
    let message = try decode(output: output)
    #expect(message.terminalFiles.isEmpty)
}

/// The PDF writer answers with a markdown link to `/files/{id}/content`. Those
/// routes need the app's token, so the link cannot be left for the browser.
@Test func fileLinksAreLiftedOutOfTheAnswer() {
    let text = """
    Done! Your PDF is ready.

    [\u{2B07}\u{FE0F} Download Smoke_Test.pdf](/api/v1/files/d1ce2b39-207a/content)
    """
    let found = FileLink.extract(text)
    #expect(found.links.count == 1)
    #expect(found.links.first?.id == "d1ce2b39-207a")
    // The label keeps its glyph; only the variation selector is dropped. It is
    // the model's wording, and a card that renames the file it offers is worse
    // than one that shows an emoji the simulator cannot draw.
    #expect(found.links.first?.name == "\u{2B07} Download Smoke_Test.pdf")
    // The link is gone from the prose, so it is not drawn twice.
    #expect(!found.text.contains("/api/v1/files/"))
    #expect(found.text.contains("Done!"))
}

/// An absolute URL to the same route is the same file.
@Test func absoluteFileLinksAreFoundToo() {
    let found = FileLink.extract(
        "see [x](https://chat.example/api/v1/files/abc123/content)")
    #expect(found.links.first?.id == "abc123")
}

/// Ordinary links must be left alone for the browser.
@Test func ordinaryLinksAreLeftAlone() {
    let text = "Read [the docs](https://example.com/a) for more."
    let found = FileLink.extract(text)
    #expect(found.links.isEmpty)
    #expect(found.text.contains("[the docs](https://example.com/a)"))
}
