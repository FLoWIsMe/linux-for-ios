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

    // ios_system decides whether a stream "is a terminal" by comparing a command's stream with
    // the session's stream (ios_isatty), and it keeps one set of session streams per session.
    // Pipeline stages run concurrently, so the session streams must not change per command:
    // they are three long lived FILE handles on the terminal, and only a command whose stdout,
    // stderr or stdin really is the terminal uses them. Everything else (pipes, files) gets a
    // private handle, which is exactly what makes `ls | less` page and `ls > file` stay plain.
    private var terminalOutput: UnsafeMutablePointer<FILE>?
    private var terminalError: UnsafeMutablePointer<FILE>?
    private var terminalOutputDescriptor: Int32 = -1
    private var terminalErrorDescriptor: Int32 = -1
    /// The session's stdin keeps one descriptor number for its whole life; the pipe the host
    /// opens for a command that reads the keyboard is dup2'ed onto it for that command's run.
    private var terminalInput: UnsafeMutablePointer<FILE>?
    private var terminalInputDescriptor: Int32 = -1
    private var idleInput: (read: Int32, write: Int32)?
    /// The tty pipe ios_system reads password prompts and pager keys from. One per session for
    /// the same reason: a pipeline stage that ended used to close the tty under the pager.
    private var ttyFile: UnsafeMutablePointer<FILE>?
    private var ttyPipe: (read: Int32, write: Int32)?

    /// Set by the session so interactive callbacks can flip the keyboard mode.
    weak var session: ShellSession?

    init(sessionName: String) {
        self.sessionName = sessionName
        self.sessionID = strdup(sessionName)
        ExecutorRegistry.shared.register(self)
    }

    deinit {
        ExecutorRegistry.shared.unregister(self)
        if let terminalOutput { fclose(terminalOutput) }
        if let terminalError { fclose(terminalError) }
        if let terminalInput { fclose(terminalInput) }
        if let idleInput { close(idleInput.read); close(idleInput.write) }
        if let ttyFile { fclose(ttyFile) }
        if let ttyPipe { close(ttyPipe.write) }
        // sessionID is intentionally leaked: ios_system may still hold the pointer in its session table.
    }

    // MARK: Session streams

    /// Returns the shared terminal handles, creating them from the host's descriptors on first use.
    private func sessionStreams(output outputFD: Int32, error errorFD: Int32) -> (input: UnsafeMutablePointer<FILE>, output: UnsafeMutablePointer<FILE>, error: UnsafeMutablePointer<FILE>)? {
        lock.lock(); defer { lock.unlock() }
        if terminalOutput == nil || terminalOutputDescriptor != outputFD {
            if let old = terminalOutput { fclose(old) }
            let fd = dup(outputFD)
            guard fd >= 0, let file = fdopen(fd, "w") else { return nil }
            setvbuf(file, nil, _IOLBF, 0)
            terminalOutput = file
            terminalOutputDescriptor = outputFD
        }
        if terminalError == nil || terminalErrorDescriptor != errorFD {
            if let old = terminalError { fclose(old) }
            let fd = dup(errorFD)
            guard fd >= 0, let file = fdopen(fd, "w") else { return nil }
            setvbuf(file, nil, _IONBF, 0)
            terminalError = file
            terminalErrorDescriptor = errorFD
        }
        if terminalInput == nil {
            // A pipe nobody writes to: reading the session stdin while no command owns the
            // keyboard simply blocks, like an idle terminal. The session stdin is a separate
            // descriptor number so it can be pointed at a command's keyboard pipe and back.
            guard let idle = FileDescriptorIO.makePipe() else { return nil }
            let descriptor = dup(idle.read)
            guard descriptor >= 0, let file = fdopen(descriptor, "r") else {
                FileDescriptorIO.closeQuietly(idle.read)
                FileDescriptorIO.closeQuietly(idle.write)
                return nil
            }
            idleInput = idle
            terminalInputDescriptor = descriptor
            terminalInput = file
        }
        if ttyFile == nil {
            guard let pipe = FileDescriptorIO.makePipe(), let file = fdopen(pipe.read, "r") else { return nil }
            ttyPipe = pipe
            ttyFile = file
            ttyWriteDescriptor = pipe.write
        }
        guard let terminalInput, let terminalOutput, let terminalError else { return nil }
        return (terminalInput, terminalOutput, terminalError)
    }

    /// Throws away keystrokes a previous command left in the tty pipe.
    private func drainTTY() {
        lock.lock()
        let file = ttyFile
        let descriptor = ttyPipe?.read ?? -1
        lock.unlock()
        guard let file, descriptor >= 0 else { return }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var scratch = [UInt8](repeating: 0, count: 4096)
        while read(descriptor, &scratch, scratch.count) > 0 {}
        _ = fcntl(descriptor, F_SETFL, flags)
        fpurge(file)
        clearerr(file)
    }

    // MARK: Window size

    func setWindowSize(_ size: TerminalSize) {
        lock.lock()
        windowSize = size
        lock.unlock()
        // The iOS ports have no TIOCGWINSZ: vim and friends read LINES and COLUMNS when the
        // SIGWINCH that ios_setWindowSize sends arrives, so the variables must change first. A
        // running command reads its own copy of the environment (getenv is ios_getenv inside the
        // frameworks), hence ios_setenv as well as setenv for commands started later.
        setenv("COLUMNS", String(size.columns), 1)
        setenv("LINES", String(size.rows), 1)
        ios_setenv("COLUMNS", String(size.columns), 1)
        ios_setenv("LINES", String(size.rows), 1)
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
        // ios_executable runs the name through basename(3), whose result lives in a static
        // buffer; pipeline stages resolve their commands at the same time, so serialize the calls.
        lock.lock(); defer { lock.unlock() }
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

        let terminalOutputFD = session?.terminalOutput ?? command.stdout
        let terminalErrorFD = session?.terminalError ?? command.stderr
        guard let sessionStreams = sessionStreams(output: terminalOutputFD, error: terminalErrorFD) else {
            FileDescriptorIO.writeAll(command.stderr, "tsh: \(name): could not open the terminal streams\n")
            return ExitStatus.cannotExecute
        }

        // Streams that are the terminal share the session handles; anything else gets a private
        // handle on a duplicated descriptor, so closing it never touches the shell's own.
        var ownedFiles: [UnsafeMutablePointer<FILE>] = []
        func privateStream(_ fd: Int32, mode: String, lineBuffered: Bool) -> UnsafeMutablePointer<FILE>? {
            let copy = dup(fd)
            guard copy >= 0 else { return nil }
            guard let file = fdopen(copy, mode) else { close(copy); return nil }
            // Line buffering keeps pipelines streaming; a terminal is line buffered anyway.
            setvbuf(file, nil, lineBuffered ? _IOLBF : _IONBF, 0)
            ownedFiles.append(file)
            return file
        }
        let stdoutIsTerminal = command.stdoutIsTerminal || command.stdout == terminalOutputFD
        let stderrIsTerminal = command.stderr == terminalErrorFD || command.stderr == terminalOutputFD
        let output = stdoutIsTerminal ? sessionStreams.output : privateStream(command.stdout, mode: "w", lineBuffered: true)
        let error = stderrIsTerminal ? (command.stderr == terminalOutputFD ? sessionStreams.output : sessionStreams.error)
            : privateStream(command.stderr, mode: "w", lineBuffered: false)
        var input: UnsafeMutablePointer<FILE>?
        if command.stdinIsTerminal {
            // The host's keyboard pipe takes over the session stdin descriptor for this run.
            lock.lock()
            let target = terminalInputDescriptor
            lock.unlock()
            if dup2(command.stdin, target) >= 0 {
                fpurge(sessionStreams.input)
                clearerr(sessionStreams.input)
                input = sessionStreams.input
            }
        } else {
            input = privateStream(command.stdin, mode: "r", lineBuffered: true)
        }
        guard let input, let output, let error else {
            FileDescriptorIO.writeAll(command.stderr, "tsh: \(name): could not open standard streams\n")
            ownedFiles.forEach { fclose($0) }
            return ExitStatus.cannotExecute
        }

        lock.lock()
        runningCommands += 1
        let firstCommand = runningCommands == 1
        let size = windowSize
        let ttyFile = self.ttyFile
        lock.unlock()
        if firstCommand { drainTTY() }

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
        ios_setStreams(sessionStreams.input, sessionStreams.output, sessionStreams.error)
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
        ownedFiles.forEach { fclose($0) }
        if command.stdinIsTerminal, let idleInput {
            // Hand the session stdin back to the idle pipe and drop what the command left unread.
            lock.lock()
            let target = terminalInputDescriptor
            lock.unlock()
            fpurge(sessionStreams.input)
            dup2(idleInput.read, target)
        }

        lock.lock()
        runningCommands -= 1
        let lastCommandFinished = runningCommands == 0
        if lastCommandFinished { rawInputRequested = false }
        lock.unlock()
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
