import XCTest
@testable import TernCore

#if os(macOS) || os(Linux)

/// Collects everything the session writes, from any thread, and keeps a small model of what a
/// terminal would show so tests can assert on visible text instead of raw escape sequences.
final class FakeTerminal: TerminalOutputSink {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var model = ScreenModel()

    func terminalWrite(_ chunk: [UInt8]) {
        lock.lock()
        bytes.append(contentsOf: chunk)
        model.feed(String(decoding: chunk, as: UTF8.self))
        lock.unlock()
    }

    /// Raw bytes as text, escape sequences included.
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Output with escape sequences removed (carriage returns kept).
    var plain: String { ANSI.stripANSI(text) }

    /// What the user would see: lines joined with newlines, after cursor movement and erasing.
    var screen: String {
        lock.lock(); defer { lock.unlock() }
        return model.text
    }

    func reset() {
        lock.lock()
        bytes.removeAll()
        model = ScreenModel()
        lock.unlock()
    }
}

/// A deliberately small terminal model: enough of CR, LF, backspace, CSI cursor movement and erase
/// sequences to turn the editor's redraws into the text a person would read.
struct ScreenModel {
    private(set) var lines: [[Character]] = [[]]
    private var row = 0
    private var col = 0
    private var pending = ""

    var text: String {
        lines.map { String($0) }.joined(separator: "\n")
    }

    mutating func feed(_ chunk: String) {
        let characters = Array(pending + chunk)
        pending = ""
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "\u{1b}" {
                // Find the end of the sequence; keep partial sequences for the next chunk.
                guard index + 1 < characters.count else { pending = String(characters[index...]); return }
                let kind = characters[index + 1]
                if kind == "[" {
                    var end = index + 2
                    while end < characters.count, !(("@"..."~").contains(characters[end])) { end += 1 }
                    guard end < characters.count else { pending = String(characters[index...]); return }
                    let params = String(characters[(index + 2)..<end])
                    apply(final: characters[end], params: params)
                    index = end + 1
                    continue
                }
                index += 2
                continue
            }
            switch c {
            case "\r":
                col = 0
            case "\n", "\r\n":
                if c == "\r\n" { col = 0 }
                row += 1
                if row >= lines.count { lines.append([]) }
            case "\u{8}":
                col = max(0, col - 1)
            case "\u{7}":
                break
            default:
                put(c)
            }
            index += 1
        }
    }

    private mutating func put(_ c: Character) {
        while lines[row].count < col { lines[row].append(" ") }
        if col < lines[row].count {
            lines[row][col] = c
        } else {
            lines[row].append(c)
        }
        col += 1
    }

    private mutating func apply(final: Character, params: String) {
        let numbers = params.split(separator: ";").compactMap { Int($0) }
        let n = numbers.first ?? 1
        switch final {
        case "A": row = max(0, row - max(1, n))
        case "B":
            row += max(1, n)
            while row >= lines.count { lines.append([]) }
        case "C": col += max(1, n)
        case "D": col = max(0, col - max(1, n))
        case "G": col = max(0, n - 1)
        case "H":
            if params.isEmpty { row = 0; col = 0 }
        case "J":
            if numbers.first == 2 || numbers.first == 3 {
                lines = [[]]
                row = 0
                col = 0
            } else {
                if lines[row].count > col { lines[row].removeSubrange(col...) }
                if row + 1 < lines.count { lines.removeSubrange((row + 1)...) }
            }
        case "K":
            if lines[row].count > col { lines[row].removeSubrange(col...) }
        default:
            break
        }
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

final class ScreenModelTests: XCTestCase {
    func testPromptAndOutputSequence() {
        var model = ScreenModel()
        model.feed("\r\u{1b}[J$ \r\u{1b}[2C")
        model.feed("\r\u{1b}[J$ e\r\u{1b}[3C")
        model.feed("\r\u{1b}[J$ echo hello\r\u{1b}[12C\r\n")
        model.feed("hello\n")
        model.feed("\r\u{1b}[J$ \r\u{1b}[2C")
        XCTAssertEqual(model.text, "$ echo hello\nhello\n$ ")
    }

    func testSplitSequencesAndClear() {
        var model = ScreenModel()
        model.feed("ab\u{1b}[")
        model.feed("2Dxy\r")
        model.feed("\n")
        model.feed("\u{1b}[H\u{1b}[2J\u{1b}[3Jz")
        XCTAssertEqual(model.text, "z")
    }
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
        let ok = waitUntil { self.terminal.screen.hasSuffix("$ ") && self.session.mode == .prompt }
        XCTAssertTrue(ok, "prompt did not appear: \(terminal.screen.debugDescription)", file: file, line: line)
    }

    private var screen: String { terminal.screen }

    // MARK: Tests

    func testStartShowsWelcomeAndPrompt() {
        startSession(welcome: "Welcome to Tern\nType help to begin")
        waitForPrompt()
        XCTAssertEqual(screen, "Welcome to Tern\nType help to begin\n$ ")
        XCTAssertTrue(recorder.modes.contains(.prompt))
        XCTAssertEqual(recorder.titles.last, "~")
    }

    func testEchoCommandShowsOutputAndNewPrompt() {
        startSession()
        waitForPrompt()
        type("echo hello\r")
        XCTAssertTrue(waitUntil { self.screen == "$ echo hello\nhello\n$ " }, "screen: \(screen.debugDescription) raw: \(terminal.text.debugDescription)")
        XCTAssertEqual(session.shell.lastExitStatus, 0)
    }

    func testExternalCommandRunsWithRealProcess() {
        startSession()
        waitForPrompt()
        type("printf 'a\\nb\\n' | sort -r\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("b\na\n$ ") }, "screen: \(screen.debugDescription) raw: \(terminal.text.debugDescription) mode: \(session.mode) running: \(String(describing: session.runningCommand))")
        XCTAssertTrue(recorder.started.contains { $0.first == "sort" }, "\(recorder.started)")
    }

    func testCookedInputToCatAndEndOfFile() {
        startSession()
        waitForPrompt()
        type("cat\r")
        XCTAssertTrue(waitUntil { self.session.mode == .cooked(command: "cat") }, "\(session.mode)")
        type("abc\r")
        XCTAssertTrue(waitUntil { self.screen.contains("abc\nabc") }, screen)
        session.handleInput([0x04])
        waitForPrompt()
        XCTAssertEqual(recorder.finished.last?.argv.first, "cat")
        XCTAssertEqual(recorder.finished.last?.status, 0)
    }

    func testIncompleteInputAsksForContinuation() {
        startSession()
        waitForPrompt()
        type("if true; then\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("\n> ") }, screen)
        type("echo yes\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("> echo yes\n> ") }, screen)
        type("fi\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("> fi\nyes\n$ ") }, screen)
        XCTAssertEqual(session.history.entries.last, "if true; then\necho yes\nfi")
    }

    func testControlCAtPromptStartsFreshLine() {
        startSession()
        waitForPrompt()
        type("abc")
        XCTAssertTrue(waitUntil { self.screen == "$ abc" })
        session.handleInput([0x03])
        XCTAssertTrue(waitUntil { self.screen == "$ abc^C\n$ " }, screen)
        XCTAssertEqual(session.history.entries, [])
    }

    func testControlCCancelsContinuation() {
        startSession()
        waitForPrompt()
        type("while true; do\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("\n> ") }, screen)
        session.interrupt()
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("> ^C\n$ ") }, screen)
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
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("tern\ngot:tern\n$ ") }, screen)
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
        XCTAssertTrue(screen.contains("exit\n"), screen)
    }

    func testSubmitRunsALine() {
        startSession()
        waitForPrompt()
        session.submit("pwd")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("\(self.home)\n$ ") || self.screen.hasSuffix("/private\(self.home)\n$ ") }, screen)
        XCTAssertTrue(screen.hasPrefix("$ pwd\n"))
    }

    func testSubmitBeforePromptIsQueued() {
        startSession()
        session.submit("echo queued")
        XCTAssertTrue(waitUntil { self.screen == "$ echo queued\nqueued\n$ " }, screen)
    }

    func testTypeAheadWhileCommandRuns() {
        startSession()
        waitForPrompt()
        type("sleep 0.3; echo first\r")
        type("echo second\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("first\n$ echo second\nsecond\n$ ") }, screen)
        XCTAssertEqual(session.history.entries, ["sleep 0.3; echo first", "echo second"])
    }

    func testChangingDirectoryUpdatesPromptAndDelegate() throws {
        try FileManager.default.createDirectory(atPath: home + "/work", withIntermediateDirectories: true)
        startSession(promptStyle: .tern)
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("~ \u{276F} ") }, screen)
        type("cd work\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("~/work \u{276F} ") }, screen)
        XCTAssertEqual(recorder.directories.last.map { ($0 as NSString).lastPathComponent }, "work")
        XCTAssertEqual(recorder.titles.last, "work")
    }

    func testStartupScriptAndHistoryBuiltin() {
        startSession(startup: "alias greet='echo hi there'\n")
        waitForPrompt()
        type("greet\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("hi there\n$ ") }, screen)
        type("history\r")
        XCTAssertTrue(waitUntil { self.screen.contains("1  greet\n") && self.screen.contains("2  history\n") }, screen)
    }

    func testResizeRedrawsTheLine() {
        startSession()
        waitForPrompt()
        type("echo resize")
        XCTAssertTrue(waitUntil { self.screen == "$ echo resize" }, screen)
        terminal.reset()
        session.resize(TerminalSize(columns: 40, rows: 10))
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("$ echo resize") }, screen)
        XCTAssertEqual(session.terminalSize, TerminalSize(columns: 40, rows: 10))
        type("\r")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("\nresize\n$ ") }, screen)
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
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("tern says theme dark\n$ ") }, screen)
        XCTAssertTrue(session.hostCommandNames().contains("tern"))
        session.clearScreen()
        XCTAssertTrue(waitUntil { self.terminal.text.contains(ANSI.clearScreen) && self.screen == "$ " }, terminal.text)
    }

    func testSetRawInputForwardsBytes() {
        startSession()
        waitForPrompt()
        type("cat\r")
        XCTAssertTrue(waitUntil { self.session.mode == .cooked(command: "cat") })
        session.setRawInput(true)
        XCTAssertTrue(waitUntil { self.session.mode == .raw(command: "cat") })
        type("raw\n")
        XCTAssertTrue(waitUntil { self.screen.hasSuffix("cat\nraw\n") }, screen)
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
        XCTAssertTrue(waitUntil(timeout: 3) { self.recorder.exitStatus != nil })
    }
}

#endif
