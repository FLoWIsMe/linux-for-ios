import XCTest

/// End to end checks that also produce the screenshots used for the App Store listing.
/// Run with `xcodebuild test -scheme Tern -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'`.
/// Screenshots are attached to the test report; scripts/export-screenshots.sh pulls them out.
final class TernUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES", "-shell.welcomeTips", "YES", "-ui-testing"]
        app.launch()
    }

    private func terminal() -> XCUIElement {
        // SwiftTerm's view is the first scroll view on screen.
        let view = app.scrollViews.firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        return view
    }

    private func type(_ text: String) {
        let view = terminal()
        view.tap()
        app.typeText(text)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForText(_ text: String, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.containing(predicate).firstMatch
        if element.waitForExistence(timeout: timeout) { return }
        // SwiftTerm exposes its content through accessibility; fall back to the whole view's value.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = terminal().value as? String ?? ""
            if value.contains(text) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Terminal never showed \(text)")
    }

    func testPromptAppearsAndEchoWorks() {
        _ = terminal()
        type("echo tern-ui-ok\n")
        waitForText("tern-ui-ok")
        screenshot("01-terminal")
    }

    func testTabBarCreatesAndClosesTabs() {
        _ = terminal()
        app.buttons["New tab"].tap()
        XCTAssertTrue(app.buttons["Close tab"].waitForExistence(timeout: 5))
        screenshot("02-tabs")
        app.buttons["Close tab"].tap()
    }

    func testSettingsOpens() {
        _ = terminal()
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        screenshot("03-settings")
        app.buttons["Done"].tap()
    }

    func testKeysAndHostsOpen() {
        _ = terminal()
        app.buttons["More"].tap()
        app.buttons["SSH Keys"].tap()
        XCTAssertTrue(app.navigationBars["SSH Keys"].waitForExistence(timeout: 5))
        screenshot("04-keys")
        app.buttons["Done"].tap()
        app.buttons["More"].tap()
        app.buttons["Hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        screenshot("05-hosts")
        app.buttons["Done"].tap()
    }

    func testOnboardingShowsWhenNotCompleted() {
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-onboarding.completed", "NO", "-ui-testing"]
        fresh.launch()
        XCTAssertTrue(fresh.buttons["Continue"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: fresh.screenshot())
        attachment.name = "06-onboarding"
        attachment.lifetime = .keepAlways
        add(attachment)
        for _ in 0..<4 { fresh.buttons["Continue"].tap() }
        fresh.buttons["Start"].tap()
        XCTAssertTrue(fresh.scrollViews.firstMatch.waitForExistence(timeout: 10))
    }
}
