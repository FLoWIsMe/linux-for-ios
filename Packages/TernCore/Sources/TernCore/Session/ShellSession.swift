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
}

public extension ShellSessionDelegate {
    func session(_ session: ShellSession, didChangeMode mode: SessionInputMode) {}
    func session(_ session: ShellSession, didChangeDirectory path: String) {}
    func session(_ session: ShellSession, didChangeTitle title: String) {}
    func session(_ session: ShellSession, didStartCommand argv: [String]) {}
    func session(_ session: ShellSession, didFinishCommand argv: [String], status: Int32) {}
    func sessionDidRequestBell(_ session: ShellSession) {}
    func sessionDidExit(_ session: ShellSession, status: Int32) {}
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
/// The session is fully testable without a UI: `FakeTerminal` in TernCoreTests implements
/// `TerminalOutputSink`, records everything written, and tests drive `handleInput` with key bytes.
public final class ShellSession: ShellHost {
    public let configuration: ShellSessionConfiguration
    public let shell: Shell
    public weak var delegate: ShellSessionDelegate?
    public weak var hostCommands: HostCommandProvider?
    public let history: CommandHistory

    /// Current input mode. Readable from any thread.
    public var mode: SessionInputMode { fatalError("implemented by the session") }

    /// Argv of the external command currently running, if any.
    public var runningCommand: [String]? { fatalError("implemented by the session") }

    public init(configuration: ShellSessionConfiguration, executor: CommandExecutor, output: TerminalOutputSink) {
        self.configuration = configuration
        self.history = CommandHistory(fileURL: configuration.historyFileURL, limit: configuration.historyLimit)
        fatalError("implemented by the session")
    }

    /// Starts the shell thread, prints the welcome message and the first prompt.
    public func start() { fatalError("implemented by the session") }

    /// Keyboard bytes from the terminal emulator (printable text, control characters, escape sequences).
    public func handleInput(_ bytes: [UInt8]) { fatalError("implemented by the session") }

    /// Inserts pasted text. In prompt mode it is inserted into the line editor as literal text;
    /// while a command runs it is forwarded (wrapped in bracketed paste markers when raw mode is active
    /// and the command enabled bracketed paste).
    public func paste(_ text: String) { fatalError("implemented by the session") }

    /// The terminal was resized. Redraws the current line if the editor is active.
    public func resize(_ size: TerminalSize) { fatalError("implemented by the session") }

    /// Ctrl-C: clears the line at the prompt, interrupts a running command otherwise.
    public func interrupt() { fatalError("implemented by the session") }

    /// Ctrl-D: exits at an empty prompt, sends end of file to a running command.
    public func sendEndOfFile() { fatalError("implemented by the session") }

    /// Types `line` as if the user had entered it and runs it. Used by the Hosts screen (`ssh name`),
    /// by onboarding and by Shortcuts. Ignored while a command is running unless `force` is set, in
    /// which case the text is sent to the command as input.
    public func submit(_ line: String, force: Bool = false) { fatalError("implemented by the session") }

    /// Replaces the current line editor contents without running them (snippets, `!!` style helpers).
    public func setEditorText(_ text: String) { fatalError("implemented by the session") }

    /// Clears the screen and redraws the prompt (Ctrl-L / Cmd-K).
    public func clearScreen() { fatalError("implemented by the session") }

    /// Stops the shell thread and closes descriptors. The session cannot be restarted.
    public func terminate() { fatalError("implemented by the session") }

    /// Convenience for interactive commands that report their input mode (the ios_system
    /// `startInteractive` / `stopInteractive` callbacks). Safe from any thread.
    public func setRawInput(_ enabled: Bool) { fatalError("implemented by the session") }

    // MARK: ShellHost

    public var terminalSize: TerminalSize { fatalError("implemented by the session") }
    public func readLine(prompt: String, secure: Bool) -> String? { fatalError("implemented by the session") }
    public func openTerminalInput() -> Int32? { fatalError("implemented by the session") }
    public func closeTerminalInput(_ fd: Int32) { fatalError("implemented by the session") }
    public var terminalOutput: Int32 { fatalError("implemented by the session") }
    public var terminalError: Int32 { fatalError("implemented by the session") }
    public func shellDidRequestExit(status: Int32) { fatalError("implemented by the session") }
    public func runHostCommand(_ argv: [String], io: ShellIO) -> Int32? { fatalError("implemented by the session") }
    public func hostCommandNames() -> [String] { fatalError("implemented by the session") }
}

/// Persistent, de-duplicated command history shared by the line editor and the `history` builtin.
/// Thread safe.
public final class CommandHistory {
    public let fileURL: URL?
    public let limit: Int

    public init(fileURL: URL?, limit: Int) {
        self.fileURL = fileURL
        self.limit = limit
        fatalError("implemented by the session")
    }

    /// Oldest first.
    public var entries: [String] { fatalError("implemented by the session") }
    public func append(_ line: String) { fatalError("implemented by the session") }
    public func clear() { fatalError("implemented by the session") }
    /// Most recent entry that starts with `prefix` and is not equal to it, for autosuggestions.
    public func suggestion(forPrefix prefix: String) -> String? { fatalError("implemented by the session") }
    /// Entries containing `query`, most recent first, for Ctrl-R search.
    public func search(_ query: String) -> [String] { fatalError("implemented by the session") }
    public func save() { fatalError("implemented by the session") }
}
