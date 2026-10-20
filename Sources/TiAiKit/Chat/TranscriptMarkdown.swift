import Foundation

/// A whole conversation as a Markdown document.
///
/// The web UI can export; without this the only way to get a chat out of the app
/// is to select each answer and paste it somewhere, which is how a chat ends up
/// scattered across six notes. One file, one share sheet.
///
/// Deliberately plain Markdown — no HTML, no front matter — so it opens in Notes,
/// Bear, Obsidian or an email without a converter.
public enum TranscriptMarkdown {
    public static func render(
        title: String,
        turns: [Turn],
        model: String?,
        server: URL?
    ) -> String {
        var out: [String] = ["# \(title.isEmpty ? "Conversation" : title)", ""]
        var facts: [String] = []
        if let model { facts.append("Model: \(model)") }
        if let host = server?.host { facts.append("Server: \(host)") }
        facts.append("Exported: \(Self.stamp(Date.now))")
        out.append(facts.map { "> \($0)" }.joined(separator: "\n"))
        out.append("")

        for turn in turns {
            // A turn with nothing in it is a run that never produced anything;
            // writing an empty heading for it makes the document look broken.
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoning = turn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            if turn.isUser {
                if body.isEmpty { continue }
                out.append("---")
                out.append("")
                out.append("## You")
                out.append("")
                out.append(body)
                out.append("")
            } else {
                if body.isEmpty && reasoning.isEmpty { continue }
                out.append("---")
                out.append("")
                out.append("## Assistant")
                out.append("")
                if !reasoning.isEmpty {
                    out.append("<details><summary>Thoughts</summary>")
                    out.append("")
                    out.append(reasoning)
                    out.append("")
                    out.append("</details>")
                    out.append("")
                }
                out.append(body)
                out.append("")
                let sources = turn.sources.compactMap { $0.url }
                if !sources.isEmpty {
                    out.append("### Sources")
                    out.append("")
                    out.append(contentsOf: sources.map { "- \($0)" })
                    out.append("")
                }
                let files = turn.terminalFiles.map { $0.name }
                    + turn.attachments.map { $0.name }
                if !files.isEmpty {
                    out.append("### Files")
                    out.append("")
                    out.append(contentsOf: files.map { "- \($0)" })
                    out.append("")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
