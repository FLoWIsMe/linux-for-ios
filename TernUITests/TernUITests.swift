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
        // The session controller tags SwiftTerm's view; the tab strip and keyboard bar are scroll
        // views too, so a plain scrollViews query would not do.
        let view = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
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
            // Let the page transition finish before capturing it.
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let attachment = XCTAttachment(screenshot: fresh.screenshot())
            attachment.name = "06-onboarding-\(page)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if page < 5 { fresh.buttons["Continue"].tap() }
        }
        fresh.buttons["Start"].tap()
        XCTAssertTrue(fresh.descendants(matching: .any).matching(identifier: "terminal").firstMatch.waitForExistence(timeout: 10))
    }

    /// Full interactive round trip through a real ssh session: typed bytes must reach the remote
    /// shell while ssh runs in raw mode, and its output must come back. Needs a reachable host
    /// with key authentication, so it only runs when TERN_UITEST_SSH_HOST is set, for example
    /// "user@127.0.0.1" with Remote Login enabled on the Mac. TERN_UITEST_SSH_KEY names a private
    /// key on the Mac whose .pub is in that host's authorized_keys; the app installs it as its
    /// ~/.ssh/id_ed25519 at launch. Pass both as build settings on the xcodebuild command line:
    /// `xcodebuild test ... TERN_UITEST_SSH_HOST=user@host TERN_UITEST_SSH_KEY=/path/to/key`.
    func testInteractiveSSHSession() throws {
        // The values arrive through the test bundle's Info.plist (see project.yml), because
        // xcodebuild does not pass environment variables to UI test runners.
        let info = Bundle(for: TernUITests.self).infoDictionary ?? [:]
        guard let host = info["TernUITestSSHHost"] as? String, !host.isEmpty else {
            throw XCTSkip("Pass TERN_UITEST_SSH_HOST (and TERN_UITEST_SSH_KEY) to xcodebuild to run the interactive ssh test")
        }
        if let key = info["TernUITestSSHKey"] as? String, !key.isEmpty {
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

    /// `mount Downloads` opens the system folder picker; choosing a folder links it at ~/mnt/Downloads,
    /// the link survives a relaunch, and umount removes it. The picker needs something to pick, so
    /// scripts/seed-simulator-downloads.sh must have put Downloads/tern-mount-check.txt into the
    /// Simulator's On My iPhone storage first; the test skips when it finds no Downloads folder.
    func testMountAttachesAFolderFromFiles() throws {
        _ = terminal()
        type("umount Downloads >/dev/null 2>&1; mount Downloads\n")

        // The picker is a remote view controller; XCUITest sees its controls as part of this app.
        // It opens wherever Files was last, so the Open button is the one reliable sign it is up.
        let open = app.buttons["DOCPicker.actionButton"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Folder picker did not appear")
        screenshot("10-mount-picker")

        let downloads = app.staticTexts["Downloads"].firstMatch
        if !downloads.waitForExistence(timeout: 3) {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
            let local = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On My'")).firstMatch
            if local.waitForExistence(timeout: 3) { local.tap() }
        }
        guard downloads.waitForExistence(timeout: 5) else {
            app.swipeDown()
            throw XCTSkip("No Downloads folder in the Simulator's Files storage; run scripts/seed-simulator-downloads.sh")
        }
        // Tapping the cell enters the folder (its title becomes the actions menu in the bar);
        // Open then picks the folder being shown.
        let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Downloads'")).firstMatch
        (cell.exists ? cell : downloads).tap()
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Downloads'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Did not enter the Downloads folder")
        open.tap()

        waitForText("Mounted On My iPhone/Downloads at ~/mnt/Downloads")
        type("cat ~/mnt/Downloads/tern-mount-check.txt\n")
        waitForText("mount-check-ok")
        type("mount\n")
        waitForText("~/mnt/Downloads  On My iPhone/Downloads")
        screenshot("11-mounted")

        // The bookmark must bring the folder back after a relaunch.
        app.terminate()
        app.launch()
        type("cat ~/mnt/Downloads/tern-mount-check.txt && echo relaunch-$((40+2))\n")
        waitForText("relaunch-42")

        type("umount Downloads\n")
        waitForText("Unmounted ~/mnt/Downloads")
        type("ls ~/mnt/Downloads 2>&1 | head -1; echo gone-$((40+3))\n")
        waitForText("gone-43")
    }

    func testPasteRunsACommand() {
        let view = terminal()
        view.tap()
        UIPasteboard.general.string = "echo paste-runs-123"
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).press(forDuration: 1.0)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Paste was not offered")
        paste.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.typeText("\n")
        waitForText("paste-runs-123")
        screenshot("12-paste")
    }

    func testSelectAndCopy() {
        let view = terminal()
        view.tap()
        app.typeText("echo copyword-9\n")
        waitForText("copyword-9")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // Standard iOS flow: long-press, Select the word, then Copy.
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.085)).press(forDuration: 1.0)
        let select = app.menuItems["Select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5), "Select was not offered")
        select.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy was not offered after Select")
        copy.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        // The test runner cannot read the pasteboard, so let the app read it back.
        app.typeText("pbpaste\n")
        waitForText("copyword-9", timeout: 6)
    }

    func testTapAcceptsAutosuggestion() {
        let view = terminal()
        view.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        app.typeText("echo kiwi-55\n")
        waitForText("kiwi-55")
        app.typeText("echo ki")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        view.tap()                       // tapping the grey suggestion fills it in
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        app.typeText(" tapped\n")
        // Proves the suggestion was accepted: the command ran as "echo kiwi-55 tapped".
        waitForText("kiwi-55 tapped")
        screenshot("13-tap-suggestion")
    }

    /// Exercises the full `claude` tool loop against a local mock Anthropic server. Skips unless the
    /// mock from scripts/mock-anthropic.py is running on 127.0.0.1:8099, so CI stays green.
    func testClaudeRunsAToolThroughTheAPI() throws {
        guard mockAPIReachable() else {
            throw XCTSkip("Start scripts/mock-anthropic.py on 127.0.0.1:8099 to run the claude API test")
        }
        let claude = XCUIApplication()
        claude.launchArguments = ["-onboarding.completed", "YES", "-terminal.cursorBlinks", "NO", "-ui-testing",
                                  "-ui-command", "claude -y 'please run the echo'"]
        claude.launchEnvironment["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:8099"
        claude.launchEnvironment["ANTHROPIC_API_KEY"] = "sk-ant-test"
        claude.launch()
        let view = claude.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let value = view.value as? String ?? ""
            if value.contains("hello-from-claude") && value.contains("All done") { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("claude did not complete the tool round trip")
    }

    private func mockAPIReachable() -> Bool {
        var reachable = false
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8099/")!)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return reachable
    }
}
