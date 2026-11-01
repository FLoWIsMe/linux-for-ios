import Foundation

/// Receives everything the session wants to show in the terminal.
///
/// `terminalWrite` is called from a background thread, strictly in order. The app forwards the
/// bytes to its terminal emulator on the main thread.
public protocol TerminalOutputSink: AnyObject {
    func terminalWrite(_ bytes: [UInt8])
}

/// What keyboard input currently drives.
public enum SessionInputMode: Equatable, Sendable {
    /// The line editor is active and the user is composing a command.
    case prompt
    /// An external command is running and reads lines (local echo and editing, Enter sends the line).
    case cooked(command: String)
    /// An interactive command (vim, less, ssh) owns the keyboard; every byte is forwarded.
    case raw(command: String)
    /// A builtin (`read`) is waiting for a line.
    case reading(prompt: String)
    /// The session has exited.
    case ended

    /// The command that owns the keyboard in `cooked` and `raw` mode.
    public var commandName: String? {
        switch self {
        case .cooked(let command), .raw(let command): return command
        default: return nil
        }
    }
}

/// Main thread callbacks about the session's state. Every method has a default empty implementation.
public protocol ShellSessionDelegate: AnyObject {
    func session(_ session: ShellSession, didChangeMode mode: SessionInputMode)
    func session(_ session: ShellSession, didChangeDirectory path: String)
    func session(_ session: ShellSession, didChangeTitle title: String)
    func session(_ session: ShellSession, didStartCommand argv: [String])
    func session(_ session: ShellSession, didFinishCommand argv: [String], status: Int32)
    func sessionDidRequestBell(_ session: ShellSession)
    func sessionDidExit(_ session: ShellSession, status: Int32)
    /// The text of the line being edited at the prompt changed, or editing ended (`nil`). Sent on
    /// the main thread, after the terminal output for the change was written. Also sent when a new
    /// line begins, even when it is as empty as the last one ended.
    func session(_ session: ShellSession, didChangeLine line: String?)
}

public extension ShellSessionDelegate {
    func session(_ session: ShellSession, didChangeMode mode: SessionInputMode) {}
    func session(_ session: ShellSession, didChangeDirectory path: String) {}
    func session(_ session: ShellSession, didChangeTitle title: String) {}
    func session(_ session: ShellSession, didStartCommand argv: [String]) {}
    func session(_ session: ShellSession, didFinishCommand argv: [String], status: Int32) {}
    func sessionDidRequestBell(_ session: ShellSession) {}
    func sessionDidExit(_ session: ShellSession, status: Int32) {}
    func session(_ session: ShellSession, didChangeLine line: String?) {}
}

/// App provided commands such as `tern`, `open`, `pbcopy`, `help`. Called on the shell thread.
public protocol HostCommandProvider: AnyObject {
    var hostCommandNames: [String] { get }
    /// Return nil if `argv[0]` is not a host command.
    func runHostCommand(_ argv: [String], io: ShellIO, session: ShellSession) -> Int32?
}

/// A 24-bit color used for terminal accents.
public struct RGBColor: Equatable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
    /// SGR parameters selecting this color as the foreground, without the leading `ESC[` or trailing `m`.
    public var foregroundSGR: String { "38;2;\(red);\(green);\(blue)" }
}

/// How the prompt looks.
public enum PromptStyle: String, CaseIterable, Codable, Sendable {
    /// `~/projects/tern main ❯ ` with the directory dimmed and the arrow in the accent color.
    case tern
    /// `user@tern:~/projects/tern$ `
    case classic
    /// Just `$ `.
    case minimal
}

public struct ShellSessionConfiguration: Sendable {
    public var homeDirectory: String
    public var workingDirectory: String
    public var environment: [String: String]
    /// Where history is persisted. nil keeps history in memory only.
    public var historyFileURL: URL?
    /// Script sourced before the first prompt (`~/.ternrc`). Ignored when missing.
    public var startupScriptURL: URL?
    public var promptStyle: PromptStyle
    /// Fish style inline suggestions from history.
    public var autosuggestions: Bool
    /// Colorize the command line while typing.
    public var syntaxHighlighting: Bool
    /// Text printed once when the session starts. nil prints nothing.
    public var welcomeMessage: String?
    public var terminalSize: TerminalSize
    /// Maximum number of history entries kept.
    public var historyLimit: Int
    /// 24-bit color for the prompt symbol and other accents. nil uses the terminal's ANSI yellow.
    public var accentColor: RGBColor?
    /// Name shown in the classic prompt (`user@host`). Defaults to `mobile@tern`.
    public var userName: String
    public var hostName: String

    public init(
        homeDirectory: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        historyFileURL: URL? = nil,
        startupScriptURL: URL? = nil,
        promptStyle: PromptStyle = .tern,
        autosuggestions: Bool = true,
        syntaxHighlighting: Bool = true,
        welcomeMessage: String? = nil,
        terminalSize: TerminalSize = .fallback,
        historyLimit: Int = 5000,
        accentColor: RGBColor? = nil,
        userName: String = "mobile",
        hostName: String = "tern"
    ) {
        self.accentColor = accentColor
        self.userName = userName
        self.hostName = hostName
        self.homeDirectory = homeDirectory
        self.workingDirectory = workingDirectory ?? homeDirectory
        self.environment = environment
        self.historyFileURL = historyFileURL
        self.startupScriptURL = startupScriptURL
        self.promptStyle = promptStyle
        self.autosuggestions = autosuggestions
        self.syntaxHighlighting = syntaxHighlighting
        self.welcomeMessage = welcomeMessage
        self.terminalSize = terminalSize
        self.historyLimit = historyLimit
    }
}

/// One interactive terminal session: a `Shell` running on its own thread, a line editor driven by
/// keyboard bytes, and the plumbing (pipes and threads) that moves bytes between them and the
/// terminal emulator.
///
/// Call `start()` once, then feed keyboard bytes with `handleInput`. All public methods must be
/// called on the main thread unless documented otherwise; delegate callbacks arrive on the main
/// thread. `TerminalOutputSink.terminalWrite` arrives on a background thread.
///
/// The sink is held weakly: whoever owns the session must keep the sink alive.
///
/// The session is fully testable without a UI: `FakeTerminal` in TernCoreTests implements
/// `TerminalOutputSink`, records everything written, and tests drive `handleInput` with key bytes.
public final class ShellSession: ShellHost {
    public let configuration: ShellSessionConfiguration
    public let shell: Shell
    public weak var delegate: ShellSessionDelegate?
    public weak var hostCommands: HostCommandProvider?
    public let history: CommandHistory
    /// Add `CompletionProvider`s here to extend Tab completion (the app registers `tern` subcommands).
    public let completionEngine: CompletionEngine
    public var promptRenderer: PromptRenderer

    private let executor: CommandExecutor
    private weak var output: TerminalOutputSink?
    private let editor: LineEditor
    /// The line last reported through `didChangeLine`, so unchanged text is not reported again.
    private var reportedLine: String?
    /// The `ShellHost` the interpreter talks to. It exists before the session finishes initializing
    /// and forwards every call here.
    private let hostBridge: SessionHostBridge

    private let lock = NSLock()
    private var state = SessionState()
    private var outputRead: Int32 = -1
    private var outputWrite: Int32 = -1
    private var shellThread: Thread?
    private var drainThread: Thread?

    // Main thread only.
    private var editorActive = false
    private var cooked = CookedLineBuffer()
    private var typeahead: [UInt8] = []
    private var pendingKeys: [Key] = []
    private var pendingSubmits: [String] = []
    private var pendingEditorText: String? = nil
    private var lastNotifiedMode: SessionInputMode? = nil
    private var lastNotifiedTitle: String? = nil

    /// State shared between the main thread and the shell thread. Always accessed under `lock`.
    private struct SessionState {
        var started = false
        var terminated = false
        var exitRequested = false
        var exitStatus: Int32 = 0
        var mode: SessionInputMode = .prompt
        var size: TerminalSize = .fallback
        var runningCommand: [String]? = nil
        /// External commands currently running, oldest first. A pipeline runs several at once and
        /// the keyboard goes back to the prompt only when the last one is done.
        var running: [[String]] = []
        var forcedRaw = false
        var lineRequest: LineRequest? = nil
        /// Read descriptor to write descriptor for open terminal input pipes.
        var stdinSinks: [Int32: Int32] = [:]
        var currentStdinWrite: Int32? = nil
        var workingDirectory: String = ""
        /// Lines typed ahead while a `read` builtin was active, consumed by the next read.
        var pendingLines: [String] = []
    }

    /// A blocking request from the shell thread for one line of input.
    private final class LineRequest {
        enum Outcome { case line(String), cancelled, eof }
        let prompt: RenderedPrompt
        let secure: Bool
        let useEditor: Bool
        private let condition = NSCondition()
        private var outcome: Outcome? = nil

        init(prompt: RenderedPrompt, secure: Bool, useEditor: Bool) {
            self.prompt = prompt
            self.secure = secure
            self.useEditor = useEditor
        }

        func deliver(_ outcome: Outcome) {
            condition.lock()
            if self.outcome == nil { self.outcome = outcome }
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> Outcome {
            condition.lock()
            while outcome == nil { condition.wait() }
            let result = outcome!
            condition.unlock()
            return result
        }
    }

    /// Current input mode. Readable from any thread.
    public var mode: SessionInputMode {
        lock.lock(); defer { lock.unlock() }
        return state.mode
    }

    /// Argv of the external command currently running, if any.
    public var runningCommand: [String]? {
        lock.lock(); defer { lock.unlock() }
        return state.runningCommand
    }

    public init(configuration: ShellSessionConfiguration, executor: CommandExecutor, output: TerminalOutputSink) {
        self.configuration = configuration
        self.executor = executor
        self.output = output
        self.history = CommandHistory(fileURL: configuration.historyFileURL, limit: configuration.historyLimit)
        self.completionEngine = CompletionEngine()
        self.promptRenderer = PromptRenderer(style: configuration.promptStyle, accent: configuration.accentColor, userName: configuration.userName, hostName: configuration.hostName)
        var initialState = SessionState()
        initialState.size = configuration.terminalSize
        initialState.workingDirectory = configuration.workingDirectory
        self.state = initialState

        // The output pipe must exist before the shell is created: the interpreter captures the
        // terminal descriptors when it builds its root descriptor table.
        if let pipe = FileDescriptorIO.makePipe() {
            outputRead = pipe.read
            outputWrite = pipe.write
        }
        let bridge = SessionHostBridge(outputDescriptor: outputWrite, initialSize: configuration.terminalSize)
        self.hostBridge = bridge
        let shell = Shell(
            executor: executor,
            host: bridge,
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory,
            homeDirectory: configuration.homeDirectory
        )
        self.shell = shell
        let editorConfiguration = LineEditorConfiguration(
            autosuggestions: configuration.autosuggestions,
            syntaxHighlighting: configuration.syntaxHighlighting,
            columns: configuration.terminalSize.columns
        )
        self.editor = LineEditor(configuration: editorConfiguration, history: history, completionEngine: completionEngine) { shell.snapshot() }
        bridge.session = self
    }

    deinit {
        closeDescriptors()
    }

    // MARK: Lifecycle

    /// Starts the shell thread, prints the welcome message and the first prompt.
    public func start() {
        lock.lock()
        if state.started { lock.unlock(); return }
        state.started = true
        lock.unlock()

        // Keystrokes may be written to a pipe whose reader (a finished command) is gone. That must
        // surface as EPIPE, never as a process killing SIGPIPE.
        ShellSession.ignoreSIGPIPE()

        guard outputRead >= 0, outputWrite >= 0 else { return }

        let drain = Thread { [weak self] in self?.drainOutput() }
        drain.name = "tern.session.drain"
        drain.qualityOfService = .userInteractive
        drainThread = drain
        drain.start()

        let runner = Thread { [weak self] in self?.runREPL() }
        runner.name = "tern.session.shell"
        runner.stackSize = 16 * 1024 * 1024
        runner.qualityOfService = .userInitiated
        shellThread = runner
        runner.start()
    }

    /// Stops the shell thread and closes descriptors. The session cannot be restarted.
    public func terminate() {
        lock.lock()
        state.terminated = true
        let request = state.lineRequest
        state.lineRequest = nil
        let sinks = state.stdinSinks.values.filter { $0 >= 0 }
        state.stdinSinks = state.stdinSinks.mapValues { _ in -1 }
        state.currentStdinWrite = nil
        state.mode = .ended
        lock.unlock()
        request?.deliver(.eof)
        shell.interrupt()
        for fd in sinks { FileDescriptorIO.closeQuietly(fd) }
        editorActive = false
        closeOutputWriteEnd()
    }

    private static let sigpipeOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private static func ignoreSIGPIPE() {
        _ = sigpipeOnce
    }

    private func closeOutputWriteEnd() {
        lock.lock()
        let fd = outputWrite
        outputWrite = -1
        lock.unlock()
        FileDescriptorIO.closeQuietly(fd)
    }

    private func closeDescriptors() {
        lock.lock()
        let write = outputWrite
        let sinks = state.stdinSinks
        outputWrite = -1
        state.stdinSinks = [:]
        let unusedRead = drainThread == nil ? outputRead : -1
        outputRead = drainThread == nil ? -1 : outputRead
        lock.unlock()
        FileDescriptorIO.closeQuietly(write)
        FileDescriptorIO.closeQuietly(unusedRead)
        for (read, write) in sinks {
            FileDescriptorIO.closeQuietly(read)
            if write >= 0 { FileDescriptorIO.closeQuietly(write) }
        }
    }

    // MARK: Output

    /// Writes text destined for the terminal through the session's output pipe so it stays ordered
    /// with command output. Safe from any thread.
    public func write(_ text: String) {
        lock.lock()
        let fd = outputWrite
        lock.unlock()
        guard fd >= 0 else { return }
        FileDescriptorIO.writeAll(fd, text)
    }

    private func write(bytes: [UInt8]) {
        lock.lock()
        let fd = outputWrite
        lock.unlock()
        guard fd >= 0 else { return }
        var copy = bytes
        FileDescriptorIO.writeAll(fd, &copy)
    }

    private func drainOutput() {
        let fd = outputRead
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, pointer.baseAddress!, pointer.count)
                #else
                return Glibc.read(fd, pointer.baseAddress!, pointer.count)
                #endif
            }
            if count > 0 {
                output?.terminalWrite(Array(buffer[0..<count]))
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        FileDescriptorIO.closeQuietly(fd)
    }

    // MARK: The read, eval, print loop (shell thread)

    private func runREPL() {
        if let welcome = configuration.welcomeMessage, !welcome.isEmpty {
            write(welcome.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
        }
        if let startup = configuration.startupScriptURL, FileManager.default.fileExists(atPath: startup.path) {
            _ = shell.runFile(atPath: startup.path)
        }
        notifyDirectory(shell.workingDirectory)

        var status: Int32 = 0
        replLoop: while true {
            lock.lock()
            let stop = state.terminated || state.exitRequested
            if state.exitRequested { status = state.exitStatus }
            lock.unlock()
            if stop { break }

            let snapshot = shell.snapshot()
            let prompt = promptRenderer.render(
                workingDirectory: snapshot.workingDirectory,
                homeDirectory: snapshot.homeDirectory,
                lastExitStatus: snapshot.lastExitStatus,
                gitBranch: GitBranchDetector.branch(forDirectory: snapshot.workingDirectory)
            )

            var program: String
            switch requestLine(prompt: prompt, secure: false, useEditor: true) {
            case .line(let text): program = text
            case .cancelled: continue replLoop
            case .eof:
                write("exit\r\n")
                break replLoop
            }

            var cancelled = false
            while case .incomplete = Shell.parseState(of: program) {
                switch requestLine(prompt: promptRenderer.continuation(), secure: false, useEditor: true) {
                case .line(let more): program += "\n" + more
                case .cancelled, .eof: cancelled = true
                }
                if cancelled { break }
            }
            if cancelled { continue }

            let trimmed = program.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            history.append(program)
            status = shell.run(program)

            lock.lock()
            let knownDirectory = state.workingDirectory
            lock.unlock()
            let currentDirectory = shell.workingDirectory
            if currentDirectory != knownDirectory {
                notifyDirectory(currentDirectory)
            }
        }

        lock.lock()
        state.mode = .ended
        if state.exitRequested { status = state.exitStatus }
        lock.unlock()
        notifyMode(.ended)
        let finalStatus = status
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorActive = false
            self.delegate?.sessionDidExit(self, status: finalStatus)
        }
    }

    /// Blocks the shell thread until the main thread delivers a line.
    private func requestLine(prompt: RenderedPrompt, secure: Bool, useEditor: Bool) -> LineRequest.Outcome {
        let request = LineRequest(prompt: prompt, secure: secure, useEditor: useEditor)
        lock.lock()
        if state.terminated {
            lock.unlock()
            return .eof
        }
        state.lineRequest = request
        state.mode = useEditor ? .prompt : .reading(prompt: ANSI.stripANSI(prompt.text))
        let mode = state.mode
        lock.unlock()
        notifyMode(mode)
        DispatchQueue.main.async { [weak self] in self?.activate(request) }
        return request.wait()
    }

    /// Main thread: shows the prompt for a pending request and replays type ahead.
    private func activate(_ request: LineRequest) {
        lock.lock()
        guard state.lineRequest === request, !state.terminated else { lock.unlock(); return }
        lock.unlock()

        if request.useEditor {
            editorActive = true
            let initial = pendingEditorText ?? ""
            pendingEditorText = nil
            write(editor.beginLine(prompt: request.prompt, initialText: initial))
            reportLine(force: true)
            if !pendingSubmits.isEmpty {
                let line = pendingSubmits.removeFirst()
                writeEditor(editor.setText(line))
                process(editor.feed(key: .enter))
                return
            }
            if !pendingKeys.isEmpty {
                let keys = pendingKeys
                pendingKeys = []
                process(editor.feed(keys: keys))
                if !editorActive { return }
            }
            if !typeahead.isEmpty {
                let bytes = typeahead
                typeahead = []
                handleInput(bytes)
            }
        } else {
            cooked.reset(echo: !request.secure)
            if !request.prompt.text.isEmpty { write(request.prompt.text) }
            if !typeahead.isEmpty {
                let bytes = typeahead
                typeahead = []
                handleInput(bytes)
            }
        }
    }

    private func takePendingLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !state.pendingLines.isEmpty else { return nil }
        return state.pendingLines.removeFirst()
    }

    private func storePendingLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        state.pendingLines.append(contentsOf: lines)
        lock.unlock()
    }

    private func deliver(_ outcome: LineRequest.Outcome) {
        lock.lock()
        let request = state.lineRequest
        state.lineRequest = nil
        lock.unlock()
        request?.deliver(outcome)
    }

    // MARK: Input (main thread)

    /// The text being edited at the prompt, or nil while a command or a read owns the input. Main
    /// thread only. The terminal view mirrors it into the text input document the software keyboard
    /// looks at, so the delete key can see there is something to delete.
    public var editorLine: String? {
        guard editorActive, case .prompt = mode else { return nil }
        return editor.editableText
    }

    /// Reports the line to the delegate when it differs from the last report, or always when `force`.
    private func reportLine(force: Bool = false) {
        let line = editorLine
        guard force || line != reportedLine else { return }
        reportedLine = line
        delegate?.session(self, didChangeLine: line)
    }

    /// Writes line editor output and reports the line if it changed.
    private func writeEditor(_ output: String) {
        write(output)
        reportLine()
    }

    /// Keyboard bytes from the terminal emulator (printable text, control characters, escape sequences).
    public func handleInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        let current = state
        lock.unlock()
        if current.terminated { return }

        if editorActive, case .prompt = current.mode {
            process(editor.feed(bytes: bytes))
            return
        }

        if case .reading = current.mode, current.lineRequest != nil {
            let result = cooked.feed(bytes)
            write(result.echo)
            if result.interrupt {
                shell.interrupt()
                deliver(.cancelled)
                return
            }
            var lines = result.lines
            if result.eof {
                if let partial = result.partial, !partial.isEmpty { lines.append(partial) } else if lines.isEmpty {
                    deliver(.eof)
                    return
                }
            }
            if let first = lines.first {
                storePendingLines(Array(lines.dropFirst()))
                deliver(.line(first))
            }
            return
        }

        if let command = current.runningCommand {
            let routing: CommandInputRouting = current.forcedRaw ? .raw : executor.inputRouting()
            switch routing {
            case .raw:
                writeToCommandStdin(bytes)
            case .rawToDescriptor(let fd):
                var copy = bytes
                FileDescriptorIO.writeAll(fd, &copy)
            case .cooked:
                if case .cooked = current.mode {} else {
                    updateMode(.cooked(command: command.first ?? ""))
                }
                let result = cooked.feed(bytes)
                write(result.echo)
                if result.interrupt {
                    write("^C\r\n")
                    shell.interrupt()
                    return
                }
                for line in result.lines {
                    writeToCommandStdin(Array((line + "\n").utf8))
                }
                if result.eof {
                    if let partial = result.partial, !partial.isEmpty {
                        writeToCommandStdin(Array(partial.utf8))
                    } else {
                        closeCommandStdin()
                    }
                }
            }
            return
        }

        // The shell is busy between commands: keep the bytes for the next prompt, except Ctrl-C.
        if bytes.contains(0x03) {
            shell.interrupt()
            typeahead.removeAll()
            return
        }
        typeahead.append(contentsOf: bytes)
    }

    private func process(_ result: LineEditorOutput) {
        write(result.text)
        switch result.event {
        case .none, .clearScreen:
            break
        case .submit(let line):
            editorActive = false
            pendingKeys = result.unconsumed
            deliver(.line(line))
        case .cancel:
            editorActive = false
            pendingKeys = result.unconsumed
            deliver(.cancelled)
        case .eof:
            editorActive = false
            deliver(.eof)
        }
        reportLine()
    }

    private func writeToCommandStdin(_ bytes: [UInt8]) {
        lock.lock()
        let fd = state.currentStdinWrite
        lock.unlock()
        guard let fd, fd >= 0 else { return }
        var copy = bytes
        FileDescriptorIO.writeAll(fd, &copy)
    }

    private func closeCommandStdin() {
        lock.lock()
        guard let fd = state.currentStdinWrite else { lock.unlock(); return }
        state.currentStdinWrite = nil
        for (read, write) in state.stdinSinks where write == fd {
            state.stdinSinks[read] = -1
        }
        lock.unlock()
        FileDescriptorIO.closeQuietly(fd)
    }

    /// Inserts pasted text. In prompt mode it is inserted into the line editor as literal text;
    /// while a command runs it is forwarded (wrapped in bracketed paste markers when raw mode is active
    /// and the command enabled bracketed paste).
    public func paste(_ text: String) {
        lock.lock()
        let current = state
        lock.unlock()
        if editorActive, case .prompt = current.mode {
            writeEditor(editor.insert(text))
            return
        }
        // While a command or a read is active the bytes follow the normal routing rules.
        handleInput(Array(text.utf8))
    }

    /// Accepts the grey autosuggestion, if one is showing at the prompt. Returns true if it did.
    /// Used by the terminal view so a tap on the suggestion fills it in, the same as pressing Right.
    @discardableResult
    public func acceptAutosuggestion() -> Bool {
        lock.lock()
        let current = state
        lock.unlock()
        guard editorActive, case .prompt = current.mode, editor.hasActiveSuggestion else { return false }
        process(editor.feed(key: .end))
        return true
    }

    /// Deletes the word before the cursor at the prompt, as Alt-Backspace does. Returns true if the
    /// line editor handled it; false while a command is running, so the caller can send a plain
    /// backspace to the command instead. The terminal view calls this once the software keyboard's
    /// delete key has been held long enough to speed up from characters to words.
    @discardableResult
    public func deleteWordBackward() -> Bool {
        lock.lock()
        let current = state
        lock.unlock()
        guard editorActive, case .prompt = current.mode else { return false }
        process(editor.feed(key: .altBackspace))
        return true
    }

    /// The terminal was resized. Redraws the current line if the editor is active.
    public func resize(_ size: TerminalSize) {
        lock.lock()
        state.size = size
        lock.unlock()
        if editorActive {
            write(editor.resize(columns: size.columns))
        } else {
            editor.configuration.columns = size.columns
        }
    }

    /// Ctrl-C: clears the line at the prompt, interrupts a running command otherwise.
    public func interrupt() {
        lock.lock()
        let current = state
        lock.unlock()
        if editorActive, case .prompt = current.mode {
            process(editor.feed(key: .control("c")))
            return
        }
        if case .reading = current.mode {
            write("^C\r\n")
            shell.interrupt()
            deliver(.cancelled)
            return
        }
        if current.runningCommand != nil {
            let routing: CommandInputRouting = current.forcedRaw ? .raw : executor.inputRouting()
            if routing == .raw {
                writeToCommandStdin([0x03])
            } else if case .rawToDescriptor(let fd) = routing {
                var copy: [UInt8] = [0x03]
                FileDescriptorIO.writeAll(fd, &copy)
            } else {
                write("^C\r\n")
                cooked.reset(echo: true)
            }
            shell.interrupt()
            return
        }
        shell.interrupt()
    }

    /// Ctrl-D: exits at an empty prompt, sends end of file to a running command.
    public func sendEndOfFile() {
        lock.lock()
        let current = state
        lock.unlock()
        if editorActive, case .prompt = current.mode {
            process(editor.feed(key: .control("d")))
            return
        }
        if case .reading = current.mode {
            write("\r\n")
            deliver(.eof)
            return
        }
        if current.runningCommand != nil {
            let routing: CommandInputRouting = current.forcedRaw ? .raw : executor.inputRouting()
            switch routing {
            case .raw: writeToCommandStdin([0x04])
            case .rawToDescriptor(let fd):
                var copy: [UInt8] = [0x04]
                FileDescriptorIO.writeAll(fd, &copy)
            case .cooked: handleInput([0x04])
            }
        }
    }

    /// Types `line` as if the user had entered it and runs it. Used by the Hosts screen (`ssh name`),
    /// by onboarding and by Shortcuts. Ignored while a command is running unless `force` is set, in
    /// which case the text is sent to the command as input.
    public func submit(_ line: String, force: Bool = false) {
        lock.lock()
        let current = state
        lock.unlock()
        if editorActive, case .prompt = current.mode {
            writeEditor(editor.setText(line))
            process(editor.feed(key: .enter))
            return
        }
        if case .reading = current.mode {
            write(line + "\r\n")
            deliver(.line(line))
            return
        }
        if current.runningCommand != nil {
            if force { writeToCommandStdin(Array((line + "\n").utf8)) }
            return
        }
        pendingSubmits.append(line)
    }

    /// Replaces the current line editor contents without running them (snippets, `!!` style helpers).
    public func setEditorText(_ text: String) {
        lock.lock()
        let current = state
        lock.unlock()
        if editorActive, case .prompt = current.mode {
            writeEditor(editor.setText(text))
        } else {
            pendingEditorText = text
        }
    }

    /// Changes editor behaviour at runtime (Settings toggles). Takes effect on the next redraw.
    public func updateEditorOptions(autosuggestions: Bool? = nil, syntaxHighlighting: Bool? = nil, promptStyle: PromptStyle? = nil, accentColor: RGBColor?? = nil) {
        if let autosuggestions { editor.configuration.autosuggestions = autosuggestions }
        if let syntaxHighlighting { editor.configuration.syntaxHighlighting = syntaxHighlighting }
        if let promptStyle { promptRenderer.style = promptStyle }
        if let accentColor { promptRenderer.accent = accentColor }
        if editorActive { write(editor.resize(columns: editor.configuration.columns)) }
    }

    /// Clears the screen and redraws the prompt (Ctrl-L / Cmd-K).
    public func clearScreen() {
        write(ANSI.clearScreen)
        if editorActive {
            write(editor.redrawAfterClear())
        }
    }

    /// Convenience for interactive commands that report their input mode (the ios_system
    /// `startInteractive` / `stopInteractive` callbacks). Safe from any thread.
    public func setRawInput(_ enabled: Bool) {
        lock.lock()
        state.forcedRaw = enabled
        var newMode: SessionInputMode? = nil
        if let command = state.runningCommand {
            newMode = enabled ? .raw(command: command.first ?? "") : .cooked(command: command.first ?? "")
            state.mode = newMode!
        }
        lock.unlock()
        if let newMode { notifyMode(newMode) }
    }

    // MARK: Notifications

    private func updateMode(_ mode: SessionInputMode) {
        lock.lock()
        state.mode = mode
        lock.unlock()
        notifyMode(mode)
    }

    private func notifyMode(_ mode: SessionInputMode) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastNotifiedMode != mode else { return }
            self.lastNotifiedMode = mode
            self.delegate?.session(self, didChangeMode: mode)
        }
    }

    private func notifyTitle(_ title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastNotifiedTitle != title else { return }
            self.lastNotifiedTitle = title
            self.delegate?.session(self, didChangeTitle: title)
        }
    }

    private func notifyDirectory(_ path: String) {
        lock.lock()
        state.workingDirectory = path
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.session(self, didChangeDirectory: path)
        }
        notifyTitle(ShellSession.directoryTitle(path, home: configuration.homeDirectory))
    }

    static func directoryTitle(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    // MARK: ShellHost (shell thread)

    public var terminalSize: TerminalSize {
        lock.lock(); defer { lock.unlock() }
        return state.size
    }

    public func readLine(prompt: String, secure: Bool) -> String? {
        if let line = takePendingLine() {
            return line
        }
        switch requestLine(prompt: .plain(prompt), secure: secure, useEditor: false) {
        case .line(let text): return text
        case .cancelled, .eof: return nil
        }
    }

    public func openTerminalInput() -> Int32? {
        guard let pipe = FileDescriptorIO.makePipe() else { return nil }
        lock.lock()
        state.stdinSinks[pipe.read] = pipe.write
        state.currentStdinWrite = pipe.write
        lock.unlock()
        return pipe.read
    }

    public func closeTerminalInput(_ fd: Int32) {
        lock.lock()
        let write = state.stdinSinks.removeValue(forKey: fd)
        if let write, state.currentStdinWrite == write {
            state.currentStdinWrite = state.stdinSinks.values.first(where: { $0 >= 0 })
        }
        lock.unlock()
        // Whatever the command left unread was typed ahead for the shell: keep it for the next prompt,
        // the way a real tty's input queue survives the end of a foreground process.
        let unread = ShellSession.drainWithoutBlocking(fd)
        FileDescriptorIO.closeQuietly(fd)
        if let write, write >= 0 { FileDescriptorIO.closeQuietly(write) }
        if !unread.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.typeahead.insert(contentsOf: unread, at: 0)
            }
        }
    }

    private static func drainWithoutBlocking(_ fd: Int32) -> [UInt8] {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return [] }
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, pointer.baseAddress!, pointer.count)
                #else
                return Glibc.read(fd, pointer.baseAddress!, pointer.count)
                #endif
            }
            if count <= 0 { break }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    public var terminalOutput: Int32 {
        lock.lock(); defer { lock.unlock() }
        return outputWrite
    }

    public var terminalError: Int32 {
        lock.lock(); defer { lock.unlock() }
        return outputWrite
    }

    public func shellWillRun(externalCommand argv: [String]) {
        lock.lock()
        let first = state.running.isEmpty
        state.running.append(argv)
        state.runningCommand = argv
        if first { state.forcedRaw = false }
        if !state.forcedRaw { state.mode = .cooked(command: argv.first ?? "") }
        let mode = state.mode
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if first {
                self.cooked.reset(echo: true)
                // The delegate hears about busy and idle, not about every pipeline stage.
                self.delegate?.session(self, didStartCommand: argv)
            }
        }
        notifyMode(mode)
        notifyTitle(argv.first ?? "")
    }

    public func shellDidFinish(externalCommand argv: [String], status: Int32) {
        lock.lock()
        if let index = state.running.lastIndex(of: argv) { state.running.remove(at: index) }
        let last = state.running.isEmpty
        var modeForSiblings: SessionInputMode? = nil
        if last {
            state.runningCommand = nil
            state.forcedRaw = false
            state.mode = .prompt
        } else if let survivor = state.running.last {
            // A sibling stage is still running (`cat file | less`): the keyboard belongs to it.
            state.runningCommand = survivor
            state.mode = state.forcedRaw ? .raw(command: survivor.first ?? "") : .cooked(command: survivor.first ?? "")
            modeForSiblings = state.mode
        }
        let directory = state.workingDirectory
        lock.unlock()
        if let modeForSiblings {
            notifyMode(modeForSiblings)
            notifyTitle(modeForSiblings.commandName ?? "")
        }
        guard last else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Text typed but not yet submitted while the command ran belongs to the next prompt.
            let partial = self.cooked.takeBuffer()
            if !partial.isEmpty { self.typeahead.insert(contentsOf: Array(partial.utf8), at: 0) }
            self.delegate?.session(self, didFinishCommand: argv, status: status)
        }
        notifyMode(.prompt)
        notifyTitle(ShellSession.directoryTitle(directory, home: configuration.homeDirectory))
    }

    public func shellDidRequestExit(status: Int32) {
        lock.lock()
        state.exitRequested = true
        state.exitStatus = status
        lock.unlock()
    }

    public func shellDidChangeDirectory(_ path: String) {
        notifyDirectory(path)
    }

    public func runHostCommand(_ argv: [String], io: ShellIO) -> Int32? {
        guard let name = argv.first else { return nil }
        switch name {
        case "history":
            if argv.dropFirst().contains("-c") {
                history.clear()
                return 0
            }
            var text = ""
            for (index, entry) in history.entries.enumerated() {
                text += String(format: "%5d  ", index + 1) + entry.replacingOccurrences(of: "\n", with: "\n       ") + "\n"
            }
            io.writeOut(text)
            return 0
        case "clear":
            io.writeOut(ANSI.clearScreen)
            return 0
        default:
            if let result = hostCommands?.runHostCommand(argv, io: io, session: self) {
                return result
            }
            if name == "help" {
                io.writeOut(ShellSession.defaultHelp)
                return 0
            }
            return nil
        }
    }

    public func hostCommandNames() -> [String] {
        var names = ["history", "clear"]
        names.append(contentsOf: hostCommands?.hostCommandNames ?? [])
        if !names.contains("help") { names.append("help") }
        return names
    }

    static let defaultHelp = """
    Tern shell quick reference
      Tab          complete commands, paths, hosts and options
      Up / Down    browse history (type a prefix first to filter)
      Ctrl-R       search history
      Ctrl-C       cancel the line or stop the running command
      Ctrl-D       end input, exit on an empty line
      Ctrl-L       clear the screen
      history      show previous commands; history -c clears them
    Type a command name followed by --help for its options.

    """
}

/// Stands in for the session as the interpreter's host. The interpreter captures the terminal
/// descriptors when it is created, before the session's own initializer has finished, so the bridge
/// knows them up front and forwards everything else once `session` is set.
final class SessionHostBridge: ShellHost {
    weak var session: ShellSession?
    private let outputDescriptor: Int32
    private let initialSize: TerminalSize

    init(outputDescriptor: Int32, initialSize: TerminalSize) {
        self.outputDescriptor = outputDescriptor
        self.initialSize = initialSize
    }

    var terminalSize: TerminalSize { session?.terminalSize ?? initialSize }
    func readLine(prompt: String, secure: Bool) -> String? { session?.readLine(prompt: prompt, secure: secure) }
    func openTerminalInput() -> Int32? { session?.openTerminalInput() }
    func closeTerminalInput(_ fd: Int32) { session?.closeTerminalInput(fd) ?? FileDescriptorIO.closeQuietly(fd) }
    var terminalOutput: Int32 { session?.terminalOutput ?? outputDescriptor }
    var terminalError: Int32 { session?.terminalError ?? outputDescriptor }
    func shellWillRun(externalCommand argv: [String]) { session?.shellWillRun(externalCommand: argv) }
    func shellDidFinish(externalCommand argv: [String], status: Int32) { session?.shellDidFinish(externalCommand: argv, status: status) }
    func shellDidRequestExit(status: Int32) { session?.shellDidRequestExit(status: status) }
    func shellDidChangeDirectory(_ path: String) { session?.shellDidChangeDirectory(path) }
    func runHostCommand(_ argv: [String], io: ShellIO) -> Int32? { session?.runHostCommand(argv, io: io) }
    func hostCommandNames() -> [String] { session?.hostCommandNames() ?? [] }
}

/// Minimal line discipline used while an external command reads from the keyboard and for the
/// `read` builtin: echo, Backspace, Ctrl-U, Ctrl-W, Enter, Ctrl-D and Ctrl-C.
struct CookedLineBuffer {
    struct Result {
        var echo: String = ""
        var lines: [String] = []
        var partial: String? = nil
        var eof = false
        var interrupt = false
    }

    private var parser = KeyParser()
    private var buffer: [Character] = []
    private var echoEnabled = true

    mutating func reset(echo: Bool) {
        parser = KeyParser()
        buffer = []
        echoEnabled = echo
    }

    /// Returns and clears the text typed so far.
    mutating func takeBuffer() -> String {
        let text = String(buffer)
        buffer = []
        return text
    }

    mutating func feed(_ bytes: [UInt8]) -> Result {
        var result = Result()
        for key in parser.feed(bytes) {
            switch key {
            case .character(let c):
                buffer.append(c)
                if echoEnabled { result.echo.append(c) }
            case .paste(let text):
                for character in text {
                    if character == "\n" || character == "\r\n" {
                        result.lines.append(String(buffer))
                        buffer.removeAll()
                        result.echo += "\r\n"
                    } else if !character.isControl() {
                        buffer.append(character)
                        if echoEnabled { result.echo.append(character) }
                    }
                }
            case .enter:
                result.echo += "\r\n"
                result.lines.append(String(buffer))
                buffer.removeAll()
            case .backspace, .control("h"):
                if let last = buffer.popLast(), echoEnabled {
                    let width = max(1, ANSI.width(ofCluster: last))
                    result.echo += String(repeating: "\u{8} \u{8}", count: width)
                }
            case .control("u"):
                result.echo += eraseEcho(count: buffer.count)
                buffer.removeAll()
            case .control("w"):
                var removed = 0
                while let last = buffer.last, last.isWhitespace { buffer.removeLast(); removed += 1 }
                while let last = buffer.last, !last.isWhitespace { buffer.removeLast(); removed += 1 }
                result.echo += eraseEcho(count: removed)
            case .control("d"):
                result.eof = true
                result.partial = String(buffer)
                buffer.removeAll()
            case .control("c"):
                result.interrupt = true
                buffer.removeAll()
            default:
                break
            }
        }
        return result
    }

    private func eraseEcho(count: Int) -> String {
        guard echoEnabled, count > 0 else { return "" }
        return String(repeating: "\u{8} \u{8}", count: count)
    }
}
