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
}
