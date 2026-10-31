import Foundation

/// Thread safe collector for pipeline stage results.
private final class StageResults {
    private let lock = NSLock()
    private var statuses: [Int32]

    init(count: Int) {
        statuses = [Int32](repeating: 0, count: count)
    }

    func set(_ status: Int32, at index: Int) {
        lock.lock(); statuses[index] = status; lock.unlock()
    }

    var all: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return statuses
    }
}

extension Interpreter {
    static let workerStackSize = 16 * 1024 * 1024

    /// Runs `body` on a dedicated thread with a large stack and returns the thread.
    static func spawnWorker(_ body: @escaping () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.stackSize = workerStackSize
        thread.start()
        return thread
    }

    func executePipeline(_ pipeline: Pipeline) throws -> Int32 {
        try checkInterrupt()
        ctx.currentLine = pipeline.line
        let start = Date()
        var status: Int32
        if pipeline.stages.count == 1 {
            if pipeline.negated {
                ctx.errexitSuppression += 1
                defer { ctx.errexitSuppression -= 1 }
                status = try execute(pipeline.stages[0].command)
            } else {
                status = try execute(pipeline.stages[0].command)
            }
        } else {
            status = try executeMultiStage(pipeline)
        }
        if pipeline.negated {
            status = status == 0 ? 1 : 0
        }
        ctx.lastStatus = status
        if pipeline.timed {
            let elapsed = Date().timeIntervalSince(start)
            let minutes = Int(elapsed) / 60
            let seconds = elapsed - Double(minutes * 60)
            let report = String(format: "\nreal\t%dm%.3fs\nuser\t0m0.000s\nsys\t0m0.000s\n", minutes, seconds)
            FileDescriptorIO.writeAll(errorDescriptor, report)
        }
        if status != 0, ctx.options.errexit, ctx.errexitSuppression == 0, !pipeline.negated {
            throw ControlFlow.errexit(status: status)
        }
        return status
    }

    /// Runs a command with subshell semantics and returns its status, never throwing control flow.
    private func runStage(_ command: Command) -> Int32 {
        runIsolated { try execute(command) }
    }

    private func executeMultiStage(_ pipeline: Pipeline) throws -> Int32 {
        let count = pipeline.stages.count
        var pipes: [(read: Int32, write: Int32)] = []
        for _ in 0..<(count - 1) {
            guard let pipe = FileDescriptorIO.makePipe() else {
                for pipe in pipes {
                    FileDescriptorIO.closeQuietly(pipe.read)
                    FileDescriptorIO.closeQuietly(pipe.write)
                }
                throw ShellRuntimeError.generic("cannot create pipe: \(String(cString: strerror(errno)))")
            }
            pipes.append(pipe)
        }

        var children: [Interpreter] = []
        for index in 0..<count {
            let child = subshellCopy()
            if index > 0 {
                child.ctx.fdTable[0] = FDEntry(fd: pipes[index - 1].read, isTerminal: false)
            }
            if index < count - 1 {
                let entry = FDEntry(fd: pipes[index].write, isTerminal: false)
                child.ctx.fdTable[1] = entry
                if pipeline.stages[index].pipesStderr {
                    child.ctx.fdTable[2] = entry
                }
            }
            children.append(child)
        }

        let results = StageResults(count: count)
        let group = DispatchGroup()
        for index in 0..<(count - 1) {
            group.enter()
            let child = children[index]
            let command = pipeline.stages[index].command
            let writeEnd = pipes[index].write
            let readEnd: Int32? = index > 0 ? pipes[index - 1].read : nil
            _ = Interpreter.spawnWorker {
                let status = child.runStage(command)
                results.set(status, at: index)
                FileDescriptorIO.closeQuietly(writeEnd)
                if let readEnd { FileDescriptorIO.closeQuietly(readEnd) }
                group.leave()
            }
        }

        let last = children[count - 1]
        let lastStatus = last.runStage(pipeline.stages[count - 1].command)
        results.set(lastStatus, at: count - 1)
        FileDescriptorIO.closeQuietly(pipes[count - 2].read)
        group.wait()

        try checkInterrupt()
        let statuses = results.all
        if ctx.options.pipefail, let failing = statuses.last(where: { $0 != 0 }) {
            return failing
        }
        return statuses[count - 1]
    }

    // MARK: Background jobs

    /// Starts `andOr` on a background thread and returns immediately with status 0.
    func startBackgroundJob(_ andOr: AndOrList) -> Int32 {
        let child = subshellCopy()
        // A background job never reads the keyboard.
        if let entry = child.ctx.fdTable[0], entry.isTerminal, entry.fd < 0 {
            if let devNull = try? openDevNull() {
                child.ctx.fdTable[0] = FDEntry(fd: devNull, isTerminal: false)
            }
        }
        let job = jobs.add(command: "background job")
        ctx.lastBackgroundJob = job.id
        _ = Interpreter.spawnWorker {
            let status = child.runIsolated { try child.execute(andOr) }
            job.finish(status: status)
        }
        if shell.isInteractiveSession, ctx.subshellDepth == 0 {
            FileDescriptorIO.writeAll(errorDescriptor, "[\(job.id)] \(job.id)\n")
        }
        return 0
    }

    private func openDevNull() throws -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        if fd < 0 { throw ShellRuntimeError.generic("cannot open /dev/null") }
        return fd
    }

    // MARK: Command substitution

    /// Runs `source` in a subshell with stdout captured. Trailing newlines are removed.
    func captureOutput(of source: String) throws -> String {
        guard let pipe = FileDescriptorIO.makePipe() else {
            throw ShellRuntimeError.generic("cannot create pipe for command substitution")
        }
        let child = subshellCopy()
        child.ctx.fdTable[1] = FDEntry(fd: pipe.write, isTerminal: false)

        let collector = OutputCollector(fd: pipe.read)
        let status = child.runIsolated {
            let parser = Parser(source: source, aliasLookup: { child.ctx.aliases[$0] })
            var status: Int32 = 0
            do {
                while let list = try parser.parseCompleteCommand() {
                    status = try child.execute(list)
                }
            } catch let error as ParseError {
                child.reportError(child.describe(error), line: error.line)
                return 2
            }
            return status
        }
        FileDescriptorIO.closeQuietly(pipe.write)
        var output = collector.finish()
        while output.last == UInt8(ascii: "\n") { output.removeLast() }
        output.removeAll { $0 == 0 }
        lastSubstitutionStatus = status
        ctx.lastStatus = status
        try checkInterrupt()
        return String(decoding: output, as: UTF8.self)
    }
}

/// Reads a descriptor to EOF on a background thread.
final class OutputCollector {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32) {
        let thread = Thread { [self] in
            let bytes = FileDescriptorIO.readAll(fd)
            FileDescriptorIO.closeQuietly(fd)
            self.lock.lock()
            self.buffer = bytes
            self.lock.unlock()
            self.done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Waits for EOF and returns everything read.
    func finish() -> [UInt8] {
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
