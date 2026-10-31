import XCTest
@testable import TernCore

#if os(macOS) || os(Linux)

/// Collects everything the session writes, from any thread.
final class FakeTerminal: TerminalOutputSink {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func terminalWrite(_ chunk: [UInt8]) {
        lock.lock()
        bytes.append(contentsOf: chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Output with escape sequences removed.
    var plain: String { ANSI.stripANSI(text) }

    func reset() {
        lock.lock()
        bytes.removeAll()
        lock.unlock()
    }
}

final class SessionRecorder: ShellSessionDelegate {
    var modes: [SessionInputMode] = []
    var titles: [String] = []
    var directories: [String] = []
    var started: [[String]] = []
    var finished: [(argv: [String], status: Int32)] = []
    var exitStatus: Int32? = nil

    func session(_ session: ShellSession, didChangeMode mode: SessionInputMode) { modes.append(mode) }
    func session(_ session: ShellSession, didChangeDirectory path: String) { directories.append(path) }
    func session(_ session: ShellSession, didChangeTitle title: String) { titles.append(title) }
    func session(_ session: ShellSession, didStartCommand argv: [String]) { started.append(argv) }
    func session(_ session: ShellSession, didFinishCommand argv: [String], status: Int32) { finished.append((argv, status)) }
    func sessionDidExit(_ session: ShellSession, status: Int32) { exitStatus = status }
}

final class SessionTests: XCTestCase {
    private var home = ""
    private var terminal: FakeTerminal!
    private var recorder: SessionRecorder!
    private var session: ShellSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = NSTemporaryDirectory() + "tern-session-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        terminal = FakeTerminal()
        recorder = SessionRecorder()
    }

    override func tearDownWithError() throws {
        session?.terminate()
        session = nil
        try? FileManager.default.removeItem(atPath: home)
        try super.tearDownWithError()
    }

    private func startSession(welcome: String? = nil, startup: String? = nil, promptStyle: PromptStyle = .minimal) {
        var startupURL: URL? = nil
        if let startup {
            startupURL = URL(fileURLWithPath: home + "/.ternrc")
            try? startup.write(to: startupURL!, atomically: true, encoding: .utf8)
        }
        let configuration = ShellSessionConfiguration(
            homeDirectory: home,
            environment: ["PATH": "/usr/bin:/bin:/usr/local/bin"],
            historyFileURL: nil,
            startupScriptURL: startupURL,
            promptStyle: promptStyle,
            autosuggestions: false,
            syntaxHighlighting: false,
            welcomeMessage: welcome,
            terminalSize: TerminalSize(columns: 80, rows: 24)
        )
        session = ShellSession(configuration: configuration, executor: ProcessCommandExecutor(), output: terminal)
        session.delegate = recorder
        session.start()
    }

    /// Spins the main run loop until `condition` holds or the timeout passes.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func type(_ text: String) {
        session.handleInput(Array(text.utf8))
    }

    private func waitForPrompt(file: StaticString = #filePath, line: UInt = #line) {
        let ok = waitUntil { [terminal] in terminal!.plain.hasSuffix("$ ") && self.session.mode == .prompt }
        XCTAssertTrue(ok, "prompt did not appear: \(terminal.plain.debugDescription)", file: file, line: line)
    }

    // MARK: Tests

    func testStartShowsWelcomeAndPrompt() {
        startSession(welcome: "Welcome to Tern\nType help to begin")
        waitForPrompt()
        XCTAssertTrue(terminal.plain.hasPrefix("Welcome to Tern\r\nType help to begin\r\n"), terminal.plain)
        XCTAssertTrue(recorder.modes.contains(.prompt))
        XCTAssertEqual(recorder.titles.last, "~")
    }

    func testEchoCommandShowsOutputAndNewPrompt() {
        startSession()
        waitForPrompt()
        type("echo hello\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("hello\r\n$ ") }, terminal.plain)
        XCTAssertTrue(terminal.plain.contains("$ echo hello"))
        XCTAssertEqual(session.shell.lastExitStatus, 0)
    }

    func testExternalCommandRunsWithRealProcess() {
        startSession()
        waitForPrompt()
        type("printf 'a\\nb\\n' | sort -r\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("b\r\n") || self.terminal.plain.contains("b\na\n") }, terminal.plain)
        waitForPrompt()
        XCTAssertTrue(recorder.started.contains { $0.first == "sort" || $0.first == "printf" }, "\(recorder.started)")
    }

    func testCookedInputToCatAndEndOfFile() {
        startSession()
        waitForPrompt()
        type("cat\r")
        XCTAssertTrue(waitUntil { self.session.mode == .cooked(command: "cat") }, "\(session.mode)")
        type("abc\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("abc\r\nabc") }, terminal.plain)
        session.handleInput([0x04])
        waitForPrompt()
        XCTAssertEqual(recorder.finished.last?.argv.first, "cat")
        XCTAssertEqual(recorder.finished.last?.status, 0)
    }

    func testIncompleteInputAsksForContinuation() {
        startSession()
        waitForPrompt()
        type("if true; then\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.hasSuffix("> ") }, terminal.plain)
        type("echo yes\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.hasSuffix("> ") && self.terminal.plain.contains("echo yes") }, terminal.plain)
        type("fi\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("yes\r\n$ ") }, terminal.plain)
        XCTAssertEqual(session.history.entries.last, "if true; then\necho yes\nfi")
    }

    func testControlCAtPromptStartsFreshLine() {
        startSession()
        waitForPrompt()
        type("abc")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("$ abc") })
        session.handleInput([0x03])
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("^C\r\n$ ") }, terminal.plain)
        XCTAssertEqual(session.history.entries, [])
    }

    func testControlCCancelsContinuation() {
        startSession()
        waitForPrompt()
        type("while true; do\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.hasSuffix("> ") }, terminal.plain)
        session.interrupt()
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("^C\r\n$ ") }, terminal.plain)
    }

    func testInterruptStopsRunningCommand() {
        startSession()
        waitForPrompt()
        type("sleep 30\r")
        XCTAssertTrue(waitUntil { self.session.runningCommand?.first == "sleep" })
        let start = Date()
        session.interrupt()
        waitForPrompt()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertNotEqual(session.shell.lastExitStatus, 0)
    }

    func testReadBuiltinUsesCookedInput() {
        startSession()
        waitForPrompt()
        type("read name; echo got:$name\r")
        XCTAssertTrue(waitUntil { if case .reading = self.session.mode { return true } else { return false } }, "\(session.mode)")
        type("tern\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("got:tern\r\n") }, terminal.plain)
        waitForPrompt()
    }

    func testExitEndsSession() {
        startSession()
        waitForPrompt()
        type("exit 3\r")
        XCTAssertTrue(waitUntil { self.recorder.exitStatus != nil })
        XCTAssertEqual(recorder.exitStatus, 3)
        XCTAssertEqual(session.mode, .ended)
    }

    func testEndOfFileAtPromptExits() {
        startSession()
        waitForPrompt()
        session.sendEndOfFile()
        XCTAssertTrue(waitUntil { self.recorder.exitStatus != nil })
        XCTAssertTrue(terminal.plain.contains("exit\r\n"))
    }

    func testSubmitRunsALine() {
        startSession()
        waitForPrompt()
        session.submit("pwd")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("\(self.home)\r\n$ ") || self.terminal.plain.contains("/private\(self.home)\r\n$ ") }, terminal.plain)
    }

    func testSubmitBeforePromptIsQueued() {
        startSession()
        session.submit("echo queued")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("queued\r\n$ ") }, terminal.plain)
    }

    func testTypeAheadWhileCommandRuns() {
        startSession()
        waitForPrompt()
        type("sleep 0.3; echo first\r")
        type("echo second\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("first\r\n") && self.terminal.plain.contains("second\r\n$ ") }, terminal.plain)
        XCTAssertEqual(session.history.entries, ["sleep 0.3; echo first", "echo second"])
    }

    func testChangingDirectoryUpdatesPromptAndDelegate() throws {
        try FileManager.default.createDirectory(atPath: home + "/work", withIntermediateDirectories: true)
        startSession(promptStyle: .tern)
        XCTAssertTrue(waitUntil { self.terminal.plain.hasSuffix("~ \u{276F} ") }, terminal.plain)
        type("cd work\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.hasSuffix("~/work \u{276F} ") }, terminal.plain)
        XCTAssertEqual(recorder.directories.last.map { ($0 as NSString).lastPathComponent }, "work")
        XCTAssertEqual(recorder.titles.last, "work")
    }

    func testStartupScriptAndHistoryBuiltin() {
        startSession(startup: "alias greet='echo hi there'\n")
        waitForPrompt()
        type("greet\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("hi there\r\n$ ") }, terminal.plain)
        type("history\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("1  greet") && self.terminal.plain.contains("2  history") }, terminal.plain)
    }

    func testResizeRedrawsTheLine() {
        startSession()
        waitForPrompt()
        type("echo resize")
        terminal.reset()
        session.resize(TerminalSize(columns: 40, rows: 10))
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("$ echo resize") }, terminal.plain)
        XCTAssertEqual(session.terminalSize, TerminalSize(columns: 40, rows: 10))
        type("\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("resize\r\n$ ") })
    }

    func testClearScreenAndHostCommands() {
        final class Host: HostCommandProvider {
            var hostCommandNames: [String] { ["tern"] }
            func runHostCommand(_ argv: [String], io: ShellIO, session: ShellSession) -> Int32? {
                guard argv.first == "tern" else { return nil }
                io.writeOut("tern says \(argv.dropFirst().joined(separator: " "))\n")
                return 0
            }
        }
        let host = Host()
        startSession()
        session.hostCommands = host
        waitForPrompt()
        type("tern theme dark\r")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("tern says theme dark\r\n$ ") }, terminal.plain)
        XCTAssertTrue(session.hostCommandNames().contains("tern"))
        terminal.reset()
        session.clearScreen()
        XCTAssertTrue(waitUntil { self.terminal.text.contains(ANSI.clearScreen) && self.terminal.plain.hasSuffix("$ ") }, terminal.text)
    }

    func testSetRawInputForwardsBytes() {
        startSession()
        waitForPrompt()
        type("cat\r")
        XCTAssertTrue(waitUntil { self.session.mode == .cooked(command: "cat") })
        session.setRawInput(true)
        XCTAssertTrue(waitUntil { self.session.mode == .raw(command: "cat") })
        type("raw\n")
        XCTAssertTrue(waitUntil { self.terminal.plain.contains("raw\n") }, terminal.plain)
        session.setRawInput(false)
        XCTAssertTrue(waitUntil { self.session.mode == .cooked(command: "cat") })
        session.sendEndOfFile()
        waitForPrompt()
    }

    func testTerminateStopsEverything() {
        startSession()
        waitForPrompt()
        type("sleep 30\r")
        XCTAssertTrue(waitUntil { self.session.runningCommand?.first == "sleep" })
        session.terminate()
        XCTAssertEqual(session.mode, .ended)
        session.handleInput(Array("ignored\r".utf8))
        XCTAssertTrue(waitUntil(timeout: 3) { self.recorder.exitStatus != nil || self.session.mode == .ended })
    }
}

#endif
