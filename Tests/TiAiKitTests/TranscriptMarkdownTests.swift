import Foundation
import Testing
@testable import TiAiKit

private func turn(_ role: String, _ text: String) -> Turn {
    var t = Turn(id: role + UUID().uuidString, role: role, text: text)
    return t
}

@Test("an export reads as a document, not a dump")
func exportIsAReadableDocument() {
    let markdown = TranscriptMarkdown.render(
        title: "Berlin plan",
        turns: [turn("user", "What is worth seeing?"), turn("assistant", "Museums.")],
        model: "local-personal",
        server: URL(string: "https://chat.test"))

    #expect(markdown.contains("# Berlin plan"))
    #expect(markdown.contains("## You"))
    #expect(markdown.contains("What is worth seeing?"))
    #expect(markdown.contains("## Assistant"))
    #expect(markdown.contains("Model: local-personal"))
    #expect(markdown.contains("Server: chat.test"))
    // Plain Markdown: no HTML wrapper around the prose itself.
    #expect(!markdown.contains("<p>"))
}

@Test("empty turns do not leave empty headings behind")
func emptyTurnsAreSkipped() {
    let markdown = TranscriptMarkdown.render(
        title: "Half a run",
        turns: [turn("user", ""), turn("assistant", "")],
        model: nil,
        server: nil)
    #expect(!markdown.contains("## You"))
    #expect(!markdown.contains("## Assistant"))
}

@Test("a slash in the title cannot escape a directory")
func titleIsSafeAsAFilename() {
    let title = "a/b/../etc".replacingOccurrences(of: "/", with: "-")
    #expect(!title.contains("/"))
}
