import Foundation
import ios_system
import TernCore

/// Runs external commands with ios_system.
///
/// One executor exists per terminal session. ios_system identifies sessions by a stable C string
/// pointer, so the executor owns one (`sessionID`) for its whole life and never frees it.
///
/// Threading: `run` is called on the shell thread or on pipeline worker threads and blocks until
/// the command ends. `interruptRunningCommand` and `inputRouting` are called on the main thread.
final class IOSSystemExecutor: CommandExecutor {
    let sessionName: String
    let sessionID: UnsafeMutablePointer<CChar>

    private let lock = NSLock()
    private var windowSize = TerminalSize.fallback
    private var ttyWriteDescriptor: Int32 = -1
    private var rawInputRequested = false
    private var runningCommands = 0
    private var cachedCommands: [String]?

    /// Set by the session so interactive callbacks can flip the keyboard mode.
    weak var session: ShellSession?

    init(sessionName: String) {
        self.sessionName = sessionName
        self.sessionID = strdup(sessionName)
        ExecutorRegistry.shared.register(self)
    }

    deinit {
        ExecutorRegistry.shared.unregister(self)
        // sessionID is intentionally leaked: ios_system may still hold the pointer in its session table.
    }

    // MARK: Window size

    func setWindowSize(_ size: TerminalSize) {
        lock.lock()
        windowSize = size
        lock.unlock()
        // The iOS ports have no TIOCGWINSZ: vim and friends read LINES and COLUMNS when the
        // SIGWINCH that ios_setWindowSize sends arrives, so the variables must change first.
        setenv("COLUMNS", String(size.columns), 1)
        setenv("LINES", String(size.rows), 1)
        ios_setWindowSize(Int32(size.columns), Int32(size.rows), sessionID)
    }

    // MARK: Interactive state (driven by ios_system callbacks)

    func setInteractive(_ interactive: Bool) {
        lock.lock()
        rawInputRequested = interactive
        let session = self.session
        lock.unlock()
        session?.setRawInput(interactive)
    }

    var isInteractive: Bool {
        lock.lock(); defer { lock.unlock() }
        return rawInputRequested
    }

    // MARK: CommandExecutor

    func commandExists(_ name: String) -> Bool {
        if SystemEnvironment.unavailableReason(for: name) != nil { return true }
        return ios_executable(name) != 0
    }

    func availableCommands() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedCommands { return cached }
        let names = (commandsAsArray() as? [String]) ?? []
        let filtered = names.filter { SystemEnvironment.unavailableReason(for: $0) == nil }.sorted()
        cachedCommands = filtered
        return filtered
    }

    func run(_ command: ExternalCommand) -> Int32 {
        guard let name = command.argv.first else { return ExitStatus.misuse }

        if let reason = SystemEnvironment.unavailableReason(for: name) {
            let message = "tsh: \(name) is not included in this build (\(reason)). It is available on a real device.\n"
            FileDescriptorIO.writeAll(command.stderr, message)
            return ExitStatus.notFound
        }

        // Duplicate the descriptors so closing our FILE handles never touches the shell's own.
        let inFD = dup(command.stdin)
        let outFD = dup(command.stdout)
        let errFD = dup(command.stderr)
        guard inFD >= 0, outFD >= 0, errFD >= 0,
              let input = fdopen(inFD, "r"),
              let output = fdopen(outFD, "w"),
              let error = fdopen(errFD, "w") else {
            FileDescriptorIO.writeAll(command.stderr, "tsh: \(name): could not open standard streams\n")
            [inFD, outFD, errFD].forEach { if $0 >= 0 { close($0) } }
            return ExitStatus.cannotExecute
        }
        // A terminal is line buffered for stdout and unbuffered for stderr; mirror that so output
        // appears as it is produced instead of in 4 KB chunks.
        setvbuf(output, nil, _IOLBF, 0)
        setvbuf(error, nil, _IONBF, 0)

        // The tty pipe receives keystrokes while a command owns the terminal (password prompts, less).
        let tty = FileDescriptorIO.makePipe()
        let ttyFile = tty.flatMap { fdopen($0.read, "r") }

        lock.lock()
        runningCommands += 1
        if let tty { ttyWriteDescriptor = tty.write }
        let size = windowSize
        lock.unlock()

        ios_switchSession(sessionID)
        ios_setContext(sessionID)
        EnvironmentSync.shared.apply(command.environment)
        setenv("COLUMNS", "\(size.columns)", 1)
        setenv("LINES", "\(size.rows)", 1)
        ios_setWindowSize(Int32(size.columns), Int32(size.rows), sessionID)
        if chdir(command.workingDirectory) != 0 {
            chdir(SystemEnvironment.homeDirectory)
        }
        tern_set_thread_streams(input, output, error, UnsafeRawPointer(sessionID))
        ios_setStreams(input, output, error)
        if let ttyFile { ios_settty(ttyFile) }

        let line = IOSSystemQuoting.commandLine(command.argv)
        let pid = ios_fork()
        var status = ios_system(line)
        ios_waitpid(pid)
        ios_releaseThreadId(pid)
        if status == 0 {
            status = ios_getCommandStatus()
        }

        fflush(output)
        fflush(error)
        tern_clear_thread_streams()
        fclose(input)
        fclose(output)
        fclose(error)

        lock.lock()
        runningCommands -= 1
        let lastCommandFinished = runningCommands == 0
        if let tty, ttyWriteDescriptor == tty.write { ttyWriteDescriptor = -1 }
        if lastCommandFinished { rawInputRequested = false }
        lock.unlock()
        if let ttyFile { fclose(ttyFile) }
        if let tty { close(tty.write) }
        if lastCommandFinished {
            session?.setRawInput(false)
        }

        return status
    }

    func interruptRunningCommand() {
        ios_switchSession(sessionID)
        ios_setContext(sessionID)
        _ = ios_kill()
    }

    func inputRouting() -> CommandInputRouting {
        lock.lock()
        let raw = rawInputRequested
        let tty = ttyWriteDescriptor
        lock.unlock()
        ios_switchSession(sessionID)
        if ios_activePager() != 0, tty >= 0 {
            return .rawToDescriptor(tty)
        }
        return raw ? .raw : .cooked
    }
}

/// Builds the command line ios_system expects. ios_system re-parses its input and expands `$VAR`
/// and `~` in unquoted words, so every argument is wrapped the same way ios_system's own
/// `concatenateArgv` wraps arguments when programs call exec: double quotes when the argument has
/// none, single quotes otherwise, and the ASCII record separator (0x1e) as a last resort. Quoted
/// arguments are never expanded again, which keeps the shell's expansion authoritative.
enum IOSSystemQuoting {
    static let recordSeparator: Character = "\u{1e}"

    static func commandLine(_ argv: [String]) -> String {
        guard let first = argv.first else { return "" }
        var line = first
        for argument in argv.dropFirst() {
            line += " "
            line += quote(argument)
        }
        return line
    }

    static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "\"\"" }
        let hasDouble = argument.contains("\"")
        let hasSingle = argument.contains("'")
        let hasBackslash = argument.contains("\\")
        let hasRS = argument.contains(recordSeparator)
        if !hasDouble && !hasBackslash {
            return "\"" + argument + "\""
        }
        if !hasSingle && !hasBackslash {
            return "'" + argument + "'"
        }
        if !hasRS {
            return String(recordSeparator) + argument + String(recordSeparator)
        }
        // Pathological: contains both quote kinds, a backslash and a record separator. Escape spaces.
        return argument.replacingOccurrences(of: " ", with: "\\ ")
    }
}

/// Keeps the process environment in step with the shell's exported variables before each command.
/// The environment is process wide, so this is applied right before every external command runs.
final class EnvironmentSync {
    static let shared = EnvironmentSync()
    private let lock = NSLock()
    private var lastApplied: [String: String] = [:]

    /// Variables ios_system or the app manage themselves; the shell must not override them.
    private let protected: Set<String> = ["COLUMNS", "LINES", "ROWS", "PWD", "OLDPWD", "APPDIR", "TERMINFO", "VIMRUNTIME", "VIM"]

    func apply(_ environment: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        for (key, value) in environment where !protected.contains(key) {
            if lastApplied[key] != value {
                setenv(key, value, 1)
            }
        }
        for key in lastApplied.keys where environment[key] == nil && !protected.contains(key) {
            unsetenv(key)
        }
        lastApplied = environment
    }
}

/// Maps ios_system session contexts back to executors, so the C callbacks ios_system invokes
/// (`startInteractive` and friends) can find the right session.
final class ExecutorRegistry {
    static let shared = ExecutorRegistry()
    private let lock = NSLock()
    private var executors: [UnsafeMutablePointer<CChar>: WeakExecutor] = [:]

    private struct WeakExecutor {
        weak var executor: IOSSystemExecutor?
    }

    func register(_ executor: IOSSystemExecutor) {
        lock.lock(); defer { lock.unlock() }
        executors[executor.sessionID] = WeakExecutor(executor: executor)
    }

    func unregister(_ executor: IOSSystemExecutor) {
        lock.lock(); defer { lock.unlock() }
        executors[executor.sessionID] = nil
    }

    /// The executor whose session context matches `context` (a pointer handed out as `sessionID`).
    func executor(for context: UnsafeRawPointer?) -> IOSSystemExecutor? {
        lock.lock(); defer { lock.unlock() }
        guard let context else { return nil }
        let name = String(cString: context.assumingMemoryBound(to: CChar.self))
        for (_, entry) in executors {
            if let executor = entry.executor, executor.sessionName == name {
                return executor
            }
        }
        return nil
    }

    /// Fallback when ios_system gives us no context: the executor with a command running.
    func busyExecutor() -> IOSSystemExecutor? {
        lock.lock(); defer { lock.unlock() }
        return executors.values.compactMap { $0.executor }.first
    }
}

// MARK: - C callbacks ios_system looks up with dlsym

private func executorForCurrentThread() -> IOSSystemExecutor? {
    if let executor = ExecutorRegistry.shared.executor(for: tern_thread_context()) {
        return executor
    }
    if let context = ios_getContext(), let executor = ExecutorRegistry.shared.executor(for: context) {
        return executor
    }
    return ExecutorRegistry.shared.busyExecutor()
}

/// ios_system calls this when a command that owns the keyboard starts (vim, less, ssh, scp, sftp).
@_cdecl("startInteractive")
public func ternStartInteractive() {
    executorForCurrentThread()?.setInteractive(true)
}

/// ios_system calls this when such a command hands the keyboard back.
@_cdecl("stopInteractive")
public func ternStopInteractive() {
    executorForCurrentThread()?.setInteractive(false)
}

/// ios_system asks for the current state so nested commands (dash) can restore it afterwards.
@_cdecl("storeInteractive")
public func ternStoreInteractive() -> Int32 {
    (executorForCurrentThread()?.isInteractive ?? false) ? 1 : 0
}
