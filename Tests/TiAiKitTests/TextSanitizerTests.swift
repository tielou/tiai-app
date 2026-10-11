import Foundation
import Testing

@testable import TiAiKit

/// The hollow box in the middle of a sentence is not a font problem. The web
/// client stores inline chips — an attached file, a knowledge mention — as
/// U+FFFC in the message text and substitutes the chip before rendering; a
/// native client that renders the raw string shows the placeholder.
@Test func objectReplacementCharactersAreStripped() {
    let chip = "Hello! \u{FFFC} How can I help you today?"
    #expect(TextSanitizer.clean(chip) == "Hello!  How can I help you today?")
}

@Test func realEmojiSurvive() {
    // The strip must not become a scrub: emoji are multi-scalar and the ones
    // people actually use carry skin-tone modifiers and variation selectors.
    for emoji in ["👋", "👋🏽", "\u{1F44B}\u{FE0F}", "🇩🇪", "🧑‍💻"] {
        let text = "Hello! \(emoji) How can I help you today?"
        #expect(TextSanitizer.clean(text) == text)
    }
}

@Test func zeroWidthAndPrivateUseCharactersGo() {
    #expect(TextSanitizer.clean("a\u{200B}b") == "ab")
    #expect(TextSanitizer.clean("a\u{E000}b") == "ab")
    #expect(TextSanitizer.clean("") == "")
    #expect(TextSanitizer.clean("plain text stays byte for byte") == "plain text stays byte for byte")
}

@Test func markdownKeepsEmojiItIsGiven() {
    // Guards the other half: the sanitizer is the fix, the markdown path was
    // never the problem, and it is worth having that written down somewhere
    // executable after an hour was spent suspecting it.
    let blocks = Markdown.blocks("Hello! 👋 How can I help you today?")
    #expect(blocks == [.prose("Hello! 👋 How can I help you today?")])
}

// The thinking animation's poses live in the view layer, but the thing that can
// actually be wrong about them is the selection: a pose that no run can reach,
// or one that changes while you are looking at it. Both are cheap to pin here.
@Test func everyThinkingPoseIsReachableAndStable() {
    #expect(ThinkingAnimation.poseIndex(for: "a") == ThinkingAnimation.poseIndex(for: "a"),
            "the same run id must keep the same pose, or the cat changes mid-flight")
    var reached = Set<String>()
    for index in 0..<600 { reached.insert(ThinkingAnimation.poseName(for: "run-\(index)")) }
    #expect(reached.count == ThinkingAnimation.distinctPoseCount,
            "every pose should turn up eventually; one that never does is dead code")
    for index in 0..<200 {
        #expect(ThinkingAnimation.poseIndex(for: "x\(index)") < ThinkingAnimation.poseSlotCount)
    }
}
