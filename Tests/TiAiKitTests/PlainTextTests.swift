import Foundation
import Testing
@testable import TiAiKit

@Test func copyStripsTheMarkupAndKeepsTheSentence() {
    let md = """
    ## Plan

    You should **definitely** try the *museum*, it is `great`.

    1. First stop
    2. Second stop
    """
    #expect(TextSanitizer.plain(md) == """
    Plan

    You should definitely try the museum, it is great.

    1. First stop
    2. Second stop
    """)
}

/// A list is still a list when it is pasted somewhere else.
@Test func bulletsSurviveAsBullets() {
    let md = "- one\n* two\n+ three"
    #expect(TextSanitizer.plain(md) == "- one\n- two\n- three")
}

/// Inside a fence the characters are the content, so only the fence goes.
@Test func codeKeepsItsOwnFormatting() {
    let md = """
    ```python
    def f(x):   # spaced on purpose
        return  ** 2
    ```
    """
    #expect(TextSanitizer.plain(md) == "def f(x):   # spaced on purpose\n    return  ** 2")
}

/// A copied sentence that loses where the link went is missing half of itself.
@Test func linksKeepTheirDestination() {
    #expect(
        TextSanitizer.plain("See [the docs](https://ex.am/a) now.") == "See the docs (https://ex.am/a) now.")
    #expect(
        TextSanitizer.plain("See [https://ex.am/a](https://ex.am/a) now.") == "See https://ex.am/a now.")
}

@Test func rulesAndBlankRunsDoNotComeAlong() {
    let md = "one\n\n\n\n---\n\ntwo"
    #expect(TextSanitizer.plain(md) == "one\n\ntwo")
}
