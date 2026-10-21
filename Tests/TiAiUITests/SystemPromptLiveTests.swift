import XCTest

/// Does the system prompt actually change the answer?
///
/// The unit tests prove the message is on the wire. This proves the model obeys
/// it, against whatever server the simulator is signed into — which is the only
/// way to catch "the field saves, the request carries it, and the answer is
/// unchanged".
@MainActor
final class SystemPromptLiveTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        if app.secureTextFields.count > 0 {
            throw XCTSkip("not signed in on this simulator")
        }
        _ = app.buttons["drawerToggle"].waitForExistence(timeout: 15)
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.main.run(until: .now + seconds)
    }

    func testSystemPromptReachesTheModel() throws {
        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer on screen")
        composer.tap()
        settle(0.6)
        composer.typeText("What is the capital of France? One short sentence.\n")

        let answers = app.textViews.matching(NSPredicate(format: "identifier == 'answerText'"))
        XCTAssertTrue(answers.firstMatch.waitForExistence(timeout: 90),
                      "no answer came back at all")
        // Wait for the stream to finish rather than reading mid-sentence.
        let deadline = Date().addingTimeInterval(90)
        var last = ""
        while Date() < deadline {
            let text = answers.element(boundBy: answers.count - 1).label
            if text == last, !text.isEmpty { break }
            last = text
            settle(2)
        }
        let answer = answers.element(boundBy: answers.count - 1).label
        print("ANSWER_BEGIN[\(answer)]ANSWER_END")
        XCTAssertTrue(answer.lowercased().contains("sir"),
                      "the system prompt never reached the model. Answer was: \(answer)")
    }
}
