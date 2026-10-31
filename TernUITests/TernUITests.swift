import XCTest

/// End to end checks that also produce the screenshots used for the App Store listing.
/// Run with `xcodebuild test -scheme Tern -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'`.
/// Screenshots are attached to the test report; scripts/export-screenshots.sh pulls them out.
final class TernUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A blinking cursor never lets XCUITest consider the app idle, so every tap would wait 60 s.
        app.launchArguments = ["-onboarding.completed", "YES", "-shell.welcomeTips", "YES", "-terminal.cursorBlinks", "NO", "-ui-testing"]
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
        app.buttons["menu.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        screenshot("03-settings")
        app.buttons["Done"].tap()
    }

    func testKeysAndHostsOpen() {
        _ = terminal()
        app.buttons["More"].tap()
        app.buttons["menu.keys"].tap()
        XCTAssertTrue(app.navigationBars["SSH Keys"].waitForExistence(timeout: 5))
        screenshot("04-keys")
        app.buttons["Done"].tap()
        app.buttons["More"].tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        screenshot("05-hosts")
        app.buttons["Done"].tap()
    }

    func testOnboardingShowsWhenNotCompleted() {
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-onboarding.completed", "NO", "-terminal.cursorBlinks", "NO", "-ui-testing"]
        fresh.launch()
        XCTAssertTrue(fresh.buttons["Continue"].waitForExistence(timeout: 10))
        for page in 1...5 {
            let attachment = XCTAttachment(screenshot: fresh.screenshot())
            attachment.name = "06-onboarding-\(page)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if page < 5 { fresh.buttons["Continue"].tap() }
        }
        fresh.buttons["Start"].tap()
        XCTAssertTrue(fresh.scrollViews.firstMatch.waitForExistence(timeout: 10))
    }

    /// Full interactive round trip through a real ssh session: typed bytes must reach the remote
    /// shell while ssh runs in raw mode, and its output must come back. Needs a reachable host
    /// with key authentication, so it only runs when TERN_UITEST_SSH_HOST is set, for example
    /// "user@127.0.0.1" with Remote Login enabled on the Mac. TERN_UITEST_SSH_KEY names a private
    /// key on the Mac whose .pub is in that host's authorized_keys; the app installs it as its
    /// ~/.ssh/id_ed25519 at launch. Pass both through xcodebuild as TEST_RUNNER_TERN_UITEST_SSH_HOST
    /// and TEST_RUNNER_TERN_UITEST_SSH_KEY.
    func testInteractiveSSHSession() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TERN_UITEST_SSH_HOST"], !host.isEmpty else {
            throw XCTSkip("Set TERN_UITEST_SSH_HOST (and TERN_UITEST_SSH_KEY) to run the interactive ssh test")
        }
        if let key = environment["TERN_UITEST_SSH_KEY"], !key.isEmpty {
            // Fresh installs get a fresh sandbox, so hand the app the test key to install.
            app.terminate()
            app.launchArguments += ["-ui-ssh-key", key]
            app.launch()
        }
        let view = terminal()
        view.tap()
        app.typeText("ssh -o StrictHostKeyChecking=accept-new \(host)\n")
        // Give the connection a moment; the remote tty buffers anything typed early anyway.
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        app.typeText("echo interactive-$((20+22))\n")
        waitForText("interactive-42", timeout: 10)
        screenshot("09-ssh-session")
        app.typeText("exit\n")
        app.typeText("echo back-home\n")
        waitForText("back-home", timeout: 10)
    }

    /// The keyboard bar is an input accessory view: it only exists while the software keyboard is up.
    /// The Simulator must not have "Connect Hardware Keyboard" enabled for this test.
    func testKeyboardBarTypesControlSequences() throws {
        let view = terminal()
        view.tap()
        let control = app.buttons["Control"]
        guard control.waitForExistence(timeout: 5) else {
            throw XCTSkip("Software keyboard did not appear (hardware keyboard connected?)")
        }
        screenshot("07-keyboard-bar")

        // A command that reads a line: ctrl-C from the bar must interrupt it.
        app.typeText("cat\n")
        app.buttons["Interrupt, Control C"].tap()
        app.typeText("echo bar-ok\n")
        waitForText("bar-ok")

        // Latch control, press U: the line editor clears the text typed so far.
        app.typeText("this text will be erased")
        control.tap()
        app.typeText("u")
        app.typeText("echo after-ctrl-u\n")
        waitForText("after-ctrl-u")

        // Up arrow recalls the previous command.
        app.buttons["Up arrow"].tap()
        app.typeText("\n")
        screenshot("08-keyboard-history")
    }
}
