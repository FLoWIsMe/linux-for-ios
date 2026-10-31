#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs external commands as real processes. Used on macOS and Linux (tests, command line tools);
/// the iOS app provides an ios_system backed executor instead.
public final class ProcessCommandExecutor: CommandExecutor {
    private let lock = NSLock()
    private var runningPIDs: Set<pid_t> = []
    private var runningNames: [pid_t: String] = [:]
    private var cachedCommands: [String]?
    private var cachedPath: String?
    /// Commands that take over the terminal and must receive raw keystrokes.
    public var interactiveCommands: Set<String> = ["vim", "vi", "nvim", "less", "more", "ssh", "nano", "top", "htop", "man"]
    private let searchPath: String
    private let spawnLock = NSLock()

    public init(path: String? = nil) {
        self.searchPath = path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        signal(SIGPIPE, SIG_IGN)
    }

    public func commandExists(_ name: String) -> Bool {
        resolve(name) != nil
    }

    public func availableCommands() -> [String] {
        lock.lock()
        if let cachedCommands, cachedPath == searchPath {
            lock.unlock()
            return cachedCommands
        }
        lock.unlock()
        var names = Set<String>()
        let fileManager = FileManager.default
        for directory in searchPath.split(separator: ":") {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: String(directory)) else { continue }
            for entry in entries where fileManager.isExecutableFile(atPath: "\(directory)/\(entry)") {
                names.insert(entry)
            }
        }
        let sorted = names.sorted()
        lock.lock()
        cachedCommands = sorted
        cachedPath = searchPath
        lock.unlock()
        return sorted
    }

    public func run(_ command: ExternalCommand) -> Int32 {
        guard let path = resolve(command.argv[0], workingDirectory: command.workingDirectory) else {
            FileDescriptorIO.writeAll(command.stderr, "\(command.argv[0]): command not found\n")
            return ExitStatus.notFound
        }

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, command.stdin, 0)
        posix_spawn_file_actions_adddup2(&fileActions, command.stdout, 1)
        posix_spawn_file_actions_adddup2(&fileActions, command.stderr, 2)
        #if canImport(Darwin)
        posix_spawn_file_actions_addchdir_np(&fileActions, command.workingDirectory)
        #endif

        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags: Int32 = Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        sigaddset(&defaultSignals, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv: [UnsafeMutablePointer<CChar>?] = command.argv.map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in environment { free(pointer) }
        }

        var pid: pid_t = 0
        #if !canImport(Darwin)
        // glibc may lack posix_spawn_file_actions_addchdir_np; change directory around the spawn instead.
        spawnLock.lock()
        let previousDirectory = FileManager.default.currentDirectoryPath
        chdir(command.workingDirectory)
        #endif
        let spawnResult = argv.withUnsafeBufferPointer { argvBuffer in
            environment.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, path, &fileActions, &attributes, argvBuffer.baseAddress, envBuffer.baseAddress)
            }
        }
        #if !canImport(Darwin)
        chdir(previousDirectory)
        spawnLock.unlock()
        #endif
        guard spawnResult == 0 else {
            FileDescriptorIO.writeAll(command.stderr, "\(command.argv[0]): \(String(cString: strerror(spawnResult)))\n")
            return spawnResult == ENOENT ? ExitStatus.notFound : ExitStatus.cannotExecute
        }

        lock.lock()
        runningPIDs.insert(pid)
        runningNames[pid] = URL(fileURLWithPath: command.argv[0]).lastPathComponent
        lock.unlock()
        defer {
            lock.lock()
            runningPIDs.remove(pid)
            runningNames.removeValue(forKey: pid)
            lock.unlock()
        }

        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == -1 && errno == EINTR { continue }
            break
        }
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    public func interruptRunningCommand() {
        lock.lock()
        let pids = runningPIDs
        lock.unlock()
        for pid in pids {
            kill(pid, SIGINT)
        }
    }

    public func inputRouting() -> CommandInputRouting {
        lock.lock(); defer { lock.unlock() }
        if runningNames.values.contains(where: { interactiveCommands.contains($0) }) {
            return .raw
        }
        return .cooked
    }

    /// Finds the executable for `name`: absolute and relative paths are checked directly, bare names
    /// are searched in PATH.
    public func resolve(_ name: String, workingDirectory: String? = nil) -> String? {
        let fileManager = FileManager.default
        if name.contains("/") {
            var path = name
            if !path.hasPrefix("/"), let workingDirectory {
                path = workingDirectory + "/" + name
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in searchPath.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue, fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
#endif
