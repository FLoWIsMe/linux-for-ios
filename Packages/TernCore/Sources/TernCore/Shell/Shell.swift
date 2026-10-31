import Foundation

/// Result of checking whether a chunk of input forms a complete program.
public enum ParseState: Equatable, Sendable {
    /// The input can be executed as is.
    case complete
    /// More input is needed (unterminated quote, open `if`, trailing `|` or `\`). `hint` names what is
    /// open, for the continuation prompt: `quote`, `dquote`, `if`, `for`, `while`, `case`, `{`, `(`, `pipe`, `heredoc`...
    case incomplete(hint: String)
    /// The input can never become valid; `message` is the diagnostic to show.
    case error(message: String)
}

/// Shell options settable with `set -e` style flags.
public struct ShellOptions: Equatable, Sendable {
    /// `-e`: exit when a command fails.
    public var errexit = false
    /// `-x`: print commands before running them.
    public var xtrace = false
    /// `-u`: error on unset variables.
    public var nounset = false
    /// `-f`: disable pathname expansion.
    public var noglob = false
    /// `-C`: `>` does not overwrite existing files.
    public var noclobber = false
    /// `-a`: export every assignment.
    public var allexport = false
    /// `-o pipefail`: a pipeline fails if any stage fails.
    public var pipefail = false
    /// `-v`: echo input lines as read.
    public var verbose = false
    public init() {}
}

/// A thread safe copy of the state the UI needs for completion, highlighting and the prompt.
public struct ShellSnapshot: Sendable {
    public var workingDirectory: String
    public var homeDirectory: String
    public var previousDirectory: String?
    public var aliases: [String: String]
    public var functionNames: [String]
    public var variableNames: [String]
    public var environment: [String: String]
    public var builtinNames: [String]
    public var externalCommandNames: [String]
    public var hostCommandNames: [String]
    public var lastExitStatus: Int32
    public var isRunningCommand: Bool

    public init(
        workingDirectory: String,
        homeDirectory: String,
        previousDirectory: String? = nil,
        aliases: [String: String] = [:],
        functionNames: [String] = [],
        variableNames: [String] = [],
        environment: [String: String] = [:],
        builtinNames: [String] = [],
        externalCommandNames: [String] = [],
        hostCommandNames: [String] = [],
        lastExitStatus: Int32 = 0,
        isRunningCommand: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.homeDirectory = homeDirectory
        self.previousDirectory = previousDirectory
        self.aliases = aliases
        self.functionNames = functionNames
        self.variableNames = variableNames
        self.environment = environment
        self.builtinNames = builtinNames
        self.externalCommandNames = externalCommandNames
        self.hostCommandNames = hostCommandNames
        self.lastExitStatus = lastExitStatus
        self.isRunningCommand = isRunningCommand
    }

    /// Every name that can start a simple command: aliases, functions, builtins, host and external commands.
    public var allCommandNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in aliases.keys.sorted() + functionNames + builtinNames + hostCommandNames + externalCommandNames {
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }
}

/// The POSIX style shell interpreter.
///
/// `Shell` parses and runs scripts and interactive lines. It owns variables, functions, aliases
/// and the working directory of one session. External commands go through the `CommandExecutor`;
/// everything the shell language itself provides (control flow, expansions, redirections,
/// pipelines, builtins) is implemented here in pure Swift so it behaves identically on iOS,
/// macOS and Linux.
///
/// Threading: `run` and `runFile` block the calling thread (the session's shell thread) until the
/// program finishes. `interrupt` and `snapshot` may be called from any thread.
///
/// Supported language (see docs/SHELL.md for the full list): quoting ('...', "...", \), comments,
/// `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR:=default}`, `${VAR:?msg}`, `${VAR:+alt}`, `${#VAR}`,
/// `${VAR#pat}`, `${VAR##pat}`, `${VAR%pat}`, `${VAR%%pat}`, `${VAR/pat/repl}`, positional and special
/// parameters (`$0`-`$9`, `${10}`, `$#`, `$@`, `$*`, `$?`, `$$`, `$!`, `$-`, `$_`), `$(cmd)`, backticks,
/// `$((expr))`, tilde expansion, globbing (`*`, `?`, `[...]`, `**`), brace expansion (`{a,b}`, `{1..5}`),
/// pipelines, `;`, `&&`, `||`, `!`, `&` (runs the pipeline concurrently), redirections (`<`, `>`, `>>`,
/// `2>`, `2>&1`, `&>`, `<<EOF` heredocs, `<<<` herestrings, `<>`), `if/elif/else`, `for`, `for ((...))`,
/// `while`, `until`, `case`, `select` is not supported, `{ ...; }`, `( ... )`, functions (`name() {}` and
/// `function name {}`), `local`, `return`, `break`, `continue`, arrays are not supported in v1.
public final class Shell {
    public static let builtinNames: [String] = [
        ".", ":", "[", "alias", "bg", "break", "builtin", "cd", "command", "continue", "dirs", "echo",
        "eval", "exec", "exit", "export", "false", "fg", "getopts", "hash", "help", "history", "jobs",
        "kill", "let", "local", "popd", "printf", "pushd", "pwd", "read", "readonly", "return", "set",
        "shift", "source", "test", "times", "trap", "true", "type", "ulimit", "umask", "unalias", "unset",
        "wait", "which",
    ]

    public let executor: CommandExecutor
    public weak var host: ShellHost?
    public var homeDirectory: String

    /// The directory new commands run in. Always absolute.
    public var workingDirectory: String { fatalError("implemented by the interpreter") }
    public var lastExitStatus: Int32 { fatalError("implemented by the interpreter") }
    public var options: ShellOptions {
        get { fatalError("implemented by the interpreter") }
        set { fatalError("implemented by the interpreter") }
    }
    /// True while `run` or `runFile` is executing on the shell thread.
    public var isRunning: Bool { fatalError("implemented by the interpreter") }

    /// - Parameters:
    ///   - executor: runs external commands.
    ///   - host: the interactive session (or a test harness).
    ///   - environment: initial exported variables. `HOME`, `PATH`, `PWD`, `SHELL`, `TERM`, `USER` are filled in
    ///     with sensible defaults when missing.
    ///   - workingDirectory: initial directory; falls back to `homeDirectory` if it does not exist.
    ///   - homeDirectory: what `~` and `cd` with no arguments resolve to.
    public init(
        executor: CommandExecutor,
        host: ShellHost?,
        environment: [String: String],
        workingDirectory: String,
        homeDirectory: String
    ) {
        self.executor = executor
        self.host = host
        self.homeDirectory = homeDirectory
        fatalError("implemented by the interpreter")
    }

    /// Parses and runs `source` as a complete program. Blocks until done. Returns the exit status of the
    /// last command run. Syntax errors are reported on the host's error stream and return 2.
    @discardableResult
    public func run(_ source: String, scriptName: String = "tsh") -> Int32 {
        fatalError("implemented by the interpreter")
    }

    /// Runs a script file with `$0` set to `path` and `$1...` set to `arguments`.
    @discardableResult
    public func runFile(atPath path: String, arguments: [String] = []) -> Int32 {
        fatalError("implemented by the interpreter")
    }

    /// Runs `source` with stdout captured and returned (used by command substitution and by hosts that
    /// want a command's output as a string, for example the prompt's git branch lookup).
    public func capture(_ source: String) -> (output: String, status: Int32) {
        fatalError("implemented by the interpreter")
    }

    /// Whether `source` is a complete program, needs more lines, or is unrecoverable.
    public static func parseState(of source: String) -> ParseState {
        fatalError("implemented by the interpreter")
    }

    /// Stops the currently running program as soon as possible: the running external command is
    /// interrupted through the executor, loops stop, and `run` returns 130. Safe from any thread.
    public func interrupt() {
        fatalError("implemented by the interpreter")
    }

    /// A consistent copy of the state needed by completion, highlighting and the prompt. Safe from any thread.
    public func snapshot() -> ShellSnapshot {
        fatalError("implemented by the interpreter")
    }

    /// Reads a variable (shell or environment). Safe from any thread.
    public func value(of name: String) -> String? {
        fatalError("implemented by the interpreter")
    }

    /// Sets a variable, optionally exporting it. Safe from any thread between commands.
    public func setValue(_ value: String, for name: String, exported: Bool = false) {
        fatalError("implemented by the interpreter")
    }

    /// Expands `~`, `$VAR` and relative paths against the working directory. Used by the UI (file pickers,
    /// completion) so paths resolve exactly like the shell would.
    public func resolvePath(_ path: String) -> String {
        fatalError("implemented by the interpreter")
    }
}
