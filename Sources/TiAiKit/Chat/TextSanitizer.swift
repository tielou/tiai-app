import Foundation

/// Characters that arrive in chat content and have no glyph.
///
/// The web client stores inline chips — an attached file, a knowledge mention —
/// as U+FFFC OBJECT REPLACEMENT CHARACTER inside the message text. On the web it
/// is replaced by the chip before rendering; a native client that renders the
/// raw string shows a hollow box in the middle of a sentence, which looks like a
/// font bug and is really a placeholder nobody substituted.
///
/// Stripping them is safe because they carry no readable content: what is left is
/// exactly what the user sees in the browser.
///
/// Worth knowing before chasing a box as a bug: a box can also mean the font
/// cannot draw a character that *is* real content. This simulator renders every
/// emoji as a hollow box — Safari in the same simulator does it too, and so does
/// a plain text field, which is the fastest way to tell the two cases apart.
/// Nothing in this file can fix that, and nothing needs to.
public enum TextSanitizer {
    /// Codepoints that render as a missing-glyph box or as nothing at all.
    ///
    /// Deliberately does *not* include U+200D (zero-width joiner) or U+200C:
    /// those are what hold multi-scalar emoji together, so a 🧑‍💻 or a flag
    /// falls apart into fragments if you scrub them. A stray joiner in plain
    /// text is invisible; a broken emoji is very visible.
    static let invisible: Set<Unicode.Scalar> = [
        "\u{FFFC}",  // object replacement — inline chips from the web client
        "\u{FFFD}",  // replacement character from a bad decode
        "\u{FFFE}", "\u{FFFF}",
        "\u{200B}",  // zero-width space
        "\u{2060}",  // word joiner
    ]

    /// True for the private use areas, where a model can emit something no font
    /// on this device has ever seen.
    static func privateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value) || (0xF0000...0xFFFFD).contains(scalar.value)
            || (0x100000...0x10FFFD).contains(scalar.value)
    }

    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Fast exit: the overwhelming majority of messages contain none of these,
        // and this runs on every keystroke of a streaming answer.
        guard text.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{FFFC}\u{FFFD}\u{FFFE}\u{FFFF}\u{200B}\u{2060}")) != nil
            || text.unicodeScalars.contains(where: privateUse)
        else { return text }

        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if invisible.contains(scalar) || privateUse(scalar) { continue }
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Plain text for copying

    /// Markdown turned into text a person would want pasted somewhere.
    ///
    /// The copy button used to hand over the answer exactly as it arrived, so
    /// pasting into Mail or Notes carried the `##`, the `**` and the fences along
    /// with the sentence they were formatting. Code is the exception: inside a
    /// fence the characters *are* the content, so the fence markers go and the
    /// code stays untouched.
    public static func plain(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { out.append(String(line)); continue }

            var text = String(line)
            switch trimmed {
            case "", "---", "***", "___":
                // Rules carry nothing once the line breaks are gone.
                out.append("")
                continue
            default: break
            }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#") {
                let level = trimmed[..<hashes].count
                if (1...6).contains(level) { text = String(trimmed[hashes...]) }
            } else if trimmed.hasPrefix(">") {
                text = String(trimmed.drop { $0 == ">" || $0 == " " })
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                // Normalised rather than dropped: a list that pastes as a wall of
                // prose is worse than one that pastes as a list.
                text = "- " + inline(String(trimmed.dropFirst(2)))
                out.append(text)
                continue
            }
            out.append(inline(text))
        }
        // Runs of blank lines are a formatting accident more often than a choice.
        var collapsed: [String] = []
        var blanks = 0
        for line in out {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                if blanks > 1 { continue }
            } else { blanks = 0 }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inline markup, taken out. Order matters: `**bold**` has to go before the
    /// single-star pass, or the star pass eats one of its stars.
    private static func inline(_ text: String) -> String {
        var out = text
        func strip(_ pattern: String) {
            guard let re = try? Regex(pattern) else { return }
            // The closure form, not `with: "$1"`: the string variant substitutes
            // nothing and pastes a literal `$1` into the answer.
            let replaced = try? out.replacing(re) { match -> String in
                guard let group = match.output[1].substring else {
                    return String(match.output[0].substring ?? "")
                }
                return String(group)
            }
            if let replaced { out = replaced }
        }
        // [label](url) — kept as "label (url)" when they differ, because a copied
        // sentence that loses where the link went is missing half of itself.
        if let links = try? Regex(#"\[([^\]]+)\]\(([^)\s]+)\)"#) {
            out = (try? out.replacing(links) { match in
                let label = match.output[1].substring.map(String.init) ?? ""
                let url = match.output[2].substring.map(String.init) ?? ""
                return label == url ? url : "\(label) (\(url))"
            }) ?? out
        }
        strip(#"\*\*(.+?)\*\*"#)
        strip(#"__(.+?)__"#)
        strip(#"~~(.+?)~~"#)
        strip(#"\*([^*\n]+?)\*"#)
        strip(#"(?<![\w])_([^_\n]+?)_(?![\w])"#)
        strip(#"`([^`\n]+?)`"#)
        return out
    }
}
