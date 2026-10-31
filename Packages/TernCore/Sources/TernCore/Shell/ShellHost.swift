import Foundation

/// Terminal dimensions in character cells.
public struct TerminalSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
    public static let fallback = TerminalSize(columns: 80, rows: 24)
}

/// The standard streams a builtin or host command writes to. Descriptors are owned by the shell.
public struct ShellIO: Sendable {
    public var stdin: Int32
    public var stdout: Int32
    public var stderr: Int32

    public init(stdin: Int32, stdout: Int32, stderr: Int32) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Writes the whole string to stdout, retrying on partial writes.
    public func writeOut(_ text: String) { FileDescriptorIO.writeAll(stdout, text) }
    /// Writes the whole string to stderr.
    public func writeErr(_ text: String) { FileDescriptorIO.writeAll(stderr, text) }
}

/// Small helpers for blocking descriptor IO shared by the interpreter, the session and tests.
public enum FileDescriptorIO {
    public static func writeAll(_ fd: Int32, _ text: String) {
        var bytes = Array(text.utf8)
        writeAll(fd, &bytes)
    }

    public static func writeAll(_ fd: Int32, _ bytes: inout [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                #if canImport(Darwin)
                return Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                #else
                return Glibc.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                #endif
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            offset += written
        }
    }

    /// Reads until EOF. Used by command substitution and tests.
    public static func readAll(_ fd: Int32) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, pointer.baseAddress!, pointer.count)
                #else
                return Glibc.read(fd, pointer.baseAddress!, pointer.count)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    /// Creates a pipe. Returns (readEnd, writeEnd) with close-on-exec set.
    public static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { pointer in pipe(pointer.baseAddress!) }
        guard result == 0 else { return nil }
        #if canImport(Darwin)
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        #endif
        return (fds[0], fds[1])
    }

    public static func closeQuietly(_ fd: Int32) {
        guard fd >= 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}

/// Services the interpreter needs from whatever is hosting it: the interactive session in the
/// app, or a test harness. Most calls happen on the shell thread (the thread running `Shell.run`),
/// but every stage of a pipeline runs on a thread of its own, so `shellWillRun`,
/// `shellDidFinish`, `openTerminalInput` and `runHostCommand` can arrive concurrently from
/// several threads. Implementations must be thread safe.
public protocol ShellHost: AnyObject {
    /// Current terminal size, for builtins that lay out columns.
    var terminalSize: TerminalSize { get }

    /// Blocking request for one line of user input in cooked mode (the `read` builtin, and
    /// continuation lines when a script is incomplete). Returns nil on end of input (Ctrl-D).
    /// `secure` hides the echo (passwords).
    func readLine(prompt: String, secure: Bool) -> String?

    /// Opens a fresh descriptor connected to the keyboard for an external command whose stdin is
    /// the terminal. The host keeps the write side and routes keystrokes into it until
    /// `closeTerminalInput` is called. Returns nil if the host has no interactive input (scripts).
    func openTerminalInput() -> Int32?
    func closeTerminalInput(_ fd: Int32)

    /// The descriptor builtins should write to when their stdout is "the terminal".
    var terminalOutput: Int32 { get }
    var terminalError: Int32 { get }

    /// Called before and after every external command, so the UI can switch keyboard modes,
    /// keep the device awake, and show the running command's name.
    func shellWillRun(externalCommand argv: [String])
    func shellDidFinish(externalCommand argv: [String], status: Int32)

    /// `exit` at the top level of the interactive shell.
    func shellDidRequestExit(status: Int32)

    /// The working directory changed (cd, pushd, popd), for prompt and title updates.
    func shellDidChangeDirectory(_ path: String)

    /// Lets the host implement app specific commands (`tern`, `open`, `pbcopy`, `help`).
    /// Return nil when the command is not a host command so the shell keeps resolving it.
    func runHostCommand(_ argv: [String], io: ShellIO) -> Int32?

    /// Names of host commands for completion and `type`.
    func hostCommandNames() -> [String]
}

public extension ShellHost {
    func shellWillRun(externalCommand argv: [String]) {}
    func shellDidFinish(externalCommand argv: [String], status: Int32) {}
    func shellDidChangeDirectory(_ path: String) {}
    func runHostCommand(_ argv: [String], io: ShellIO) -> Int32? { nil }
    func hostCommandNames() -> [String] { [] }
}
