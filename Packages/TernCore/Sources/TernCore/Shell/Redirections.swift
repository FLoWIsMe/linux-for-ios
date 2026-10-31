import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What `applyRedirections` changed, so it can be undone after the command.
struct RedirectionScope {
    var savedTable: [Int32: FDEntry]
    var opened: [Int32] = []
    var permanent = false
}

extension Interpreter {
    /// Resolves redirections into descriptors and installs them in the fd table.
    func applyRedirections(_ redirections: [Redirection]) throws -> RedirectionScope {
        var scope = RedirectionScope(savedTable: ctx.fdTable)
        do {
            for redirection in redirections {
                try apply(redirection, scope: &scope)
            }
        } catch {
            restoreRedirections(scope)
            throw error
        }
        return scope
    }

    func restoreRedirections(_ scope: RedirectionScope) {
        if ctx.keepRedirections {
            // `exec` without a command: the redirections stay for the rest of the shell.
            ctx.keepRedirections = false
            return
        }
        guard !scope.permanent else { return }
        ctx.fdTable = scope.savedTable
        for fd in scope.opened {
            FileDescriptorIO.closeQuietly(fd)
        }
    }

    private func apply(_ redirection: Redirection, scope: inout RedirectionScope) throws {
        let fd = redirection.effectiveFD
        switch redirection.kind {
        case .input:
            let path = try expandSingle(redirection.target)
            if let entry = specialDevice(path) {
                ctx.fdTable[fd] = entry
                return
            }
            let opened = try openFile(path, flags: O_RDONLY)
            scope.opened.append(opened)
            ctx.fdTable[fd] = FDEntry(fd: opened, isTerminal: false)

        case .output, .outputClobber, .append, .readWrite, .bothOutput, .bothAppend:
            let path = try expandSingle(redirection.target)
            if let entry = specialDevice(path) {
                ctx.fdTable[fd] = entry
                if redirection.kind == .bothOutput || redirection.kind == .bothAppend { ctx.fdTable[2] = entry }
                return
            }
            var flags: Int32
            switch redirection.kind {
            case .append, .bothAppend: flags = O_WRONLY | O_CREAT | O_APPEND
            case .readWrite: flags = O_RDWR | O_CREAT
            case .outputClobber: flags = O_WRONLY | O_CREAT | O_TRUNC
            default:
                flags = O_WRONLY | O_CREAT | O_TRUNC
                if ctx.options.noclobber {
                    let absolute = ctx.absolutePath(path)
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), !isDirectory.boolValue {
                        throw ShellRuntimeError.redirection("\(path): cannot overwrite existing file")
                    }
                    flags = O_WRONLY | O_CREAT | O_EXCL
                }
            }
            let opened = try openFile(path, flags: flags)
            scope.opened.append(opened)
            let entry = FDEntry(fd: opened, isTerminal: false)
            ctx.fdTable[fd] = entry
            if redirection.kind == .bothOutput || redirection.kind == .bothAppend {
                ctx.fdTable[2] = entry
            }

        case .duplicateInput, .duplicateOutput:
            let target = try expandSingle(redirection.target)
            if target == "-" {
                ctx.fdTable[fd] = try devNullEntry(scope: &scope)
                return
            }
            if let number = Int32(target) {
                guard let source = ctx.fdTable[number] ?? defaultEntry(for: number) else {
                    throw ShellRuntimeError.redirection("\(number): Bad file descriptor")
                }
                ctx.fdTable[fd] = source
                return
            }
            // `>&file` is `&>file`; `<&file` is just `<file`.
            var copy = redirection
            copy.kind = redirection.kind == .duplicateOutput ? .bothOutput : .input
            try apply(copy, scope: &scope)

        case .heredoc:
            let body = redirection.heredocExpands ? try expandDoubleQuotedText(redirection.heredocBody) : redirection.heredocBody
            let opened = try temporaryFileDescriptor(contents: body)
            scope.opened.append(opened)
            ctx.fdTable[fd] = FDEntry(fd: opened, isTerminal: false)

        case .herestring:
            let text = try expandSingle(redirection.target) + "\n"
            let opened = try temporaryFileDescriptor(contents: text)
            scope.opened.append(opened)
            ctx.fdTable[fd] = FDEntry(fd: opened, isTerminal: false)
        }
    }

    private func defaultEntry(for fd: Int32) -> FDEntry? {
        switch fd {
        case 0: return .lazyTerminalInput
        case 1: return FDEntry(fd: host?.terminalOutput ?? 1, isTerminal: true)
        case 2: return FDEntry(fd: host?.terminalError ?? 2, isTerminal: true)
        default: return nil
        }
    }

    /// `/dev/stdout`, `/dev/stderr`, `/dev/stdin` and `/dev/tty` map onto the current descriptors so
    /// they work inside the sandbox.
    private func specialDevice(_ path: String) -> FDEntry? {
        switch path {
        case "/dev/stdout", "/dev/fd/1": return ctx.fdTable[1] ?? defaultEntry(for: 1)
        case "/dev/stderr", "/dev/fd/2": return ctx.fdTable[2] ?? defaultEntry(for: 2)
        case "/dev/stdin", "/dev/fd/0": return ctx.fdTable[0] ?? defaultEntry(for: 0)
        case "/dev/tty": return FDEntry(fd: host?.terminalOutput ?? 1, isTerminal: true)
        default: return nil
        }
    }

    private func devNullEntry(scope: inout RedirectionScope) throws -> FDEntry {
        let opened = try openFile("/dev/null", flags: O_RDWR)
        scope.opened.append(opened)
        return FDEntry(fd: opened, isTerminal: false)
    }

    private func openFile(_ path: String, flags: Int32) throws -> Int32 {
        let absolute = ctx.absolutePath(path)
        let fd = open(absolute, flags | O_CLOEXEC, 0o644)
        if fd < 0 {
            throw ShellRuntimeError.redirection("\(path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    /// Writes `contents` to an unlinked temporary file and returns a read descriptor positioned at 0.
    func temporaryFileDescriptor(contents: String) throws -> Int32 {
        let directory = NSTemporaryDirectory()
        let path = (directory as NSString).appendingPathComponent("tsh-heredoc-\(UUID().uuidString)")
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw ShellRuntimeError.redirection("cannot create temporary file: \(String(cString: strerror(errno)))")
        }
        unlink(path)
        var bytes = Array(contents.utf8)
        FileDescriptorIO.writeAll(fd, &bytes)
        lseek(fd, 0, SEEK_SET)
        return fd
    }
}
