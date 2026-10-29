import XCTest

/// End-to-end proof for issue #2 against the real server.
///
/// A seeded chat (55 image-bearing turns, one of them also carrying a PDF)
/// lives on the signed-in server; the seed id is read from
/// `/tmp/tiai_trim_chat.txt`, written by the seeding script. The test drives
/// the exact dead-end the issue describes — send is refused for being over the
/// image budget — and then takes the way out the fix added: the banner, the
/// confirmation, the server-side trim, and a send that finally goes through.
///
/// Skips itself when the seed file is absent or the simulator is signed out,
/// same policy as the other live suites.
@MainActor
final class ImageTrimLiveTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let id = try? String(contentsOfFile: "/tmp/tiai_trim_chat.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw XCTSkip("no seeded trim chat (/tmp/tiai_trim_chat.txt)")
        }
        app = XCUIApplication()
        app.launchEnvironment["TIAI_OPEN_CHAT"] = id
        app.launch()
        if app.secureTextFields.count > 0 {
            throw XCTSkip("not signed in on this simulator")
        }
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.main.run(until: .now + seconds)
    }

    func testOverCapSendOffersTrimAndTrimUnblocksSend() throws {
        // Open on the seeded chat: wait for an answer bubble to render.
        XCTAssertTrue(app.textViews.matching(
            NSPredicate(format: "identifier == 'answerText'")).firstMatch
            .waitForExistence(timeout: 30), "seeded chat did not open")

        // 1. A send over the image budget must be refused AND offer the trim.
        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        settle(0.6)
        composer.typeText("hello after the images")
        app.buttons["sendButton"].tap()
        let trimButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(trimButton.waitForExistence(timeout: 15),
                      "over-cap send did not offer a trim")

        // 2. Confirm the destructive rewrite. The dialog's button carries the
        // same label as the banner behind it, so the tap must be scoped to the
        // sheet — an unscoped firstMatch re-taps the banner and the dialog
        // never resolves.
        trimButton.tap()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 6), "confirmation dialog missing")
        sheet.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch.tap()

        // 3. The trim rewrites the oldest turns server-side; the placeholder
        // appears in the transcript once the view refreshes.
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "[image removed", "[image removed"))
            .firstMatch.waitForExistence(timeout: 30), "no placeholder after trim")

        // 4. The same send now goes through: no error banner, generation starts.
        settle(1.0)
        let composer2 = app.textFields.firstMatch
        composer2.tap()
        settle(0.6)
        composer2.typeText("second try")
        app.buttons["sendButton"].tap()
        let started = app.buttons["stopGeneration"].waitForExistence(timeout: 30)
        let offeredAgain = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch.exists
        XCTAssertFalse(offeredAgain, "send was refused for the image budget again")
        XCTAssertTrue(started, "send after trim did not start a generation")
        app.buttons["stopGeneration"].tap()  // don't burn the token on an answer
    }
}
