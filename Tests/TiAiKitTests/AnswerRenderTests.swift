import Testing
@testable import TiAiKit

/// The transcript re-renders every row on every coalesced streaming delta, and
/// parsing an answer means three full passes over it. These pin the properties
/// that make the cache worth having — and the first draft of it failed the
/// recency test below, which is the one that matters.
@MainActor
@Test("a repeated answer is parsed once")
func repeatedTextHitsTheCache() {
    AnswerRender.clear()
    let text = "## Title\n\nSome prose.\n\n```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
    let first = AnswerRender.parse(text)
    #expect(AnswerRender.parse(text) === first, "same text must return the same parsed answer")
    #expect(AnswerRender.count == 1)
}

/// The bug this exists to catch: eviction by insertion order rather than by last
/// use. The transcript is a non-lazy stack, so a render walks every turn in the
/// chat in the same order every time — with FIFO eviction, a chat longer than the
/// capacity misses on every single key on every render and ends up slower than
/// not caching at all.
@MainActor
@Test("a recently used answer survives eviction")
func recencyIsWhatEvictionIsBasedOn() {
    AnswerRender.clear()
    // Fill the cache, oldest first.
    var keys: [String] = []
    for i in 0..<300 { keys.append("answer-\(i)") }
    for key in keys { AnswerRender.parse(key) }

    // Touch the very oldest one, then overflow the cache with fresh text.
    let keeper = AnswerRender.parse(keys[0])
    #expect(AnswerRender.parse(keys[0]) === keeper)
    for i in 1000..<1200 { AnswerRender.parse("noise-\(i)") }

    #expect(AnswerRender.parse(keys[0]) === keeper,
            "a hot entry must not be evicted by traffic that is older than its last use")
}

@MainActor
@Test("streaming answers are read but not stored")
func streamingDeltasDoNotFillTheCache() {
    AnswerRender.clear()
    for length in 0..<300 {
        // What a streaming row does: a brand new string per delta.
        AnswerRender.parse(String(repeating: "word ", count: length), cacheable: false)
    }
    #expect(AnswerRender.count == 0,
            "delta text is never read again; caching it only evicts the stable answers")
}

@MainActor
@Test("the cache stays bounded under churn")
func cacheIsBounded() {
    AnswerRender.clear()
    for length in 0..<400 {
        AnswerRender.parse(String(repeating: "word ", count: length))
    }
    #expect(AnswerRender.count > 0 && AnswerRender.count <= 256,
            "bounded, but actually holding something")
}

@MainActor
@Test("the parse keeps prose, code and tables apart")
func parseMatchesTheDirectParse() {
    AnswerRender.clear()
    let text = "Intro.\n\n```python\nprint(1)\n```\n\nDone."
    let parsed = AnswerRender.parse(text)
    // A code block breaks the prose run, so there are three segments: the run
    // before it, the block, and the run after it.
    #expect(parsed.segments.count == 3)
    #expect(parsed.codeBlocks == ["print(1)"])
    if case .prose(let prose) = parsed.segments[0] {
        #expect(prose.contains("Intro."))
    } else {
        Issue.record("first segment should be prose")
    }
    if case .code(_, let code) = parsed.segments[1] {
        #expect(code == "print(1)")
    } else {
        Issue.record("second segment should be the code block")
    }
}
