import Foundation

/// A request to run one external (non builtin) command.
///
/// File descriptors are plain POSIX descriptors owned by the caller. The executor must never
/// close them; it may `dup` them if it needs its own handles. `stdin` is either a pipe from the
/// previous pipeline stage, a redirected file, or the terminal input pipe obtained from the
/// `ShellHost`.
public struct ExternalCommand: Sendable {
    public var argv: [String]
    /// The full exported environment the command should see.
    public var environment: [String: String]
    public var workingDirectory: String
    public var stdin: Int32
    public var stdout: Int32
    public var stderr: Int32
    /// True when stdin is connected to the user's keyboard rather than a pipe or file.
    public var stdinIsTerminal: Bool
    /// True when stdout is the terminal rather than a pipe or file.
    public var stdoutIsTerminal: Bool

    public init(
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        stdin: Int32,
        stdout: Int32,
        stderr: Int32,
        stdinIsTerminal: Bool,
        stdoutIsTerminal: Bool
    ) {
        self.argv = argv
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.stdinIsTerminal = stdinIsTerminal
        self.stdoutIsTerminal = stdoutIsTerminal
    }
}

/// Runs external commands. The app provides an implementation backed by ios_system; tests and
/// the macOS/Linux command line use `ProcessCommandExecutor`, which spawns real processes.
///
/// All methods may be called from the shell thread or from pipeline worker threads, possibly
/// concurrently when several pipeline stages run at once. Implementations must be thread safe.
public protocol CommandExecutor: AnyObject {
    /// Whether `name` resolves to an external command the executor can run.
    func commandExists(_ name: String) -> Bool

    /// Names of all external commands, used for completion and `type`/`which`.
    func availableCommands() -> [String]

    /// Runs the command and blocks until it finishes. Returns the exit status (0...255).
    /// Returns 127 when the command does not exist and 126 when it cannot be run.
    func run(_ command: ExternalCommand) -> Int32

    /// Requests that whatever is currently running on behalf of this executor stops (Ctrl-C).
    /// Called from the UI thread while `run` is blocked on another thread.
    func interruptRunningCommand()

    /// Where keystrokes should go while a command runs. Called on the UI thread for every
    /// input chunk. The default forwards everything to the command's stdin pipe in cooked mode.
    func inputRouting() -> CommandInputRouting
}

/// How keyboard input is delivered while an external command is running.
public enum CommandInputRouting: Equatable, Sendable {
    /// Local line editing, echo and history; the finished line (plus newline) goes to stdin.
    case cooked
    /// Every byte goes straight to the command's stdin (vim, less, ssh sessions).
    case raw
    /// Every byte goes to a separate descriptor (ios_system's tty pipe, used for password prompts).
    case rawToDescriptor(Int32)
}

public extension CommandExecutor {
    func inputRouting() -> CommandInputRouting { .cooked }
}

/// Reserved exit statuses, matching POSIX shells.
public enum ExitStatus {
    public static let success: Int32 = 0
    public static let failure: Int32 = 1
    public static let misuse: Int32 = 2
    public static let cannotExecute: Int32 = 126
    public static let notFound: Int32 = 127
    public static let interrupted: Int32 = 130
}
