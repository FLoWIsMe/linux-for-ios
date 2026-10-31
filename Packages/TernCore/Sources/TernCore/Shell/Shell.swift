import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
/// `while`, `until`, `case`, `{ ...; }`, `( ... )`, functions (`name() {}` and `function name {}`),
/// `local`, `return`, `break`, `continue`. Arrays and `select` are not supported in v1.
public final class Shell {
    public static let builtinNames: [String] = [
        ".", ":", "[", "alias", "bg", "break", "builtin", "cd", "clear", "command", "continue", "cut", "declare",
        "dirs", "echo", "eval", "exec", "exit", "export", "false", "fg", "getopts", "hash", "help", "history",
        "jobs", "kill", "let", "local", "mktemp", "popd", "printf", "pushd", "pwd", "read", "readonly", "realpath",
        "return", "rev", "seq", "set", "shift", "source", "tac", "test", "times", "trap", "true", "tty", "type",
        "typeset", "ulimit", "umask", "unalias", "unset", "wait", "which", "yes",
    ]

    /// `$0` of the interactive shell. Scripts and sourced files use their own names.
    static let interactiveScriptName = "tsh"

    public let executor: CommandExecutor
    public weak var host: ShellHost?
    public var homeDirectory: String

    /// True for a shell driven by a person. Affects whether an unbound variable (`set -u`) or a failed
    /// `exit` ends the whole shell, and whether background jobs announce themselves.
    public var isInteractive = true

    private let interpreter: Interpreter
    private let jobs = JobTable()
    private let stateLock = NSLock()
    private var interrupted = false
    private var running = false
    private var publishedSnapshot: ShellSnapshot
    private var publishedVariables: [String: String] = [:]
    private var pendingAssignments: [(name: String, value: String, exported: Bool)] = []

    /// The directory new commands run in. Always absolute.
    public var workingDirectory: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return running ? publishedSnapshot.workingDirectory : interpreter.ctx.workingDirectory
    }

    public var lastExitStatus: Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return running ? publishedSnapshot.lastExitStatus : interpreter.ctx.lastStatus
    }

    public var options: ShellOptions {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return interpreter.ctx.options
        }
        set {
            stateLock.lock(); defer { stateLock.unlock() }
            interpreter.ctx.options = newValue
        }
    }

    /// True while `run` or `runFile` is executing on the shell thread.
    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    var isInterrupted: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return interrupted
    }

    var interactiveScriptName: String { Shell.interactiveScriptName }
    var isInteractiveSession: Bool { isInteractive }

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
        signal(SIGPIPE, SIG_IGN)
        self.executor = executor
        self.host = host
        self.homeDirectory = homeDirectory

        var isDirectory: ObjCBool = false
        let startDirectory: String
        if FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
            startDirectory = PathNormalizer.normalize(workingDirectory)
        } else {
            startDirectory = PathNormalizer.normalize(homeDirectory)
        }

        var fdTable: [Int32: FDEntry] = [0: .lazyTerminalInput]
        fdTable[1] = FDEntry(fd: host?.terminalOutput ?? 1, isTerminal: true)
        fdTable[2] = FDEntry(fd: host?.terminalError ?? 2, isTerminal: true)

        var context = ShellContext(scriptName: Shell.interactiveScriptName, workingDirectory: startDirectory, fdTable: fdTable)
        var variables = environment
        func setDefault(_ name: String, _ value: String) {
            if variables[name] == nil { variables[name] = value }
        }
        setDefault("HOME", homeDirectory)
        setDefault("SHELL", "/bin/tsh")
        setDefault("TERM", "xterm-256color")
        setDefault("COLORTERM", "truecolor")
        setDefault("LANG", "en_US.UTF-8")
        setDefault("USER", "mobile")
        setDefault("LOGNAME", variables["USER"] ?? "mobile")
        setDefault("SHLVL", "1")
        setDefault("PATH", "/usr/local/bin:/usr/bin:/bin")
        setDefault("TSH_VERSION", "1.0")
        variables["PWD"] = startDirectory
        for (name, value) in variables {
            context.globals[name] = ShellVariable(value: value, exported: true)
        }
        context.globals["OPTIND"] = ShellVariable(value: "1", exported: false)
        context.globals["PS1"] = nil

        let snapshot = ShellSnapshot(workingDirectory: startDirectory, homeDirectory: homeDirectory, builtinNames: Shell.builtinNames)
        publishedSnapshot = snapshot
        interpreter = Interpreter(shell: nil, context: context, jobs: jobs)
        interpreter.shellRef = self
        publish()
    }

    // MARK: Running programs

    /// Parses and runs `source` as a complete program. Blocks until done. Returns the exit status of the
    /// last command run. Syntax errors are reported on the host's error stream and return 2.
    @discardableResult
    public func run(_ source: String, scriptName: String = "tsh") -> Int32 {
        beginRun()
        defer { endRun() }
        if scriptName != Shell.interactiveScriptName {
            let saved = interpreter.ctx.scriptName
            interpreter.ctx.scriptName = scriptName
            defer { interpreter.ctx.scriptName = saved }
            return runProgram(source, interactiveExit: true)
        }
        return runProgram(source, interactiveExit: true)
    }

    /// Runs a script file with `$0` set to `path` and `$1...` set to `arguments`.
    @discardableResult
    public func runFile(atPath path: String, arguments: [String] = []) -> Int32 {
        beginRun()
        defer { endRun() }
        let resolved = interpreter.ctx.absolutePath(path)
        guard let data = FileManager.default.contents(atPath: resolved) else {
            interpreter.reportError("\(path): No such file or directory", line: 0)
            interpreter.ctx.lastStatus = ExitStatus.notFound
            return ExitStatus.notFound
        }
        let source = String(decoding: data, as: UTF8.self)
        let savedName = interpreter.ctx.scriptName
        let savedPositional = interpreter.ctx.positional
        interpreter.ctx.scriptName = path
        interpreter.ctx.positional = arguments
        interpreter.ctx.sourceDepth += 1
        defer {
            interpreter.ctx.sourceDepth -= 1
            interpreter.ctx.scriptName = savedName
            interpreter.ctx.positional = savedPositional
        }
        let status = runProgram(source, interactiveExit: false)
        do { try interpreter.runExitTrap() } catch {}
        return status
    }

    /// Runs `source` with stdout captured and returned (used by command substitution and by hosts that
    /// want a command's output as a string, for example the prompt's git branch lookup).
    public func capture(_ source: String) -> (output: String, status: Int32) {
        beginRun()
        defer { endRun() }
        do {
            let output = try interpreter.captureOutput(of: source)
            return (output, interpreter.ctx.lastStatus)
        } catch {
            return ("", 130)
        }
    }

    private func beginRun() {
        stateLock.lock()
        interrupted = false
        running = true
        let pending = pendingAssignments
        pendingAssignments.removeAll()
        stateLock.unlock()
        for assignment in pending {
            try? interpreter.ctx.setValue(assignment.value, for: assignment.name, exported: assignment.exported)
        }
    }

    private func endRun() {
        publish()
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private func runProgram(_ source: String, interactiveExit: Bool) -> Int32 {
        let parser = Parser(source: source, aliasLookup: { [weak self] in self?.interpreter.ctx.aliases[$0] })
        var status = interpreter.ctx.lastStatus
        do {
            while true {
                try interpreter.checkInterrupt()
                guard let list = try parser.parseCompleteCommand() else { break }
                if interpreter.ctx.options.verbose {
                    FileDescriptorIO.writeAll(interpreter.errorDescriptor, source + "\n")
                }
                status = try interpreter.execute(list)
            }
        } catch let error as ParseError {
            interpreter.reportError(interpreter.describe(error), line: error.line)
            status = 2
        } catch ControlFlow.exitShell(let code) {
            status = code
            if interactiveExit {
                do { try interpreter.runExitTrap() } catch {}
                interpreter.ctx.lastStatus = status
                publish()
                host?.shellDidRequestExit(status: status)
            }
        } catch ControlFlow.errexit(let code) {
            status = code
            if !isInteractive {
                interpreter.ctx.lastStatus = status
                publish()
                host?.shellDidRequestExit(status: status)
            }
        } catch ControlFlow.interrupted {
            status = ExitStatus.interrupted
            if let handler = interpreter.ctx.traps["INT"], !handler.isEmpty {
                // The handler itself must be allowed to run after the interrupt.
                stateLock.lock()
                interrupted = false
                stateLock.unlock()
                interpreter.ctx.lastStatus = status
                _ = try? interpreter.evaluateSource(handler)
            }
        } catch ControlFlow.returnFromFunction(let code) {
            status = code
        } catch ControlFlow.breakLoop, ControlFlow.continueLoop {
            status = 0
        } catch let error as ShellRuntimeError {
            interpreter.reportError(error.message)
            status = 1
        } catch {
            interpreter.reportError("\(error)")
            status = 1
        }
        interpreter.ctx.lastStatus = status
        return status
    }

    // MARK: Parsing

    /// Whether `source` is a complete program, needs more lines, or is unrecoverable.
    public static func parseState(of source: String) -> ParseState {
        let parser = Parser(source: source)
        do {
            _ = try parser.parseAll()
            return .complete
        } catch let error as ParseError {
            switch error {
            case .incomplete(let hint, _):
                return .incomplete(hint: hint == "eof" ? "command" : hint)
            case .syntax(let message, _):
                return .error(message: message)
            }
        } catch let error as LexError {
            switch error {
            case .incomplete(let hint, _): return .incomplete(hint: hint)
            case .invalid(let message, _): return .error(message: message)
            }
        } catch {
            return .error(message: "\(error)")
        }
    }

    // MARK: Control from other threads

    /// Stops the currently running program as soon as possible: the running external command is
    /// interrupted through the executor, loops stop, and `run` returns 130. Safe from any thread.
    public func interrupt() {
        stateLock.lock()
        interrupted = true
        stateLock.unlock()
        jobs.cancelAll()
        executor.interruptRunningCommand()
    }

    /// A consistent copy of the state needed by completion, highlighting and the prompt. Safe from any thread.
    public func snapshot() -> ShellSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        var snapshot = publishedSnapshot
        snapshot.isRunningCommand = running
        return snapshot
    }

    /// Reads a variable (shell or environment). Safe from any thread.
    public func value(of name: String) -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        if !running { return interpreter.ctx.value(name) }
        return publishedVariables[name]
    }

    /// Sets a variable, optionally exporting it. Safe from any thread between commands.
    public func setValue(_ value: String, for name: String, exported: Bool = false) {
        stateLock.lock()
        if running {
            pendingAssignments.append((name, value, exported))
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        try? interpreter.ctx.setValue(value, for: name, exported: exported)
        publish()
    }

    /// Expands `~`, `$VAR` and relative paths against the working directory. Used by the UI (file pickers,
    /// completion) so paths resolve exactly like the shell would.
    public func resolvePath(_ path: String) -> String {
        stateLock.lock()
        let context = running ? nil : interpreter.ctx
        let snapshot = publishedSnapshot
        let variables = publishedVariables
        stateLock.unlock()
        var expanded = path
        if let context {
            expanded = (try? interpreter.expandSingle(Word(path))) ?? path
            return context.absolutePath(expanded)
        }
        // While a program runs, do a conservative expansion from the published copy.
        if expanded == "~" || expanded.hasPrefix("~/") {
            expanded = snapshot.homeDirectory + expanded.dropFirst()
        }
        for (name, value) in variables where expanded.contains("$" + name) {
            expanded = expanded.replacingOccurrences(of: "${" + name + "}", with: value).replacingOccurrences(of: "$" + name, with: value)
        }
        if !expanded.hasPrefix("/") {
            expanded = snapshot.workingDirectory + "/" + expanded
        }
        return PathNormalizer.normalize(expanded)
    }

    // MARK: Snapshots

    func publish() {
        let context = interpreter.ctx
        var variables: [String: String] = [:]
        for name in context.visibleVariableNames {
            if let value = context.value(name) { variables[name] = value }
        }
        let snapshot = ShellSnapshot(
            workingDirectory: context.workingDirectory,
            homeDirectory: homeDirectory,
            previousDirectory: context.previousDirectory,
            aliases: context.aliases,
            functionNames: context.functions.keys.sorted(),
            variableNames: context.visibleVariableNames,
            environment: context.exportedEnvironment(),
            builtinNames: Shell.builtinNames,
            externalCommandNames: executor.availableCommands(),
            hostCommandNames: host?.hostCommandNames() ?? [],
            lastExitStatus: context.lastStatus,
            isRunningCommand: false
        )
        stateLock.lock()
        publishedSnapshot = snapshot
        publishedVariables = variables
        stateLock.unlock()
    }
}
