import XCTest

/// Does the system prompt actually change the answer?
///
/// The unit tests prove the message is on the wire. This proves the model obeys
/// it, against whatever server the simulator is signed into — the only way to
/// catch "the field saves, the request carries it, and the answer is unchanged".
@MainActor
final class SystemPromptLiveTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The dump lands in the simulator's own /tmp, readable from the Mac, so
        // the request body can be read back instead of inferred from an answer.
        app.launchEnvironment["TIAI_DEBUG_DUMP"] = "/tmp/tiai-dump"
        app.launch()
        if app.secureTextFields.count > 0 {
            throw XCTSkip("not signed in on this simulator")
        }
        _ = app.buttons["drawerToggle"].waitForExistence(timeout: 15)
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.main.run(until: .now + seconds)
    }

    /// Types the prompt the way a person does, then asks a question in a fresh
    /// chat. Writing the plist directly would test less: it skips the settings
    /// screen, the store and the per-host key, which is where the wiring breaks.
    private func setSystemPrompt(_ text: String) throws {
        tap("drawerToggle")
        settle()
        let settings = app.buttons.matching(
            NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 6), "no Settings in the drawer")
        settings.tap()
        settle(1.5)
        let field = app.textFields["systemPromptField"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "no system prompt field")
        field.tap()
        settle(0.6)
        field.typeText(text)
        settle(0.8)
        app.swipeDown()  // drop the keyboard
        tap("Done")
        settle(1.2)
    }

    func testSystemPromptReachesTheModel() throws {
        try setSystemPrompt("Always address me as sir in every answer.")

        // A fresh chat: a prompt only governs what it is told at the start.
        tap("newChat")
        settle()

        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer on screen")
        composer.tap()
        settle(0.8)
        composer.typeText("What is the capital of France?")
        settle(0.8)
        XCTAssertEqual(composer.value as? String, "What is the capital of France?",
                       "the text never reached the composer")

        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        send.tap()

        let answers = app.textViews.matching(NSPredicate(format: "identifier == 'answerText'"))
        XCTAssertTrue(answers.firstMatch.waitForExistence(timeout: 120),
                      "no answer came back at all")
        // Read again until it stops growing, so a mid-stream fragment is not
        // mistaken for the whole reply.
        // A UITextView publishes its text as `value`; `label` is empty unless a
        // delegate set one, and reading only the label made a real answer look
        // like no answer at all.
        func text(_ view: XCUIElement) -> String {
            let value = view.value as? String ?? ""
            return value.isEmpty ? view.label : value
        }
        var last = ""
        for _ in 0..<40 {
            settle(2)
            let text = text(answers.element(boundBy: answers.count - 1))
            if text == last, !text.isEmpty { break }
            last = text
        }
        let answer = text(answers.element(boundBy: answers.count - 1))
        print("ANSWER_BEGIN[\(answer)]ANSWER_END")
        XCTAssertTrue(answer.lowercased().contains("sir"),
                      "the system prompt never reached the model. Answer was: \(answer)")
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        guard button.waitForExistence(timeout: 8) else { return }
        button.tap()
    }
}
