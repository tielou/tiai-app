import XCTest

/// End-to-end driving of the real app on a real simulator.
///
/// These exist because the unit tests can only assert what a request looked like
/// or what a parser produced. The things they catch are the ones a user reports:
/// a control that renders and does nothing, a sheet that will not dismiss, a
/// gesture that is swallowed by a scroll view.
///
/// They drive whatever the app is already signed into — the session lives in the
/// keychain, so a machine that has run the app once has something to test. A
/// machine that has never signed in lands on the sign-in screen and skips,
/// rather than failing for a reason that is not the app's fault.
@MainActor
final class ConversationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // No credentials means nothing to drive. Skip rather than fail: the
        // sign-in flow is exercised by the contract tests, not here.
        if app.secureTextFields.count > 0 {
            throw XCTSkip("not signed in on this simulator")
        }
        // The first frame is the cached transcript; give the drawer a moment to
        // be tappable rather than racing the launch animation.
        _ = app.buttons["drawerToggle"].waitForExistence(timeout: 15)
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(identifier) never appeared")
        button.waitUntilHittable()
        button.tap()
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.main.run(until: .now + seconds)
    }

    func testDrawerOpensShowsTheLibraryAndCloses() {
        tap("drawerToggle")
        settle()
        let memory = app.buttons["Memory"]
        XCTAssertTrue(memory.waitForExistence(timeout: 5), "drawer did not show Memory")
        XCTAssertTrue(memory.isHittable, "drawer row is on screen but unreachable")

        // Closing is the half that broke before: the panel is always mounted and
        // driven by an offset, so a row that still exists in the tree after
        // closing is a panel that never actually left.
        tap("drawerToggle")
        settle()
        XCTAssertFalse(app.buttons["Memory"].isHittable, "drawer is still under the reader")
    }

    func testModelSheetOpensAndDismisses() {
        tap("modelChip")
        XCTAssertTrue(app.navigationBars["Select model"].waitForExistence(timeout: 5))
        // At least one model must be listed; an empty sheet was a real bug.
        XCTAssertGreaterThan(app.cells.count + app.buttons.count, 3)
        app.buttons["Close"].firstMatch.tap()
        settle()
        XCTAssertFalse(app.navigationBars["Select model"].exists, "sheet would not close")
    }

    func testAddSheetListsToolsAndDismisses() {
        tap("addToChat")
        XCTAssertTrue(app.navigationBars["Add to Chat"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        settle()
        XCTAssertFalse(app.navigationBars["Add to Chat"].exists)
    }

    func testIncognitoTogglesFromTheTopBar() throws {
        let incognito = app.buttons["incognito"]
        guard incognito.waitForExistence(timeout: 10), incognito.isHittable else {
            throw XCTSkip("no incognito control on this screen")
        }
        let before = incognito.label
        incognito.tap()
        settle(0.6)
        XCTAssertNotEqual(app.buttons["incognito"].label, before,
                          "the toggle did not change state")
    }

    /// The reason the answer is one `UITextView` rather than a stack of `Text`s.
    ///
    /// Selection scoped per block could not cross a heading or a list item, so
    /// copying a sentence that ran across one meant selecting twice and gluing
    /// the pieces together. A long press now offers the system menu over the
    /// whole answer.
    func testAnswerOffersSystemSelection() throws {
        try openSomeChat()
        // A UITextView is its own accessibility element, so the identifier lands
        // on the text view rather than on the SwiftUI wrapper around it.
        let answers = app.textViews.matching(NSPredicate(format: "identifier == 'answerText'"))
        guard answers.count > 0 else { throw XCTSkip("no answer on screen to select from") }
        // The first answer is usually scrolled up under the nav bar, and a press
        // on its frame centre lands on the bar. Pick one that is on screen.
        var answer: XCUIElement?
        for i in 0..<answers.count {
            let candidate = answers.element(boundBy: i)
            if candidate.frame.minY > 160, candidate.frame.maxY < 700 { answer = candidate; break }
        }
        guard let target = answer else { throw XCTSkip("no answer fully on screen") }
        target.press(forDuration: 1.0)
        settle(1.2)
        // The callout is not in `app.buttons`: UIKit presents it in a second
        // window of its own, so the search has to cover the whole application.
        let menu = ["Copy", "Look Up", "Select All", "Share"]
        let found = menu.filter { name in
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name))
                .count > 0
        }
        XCTAssertTrue(!found.isEmpty, "long-press produced no selection menu")
    }

    /// A chat opened from the drawer must show its transcript, not the greeting.
    func testOpeningAChatShowsItsMessages() throws {
        try openSomeChat()
        XCTAssertTrue(app.textViews["answerText"].firstMatch.waitForExistence(timeout: 10),
                      "opened a chat and got the empty screen")
    }

    private func openSomeChat() throws {
        tap("drawerToggle")
        settle()
        // The drawer lists recents under a "Recents" heading; the first row
        // after it is a real chat on any account with history.
        // The drawer rows are buttons, not cells: the drawer is a panel, not a
        // navigation stack, so it drives selection through a closure.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow'"))
        guard rows.count > 0 else {
            throw XCTSkip("no chats to open on this account")
        }
        let first = rows.firstMatch
        first.waitUntilHittable()
        first.tap()
        settle(1.5)
    }
}

private extension XCUIElement {
    func waitUntilHittable(timeout: TimeInterval = 5) {
        let deadline = Date.now + timeout
        while !isHittable && Date.now < deadline {
            RunLoop.main.run(until: .now + 0.2)
        }
    }
}
