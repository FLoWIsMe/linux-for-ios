import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Executes parsed programs against a `ShellContext`. One `Interpreter` exists per shell; subshells
/// and pipeline stages get their own instance started from a copy of the context.
final class Interpreter {
    /// The owning shell. The main interpreter holds it weakly because the shell owns the interpreter;
    /// subshells, pipeline stages and background jobs hold it strongly so a job that outlives the UI's
    /// reference still has a shell to report to.
    weak var shellRef: Shell?
    private var strongShellRef: Shell?
    var shell: Shell { strongShellRef ?? shellRef! }
    var ctx: ShellContext
    let jobs: JobTable
    /// The background job this interpreter runs, if any; `kill` cancels it through this reference.
    var job: Job?
    /// Exit status of the most recent command substitution, used as `$?` after `x=$(cmd)`.
    var lastSubstitutionStatus: Int32?

    init(shell: Shell?, context: ShellContext, jobs: JobTable) {
        self.shellRef = shell
        self.ctx = context
        self.jobs = jobs
    }

    /// A new interpreter with a copy of the current state (subshell semantics).
    func subshellCopy() -> Interpreter {
        var copy = ctx
        copy.subshellDepth += 1
        let child = Interpreter(shell: shell, context: copy, jobs: jobs)
        child.strongShellRef = shell
        child.job = job
        return child
    }

    var executor: CommandExecutor { shell.executor }
    var host: ShellHost? { shell.host }

    func checkInterrupt() throws {
        if shell.isInterrupted { throw ControlFlow.interrupted }
        if let job, job.cancelled { throw ControlFlow.interrupted }
    }

    // MARK: Diagnostics

    var errorDescriptor: Int32 {
        if let entry = ctx.fdTable[2], entry.fd >= 0 { return entry.fd }
        return host?.terminalError ?? 2
    }

    var outputDescriptor: Int32 {
        if let entry = ctx.fdTable[1], entry.fd >= 0 { return entry.fd }
        return host?.terminalOutput ?? 1
    }

    /// Writes `scriptName: [line N: ]message` to stderr.
    func reportError(_ message: String, line: Int? = nil) {
        var prefix = ctx.scriptName
        let lineNumber = line ?? ctx.currentLine
        if shell.interactiveScriptName != ctx.scriptName || lineNumber > 1, lineNumber > 0 {
            prefix += ": line \(lineNumber)"
        }
        FileDescriptorIO.writeAll(errorDescriptor, "\(prefix): \(message)\n")
    }

    /// Writes to a descriptor, converting a closed pipe into an exit of the current stage.
    func write(_ text: String, to fd: Int32) throws {
        var bytes = Array(text.utf8)
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
                if errno == EPIPE { throw ControlFlow.exitShell(status: 141) }
                throw ShellRuntimeError.generic("write error: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
        bytes.removeAll()
    }

    // MARK: Lists

    @discardableResult
    func execute(_ list: CommandList) throws -> Int32 {
        var status = ctx.lastStatus
        for item in list.items {
            try checkInterrupt()
            if item.separator == .background {
                status = startBackgroundJob(item.andOr)
                ctx.lastStatus = status
                continue
            }
            status = try execute(item.andOr)
        }
        return status
    }

    func execute(_ andOr: AndOrList) throws -> Int32 {
        if andOr.rest.isEmpty {
            return try executePipeline(andOr.first)
        }
        ctx.errexitSuppression += 1
        var status: Int32
        do {
            status = try executePipeline(andOr.first)
        } catch {
            ctx.errexitSuppression -= 1
            throw error
        }
        for (index, element) in andOr.rest.enumerated() {
            let (op, pipeline) = element
            let isLast = index == andOr.rest.count - 1
            if isLast { ctx.errexitSuppression -= 1 }
            let shouldRun = (op == .and && status == 0) || (op == .or && status != 0)
            if shouldRun {
                do {
                    status = try executePipeline(pipeline)
                } catch {
                    if !isLast { ctx.errexitSuppression -= 1 }
                    throw error
                }
            }
        }
        ctx.lastStatus = status
        return status
    }

    // MARK: Commands

    func execute(_ command: Command) throws -> Int32 {
        switch command {
        case .simple(let simple):
            return try executeSimple(simple)
        case .compound(let compound, let redirections, let line):
            ctx.currentLine = line
            let scope: RedirectionScope
            do {
                scope = try applyRedirections(redirections)
            } catch let error as ShellRuntimeError {
                reportError(error.message, line: line)
                ctx.lastStatus = 1
                return 1
            }
            defer { restoreRedirections(scope) }
            let status = try executeCompound(compound)
            ctx.lastStatus = status
            return status
        case .function(let definition):
            ctx.functions[definition.name] = definition
            ctx.lastStatus = 0
            return 0
        }
    }

    private enum LoopSignal { case next, stop }

    private func runLoopBody(_ body: CommandList) throws -> LoopSignal {
        do {
            try execute(body)
            return .next
        } catch ControlFlow.breakLoop(let levels) {
            if levels > 1 { throw ControlFlow.breakLoop(levels: levels - 1) }
            return .stop
        } catch ControlFlow.continueLoop(let levels) {
            if levels > 1 { throw ControlFlow.continueLoop(levels: levels - 1) }
            return .next
        }
    }

    private func evaluateCondition(_ list: CommandList) throws -> Int32 {
        ctx.errexitSuppression += 1
        defer { ctx.errexitSuppression -= 1 }
        return try execute(list)
    }

    func executeCompound(_ compound: CompoundCommand) throws -> Int32 {
        switch compound {
        case .braceGroup(let list):
            return try execute(list)

        case .subshell(let list):
            let child = subshellCopy()
            return child.runIsolated { try child.execute(list) }

        case .ifClause(let clauses, let elseBody):
            for clause in clauses {
                if try evaluateCondition(clause.condition) == 0 {
                    return try execute(clause.body)
                }
            }
            if let elseBody {
                return try execute(elseBody)
            }
            return 0

        case .forLoop(let variable, let words, let body):
            let values = try words.map { try expandWords($0) } ?? ctx.positional
            var status: Int32 = 0
            ctx.loopDepth += 1
            defer { ctx.loopDepth -= 1 }
            for value in values {
                try checkInterrupt()
                try ctx.setValue(value, for: variable)
                if try runLoopBody(body) == .stop { break }
                status = ctx.lastStatus
            }
            return values.isEmpty ? 0 : status

        case .arithmeticFor(let initializer, let condition, let step, let body):
            var status: Int32 = 0
            ctx.loopDepth += 1
            defer { ctx.loopDepth -= 1 }
            if !initializer.isEmpty { _ = try evaluateArithmetic(initializer) }
            while true {
                try checkInterrupt()
                if !condition.isEmpty, try evaluateArithmetic(condition) == 0 { break }
                if try runLoopBody(body) == .stop { break }
                status = ctx.lastStatus
                if !step.isEmpty { _ = try evaluateArithmetic(step) }
            }
            return status

        case .whileLoop(let condition, let body), .untilLoop(let condition, let body):
            let isUntil: Bool
            if case .untilLoop = compound { isUntil = true } else { isUntil = false }
            var status: Int32 = 0
            ctx.loopDepth += 1
            defer { ctx.loopDepth -= 1 }
            while true {
                try checkInterrupt()
                let conditionStatus = try evaluateCondition(condition)
                let proceed = isUntil ? conditionStatus != 0 : conditionStatus == 0
                if !proceed { break }
                if try runLoopBody(body) == .stop { break }
                status = ctx.lastStatus
            }
            return status

        case .caseClause(let subjectWord, let items):
            let subject = try expandSingle(subjectWord)
            var status: Int32 = 0
            var fallingThrough = false
            for item in items {
                var matched = fallingThrough
                if !matched {
                    for pattern in item.patterns where try expandPattern(pattern).matches(subject) {
                        matched = true
                        break
                    }
                }
                guard matched else { continue }
                status = try execute(item.body)
                switch item.terminator {
                case .stop: return status
                case .fallThrough: fallingThrough = true
                case .continueMatching: fallingThrough = false
                }
            }
            return status

        case .conditional(let expression):
            return try evaluateConditional(expression) ? 0 : 1

        case .arithmetic(let text):
            do {
                return try evaluateArithmetic(text) != 0 ? 0 : 1
            } catch let error as ShellRuntimeError {
                reportError(error.message)
                return 1
            }
        }
    }

    /// Runs `body` with subshell semantics: `exit`, errexit and loop control stay inside.
    func runIsolated(_ body: () throws -> Int32) -> Int32 {
        do {
            return try body()
        } catch ControlFlow.exitShell(let status) {
            return status
        } catch ControlFlow.errexit(let status) {
            return status
        } catch ControlFlow.returnFromFunction(let status) {
            return status
        } catch ControlFlow.breakLoop, ControlFlow.continueLoop {
            return 0
        } catch ControlFlow.interrupted {
            return 130
        } catch let error as ShellRuntimeError {
            reportError(error.message)
            return 1
        } catch {
            reportError("\(error)")
            return 1
        }
    }

    // MARK: [[ ]]

    func evaluateConditional(_ expression: ConditionalExpression) throws -> Bool {
        switch expression {
        case .not(let inner):
            return !(try evaluateConditional(inner))
        case .and(let lhs, let rhs):
            return try evaluateConditional(lhs) && evaluateConditional(rhs)
        case .or(let lhs, let rhs):
            return try evaluateConditional(lhs) || evaluateConditional(rhs)
        case .string(let word):
            return !(try expandSingle(word)).isEmpty
        case .unary(let op, let operand):
            let value = try expandSingle(operand)
            if op == "-v" { return ctx.isSet(value) }
            if op == "-o" { return TestEvaluator.optionIsSet(value, options: ctx.options) }
            return TestEvaluator.unary(op, value, workingDirectory: ctx.workingDirectory)
        case .binary(let op, let lhsWord, let rhsWord):
            let lhs = try expandSingle(lhsWord)
            switch op {
            case "==", "=":
                return try expandPattern(rhsWord).matches(lhs)
            case "!=":
                return !(try expandPattern(rhsWord).matches(lhs))
            case "=~":
                let regex = try expandSingle(rhsWord)
                do {
                    let expression = try NSRegularExpression(pattern: regex)
                    let range = NSRange(lhs.startIndex..<lhs.endIndex, in: lhs)
                    if let match = expression.firstMatch(in: lhs, range: range) {
                        var groups: [String] = []
                        for index in 0..<match.numberOfRanges {
                            let groupRange = match.range(at: index)
                            if groupRange.location == NSNotFound {
                                groups.append("")
                            } else if let swiftRange = Range(groupRange, in: lhs) {
                                groups.append(String(lhs[swiftRange]))
                            }
                        }
                        try ctx.setValue(groups.first ?? "", for: "BASH_REMATCH")
                        for (index, group) in groups.enumerated() where index > 0 {
                            try ctx.setValue(group, for: "BASH_REMATCH_\(index)")
                        }
                        return true
                    }
                    return false
                } catch let error as ShellRuntimeError {
                    throw error
                } catch {
                    throw ShellRuntimeError.syntax("invalid regular expression: \(regex)")
                }
            case "<":
                return lhs < (try expandSingle(rhsWord))
            case ">":
                return lhs > (try expandSingle(rhsWord))
            default:
                let rhs = try expandSingle(rhsWord)
                return try TestEvaluator.binary(op, lhs, rhs, workingDirectory: ctx.workingDirectory)
            }
        }
    }

    // MARK: Simple commands

    func executeSimple(_ command: SimpleCommand) throws -> Int32 {
        ctx.currentLine = command.line
        try checkInterrupt()

        // Expand assignments and words. Expansion errors abort just this command.
        var assignments: [(name: String, value: String, append: Bool)] = []
        let argv: [String]
        lastSubstitutionStatus = nil
        do {
            for assignment in command.assignments {
                let value = try expandAssignmentValue(assignment.value)
                assignments.append((assignment.name, value, assignment.append))
            }
            if let first = command.words.first, Interpreter.declarationBuiltins.contains(first.raw) {
                // `local x=$value` must not split the value, like bash's declaration builtins.
                var result = try expandWord(first)
                for word in command.words.dropFirst() {
                    if let split = Parser.splitAssignment(word.raw) {
                        let value = try expandAssignmentValue(Word(split.value, line: word.line))
                        result.append(split.name + (split.append ? "+=" : "=") + value)
                    } else {
                        result.append(contentsOf: try expandWord(word))
                    }
                }
                argv = result
            } else {
                argv = try expandWords(command.words)
            }
        } catch let error as ShellRuntimeError {
            reportError(error.message, line: command.line)
            ctx.lastStatus = 1
            if case .unboundVariable = error, !shell.isInteractiveSession {
                throw ControlFlow.exitShell(status: 1)
            }
            return 1
        }

        if ctx.options.xtrace {
            var trace = "+ "
            if !assignments.isEmpty {
                trace += assignments.map { "\($0.name)=\($0.value)" }.joined(separator: " ") + (argv.isEmpty ? "" : " ")
            }
            trace += argv.map(Interpreter.quoteForTrace).joined(separator: " ")
            FileDescriptorIO.writeAll(errorDescriptor, trace + "\n")
        }

        if argv.isEmpty {
            // Pure assignment (and possibly redirections for their side effects).
            let scope: RedirectionScope
            do {
                scope = try applyRedirections(command.redirections)
            } catch let error as ShellRuntimeError {
                reportError(error.message, line: command.line)
                ctx.lastStatus = 1
                return 1
            }
            restoreRedirections(scope)
            do {
                for assignment in assignments {
                    try assign(assignment)
                }
            } catch let error as ShellRuntimeError {
                reportError(error.message, line: command.line)
                ctx.lastStatus = 1
                return 1
            }
            let status = lastSubstitutionStatus ?? 0
            ctx.lastStatus = status
            return status
        }

        ctx.lastArgument = argv.last ?? ""
        return try executeResolved(argv: argv, assignments: assignments, redirections: command.redirections, line: command.line)
    }

    private func assign(_ assignment: (name: String, value: String, append: Bool)) throws {
        if Interpreter.specialNamesForAssignment.contains(assignment.name) || assignment.name.first!.isNumber {
            throw ShellRuntimeError.generic("\(assignment.name): cannot assign in this way")
        }
        if assignment.append {
            let existing = ctx.value(assignment.name) ?? ""
            try ctx.setValue(existing + assignment.value, for: assignment.name)
        } else {
            try ctx.setValue(assignment.value, for: assignment.name)
        }
    }

    private static let specialNamesForAssignment: Set<String> = ["@", "*", "#", "?", "-", "$", "!"]

    static func quoteForTrace(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@+%,".contains($0) }
        if safe { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `argv` after resolution: functions, builtins, host commands, then external commands.
    /// `skipFunctions` implements `command`; `builtinsOnly` implements `builtin`.
    func executeResolved(
        argv: [String],
        assignments: [(name: String, value: String, append: Bool)],
        redirections: [Redirection],
        line: Int,
        skipFunctions: Bool = false,
        builtinsOnly: Bool = false
    ) throws -> Int32 {
        let name = argv[0]

        let scope: RedirectionScope
        do {
            scope = try applyRedirections(redirections)
        } catch let error as ShellRuntimeError {
            reportError(error.message, line: line)
            ctx.lastStatus = 1
            return 1
        }
        defer { restoreRedirections(scope) }

        // Temporary assignments: visible to the command, restored afterwards.
        var saved: [(String, ShellVariable?)] = []
        for assignment in assignments {
            saved.append((assignment.name, ctx.variable(assignment.name)))
            do {
                try ctx.setValue(assignment.append ? (ctx.value(assignment.name) ?? "") + assignment.value : assignment.value, for: assignment.name, exported: true)
            } catch let error as ShellRuntimeError {
                reportError(error.message, line: line)
                ctx.lastStatus = 1
                return 1
            }
        }
        defer {
            for (variableName, variable) in saved.reversed() {
                if let variable {
                    ctx.globals[variableName] = variable
                    for index in ctx.scopes.indices.reversed() where ctx.scopes[index][variableName] != nil {
                        ctx.scopes[index][variableName] = variable
                    }
                } else {
                    ctx.globals.removeValue(forKey: variableName)
                }
            }
        }

        var status: Int32
        if !skipFunctions, !builtinsOnly, let function = ctx.functions[name] {
            status = try callFunction(function, arguments: Array(argv.dropFirst()))
        } else if let builtinStatus = try runBuiltin(argv: argv, io: currentIO(), builtinsOnly: builtinsOnly) {
            status = builtinStatus
        } else if builtinsOnly {
            reportError("\(name): not a shell builtin", line: line)
            status = 1
        } else if let hostStatus = try runHostCommand(argv: argv) {
            status = hostStatus
        } else {
            status = try runExternal(argv: argv, line: line)
        }
        ctx.lastStatus = status
        return status
    }

    /// Descriptors for builtins. stdin is -1 when it is the terminal (see `read`).
    func currentIO() -> ShellIO {
        let stdin = ctx.fdTable[0] ?? .lazyTerminalInput
        let stdout = ctx.fdTable[1]?.fd ?? host?.terminalOutput ?? 1
        let stderr = ctx.fdTable[2]?.fd ?? host?.terminalError ?? 2
        return ShellIO(stdin: stdin.fd, stdout: stdout, stderr: stderr)
    }

    var stdinIsTerminal: Bool {
        (ctx.fdTable[0] ?? .lazyTerminalInput).isTerminal
    }

    // MARK: Functions

    func callFunction(_ function: FunctionDefinition, arguments: [String]) throws -> Int32 {
        guard ctx.functionDepth < 256 else {
            reportError("\(function.name): maximum function nesting level exceeded (256)")
            return 1
        }
        let savedPositional = ctx.positional
        ctx.positional = arguments
        ctx.scopes.append([:])
        ctx.functionDepth += 1
        ctx.functionStack.append(function.name)
        defer {
            ctx.functionStack.removeLast()
            ctx.functionDepth -= 1
            ctx.scopes.removeLast()
            ctx.positional = savedPositional
        }
        do {
            return try execute(function.body)
        } catch ControlFlow.returnFromFunction(let status) {
            ctx.lastStatus = status
            return status
        }
    }

    // MARK: Host and external commands

    private func runHostCommand(argv: [String]) throws -> Int32? {
        guard let host else { return nil }
        let names = host.hostCommandNames()
        guard names.contains(argv[0]) else { return nil }
        var io = currentIO()
        var openedTerminal: Int32?
        var devNull: Int32?
        if io.stdin < 0 {
            if let fd = host.openTerminalInput() {
                openedTerminal = fd
                io.stdin = fd
            } else {
                devNull = open("/dev/null", O_RDONLY)
                io.stdin = devNull ?? -1
            }
        }
        defer {
            if let openedTerminal { host.closeTerminalInput(openedTerminal) }
            if let devNull { FileDescriptorIO.closeQuietly(devNull) }
        }
        return host.runHostCommand(argv, io: io)
    }

    private static let shellNames: Set<String> = ["sh", "bash", "dash", "zsh", "tsh", "ksh"]

    func runExternal(argv: [String], line: Int) throws -> Int32 {
        let name = argv[0]
        if !executor.commandExists(name) {
            if Interpreter.shellNames.contains(name) || Interpreter.shellNames.contains(URL(fileURLWithPath: name).lastPathComponent) {
                return try runShellEmulation(argv: argv)
            }
            if name.contains("/") {
                let path = ctx.absolutePath(name)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        reportError("\(name): is a directory", line: line)
                        return ExitStatus.cannotExecute
                    }
                    return try runScriptFile(path: path, arguments: Array(argv.dropFirst()), displayName: name)
                }
                reportError("\(name): No such file or directory", line: line)
                hintMountPath(in: [name], line: line)
                return ExitStatus.notFound
            }
            reportError("\(name): command not found", line: line)
            if let suggestion = suggestCommand(for: name) {
                FileDescriptorIO.writeAll(errorDescriptor, "Did you mean: \(suggestion)?\n")
            }
            return ExitStatus.notFound
        }

        let stdinEntry = ctx.fdTable[0] ?? .lazyTerminalInput
        let stdoutEntry = ctx.fdTable[1] ?? FDEntry(fd: host?.terminalOutput ?? 1, isTerminal: true)
        let stderrEntry = ctx.fdTable[2] ?? FDEntry(fd: host?.terminalError ?? 2, isTerminal: true)
        var stdinFD = stdinEntry.fd
        var openedTerminal: Int32?
        var devNull: Int32?
        if stdinFD < 0 {
            if let host, let fd = host.openTerminalInput() {
                openedTerminal = fd
                stdinFD = fd
            } else {
                devNull = open("/dev/null", O_RDONLY)
                stdinFD = devNull ?? 0
            }
        }
        defer {
            if let openedTerminal { host?.closeTerminalInput(openedTerminal) }
            if let devNull { FileDescriptorIO.closeQuietly(devNull) }
        }

        let command = ExternalCommand(
            argv: argv,
            environment: ctx.exportedEnvironment(),
            workingDirectory: ctx.workingDirectory,
            stdin: stdinFD,
            stdout: stdoutEntry.fd,
            stderr: stderrEntry.fd,
            stdinIsTerminal: stdinEntry.isTerminal,
            stdoutIsTerminal: stdoutEntry.isTerminal
        )
        host?.shellWillRun(externalCommand: argv)
        let status = executor.run(command)
        host?.shellDidFinish(externalCommand: argv, status: status)
        try checkInterrupt()
        if status != 0 { hintMountPath(in: argv, line: line) }
        return status
    }

    /// Linux keeps mounted volumes under /mnt; Tern keeps them under ~/mnt, because iOS does not let
    /// an app create directories at the root. People type the Linux path from habit, and the failure
    /// they get is the program's own message ("dash: 0: Can't open /mnt/Downloads/setup.sh"), which
    /// explains nothing. When a command fails and one of its words is a /mnt path that does exist
    /// under ~/mnt, say where the folder really is. Nothing is printed when the path would not have
    /// worked under ~/mnt either.
    func hintMountPath(in words: [String], line: Int? = nil) {
        let home = ctx.value("HOME") ?? shell.homeDirectory
        for word in words where word == "/mnt" || word.hasPrefix("/mnt/") {
            if FileManager.default.fileExists(atPath: home + word) {
                reportError("mounted folders live under ~/mnt, not /mnt. Did you mean: ~\(word)?", line: line)
                return
            }
        }
    }

    /// Picks the closest known command name (edit distance 1 or 2) for "command not found" hints.
    func suggestCommand(for name: String) -> String? {
        guard name.count >= 2 else { return nil }
        var candidates = Set(Shell.builtinNames)
        candidates.formUnion(ctx.functions.keys)
        candidates.formUnion(ctx.aliases.keys)
        candidates.formUnion(host?.hostCommandNames() ?? [])
        candidates.formUnion(executor.availableCommands())
        var best: (String, Int)?
        for candidate in candidates where abs(candidate.count - name.count) <= 2 {
            let distance = Interpreter.editDistance(name, candidate)
            if distance <= 2, best == nil || distance < best!.1 || (distance == best!.1 && candidate < best!.0) {
                best = (candidate, distance)
            }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: Scripts

    /// Runs a script file in a fresh child shell that only inherits exported variables and the
    /// working directory, like a separate `sh` process would.
    func runScriptFile(path: String, arguments: [String], displayName: String) throws -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            reportError("\(displayName): Permission denied")
            return ExitStatus.cannotExecute
        }
        if looksBinary(data) {
            reportError("\(displayName): cannot execute binary file")
            return ExitStatus.cannotExecute
        }
        let source = String(decoding: data, as: UTF8.self)
        return try runChildScript(source: source, scriptName: displayName, arguments: arguments)
    }

    private func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(512)
        if sample.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || sample.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return true }
        return sample.contains(0)
    }

    func runChildScript(source: String, scriptName: String, arguments: [String]) throws -> Int32 {
        try runChildScript(source: source, scriptName: scriptName, arguments: arguments, options: ShellOptions())
    }

    /// `sh -c "..."`, `bash script.sh`: emulated with the built in interpreter when no real shell exists.
    private func runShellEmulation(argv: [String]) throws -> Int32 {
        var index = 1
        var inlineCommand: String?
        var options = ShellOptions()
        while index < argv.count, argv[index].hasPrefix("-"), argv[index] != "-" {
            let flag = argv[index]
            if flag == "--" { index += 1; break }
            if flag == "-c" {
                index += 1
                guard index < argv.count else {
                    reportError("\(argv[0]): -c: option requires an argument")
                    return 2
                }
                inlineCommand = argv[index]
                index += 1
                continue
            }
            for c in flag.dropFirst() {
                switch c {
                case "e": options.errexit = true
                case "x": options.xtrace = true
                case "u": options.nounset = true
                case "f": options.noglob = true
                case "c": break
                default: break // -l, -i, -s and friends are ignored
                }
            }
            index += 1
        }
        if let inlineCommand {
            let name = index < argv.count ? argv[index] : argv[0]
            let arguments = index < argv.count ? Array(argv[(index + 1)...]) : []
            return try runChildScript(source: inlineCommand, scriptName: name, arguments: arguments, options: options)
        }
        guard index < argv.count else {
            reportError("\(argv[0]): interactive mode is not available here; pass a script or -c")
            return 2
        }
        let path = ctx.absolutePath(argv[index])
        guard let data = FileManager.default.contents(atPath: path) else {
            reportError("\(argv[0]): \(argv[index]): No such file or directory")
            hintMountPath(in: [argv[index]])
            return ExitStatus.notFound
        }
        return try runChildScript(source: String(decoding: data, as: UTF8.self), scriptName: argv[index], arguments: Array(argv[(index + 1)...]), options: options)
    }

    private func runChildScript(source: String, scriptName: String, arguments: [String], options: ShellOptions) throws -> Int32 {
        var context = ShellContext(scriptName: scriptName, workingDirectory: ctx.workingDirectory, fdTable: ctx.fdTable)
        for (name, value) in ctx.exportedEnvironment() {
            context.globals[name] = ShellVariable(value: value, exported: true)
        }
        context.positional = arguments
        context.options = options
        let child = Interpreter(shell: shell, context: context, jobs: jobs)
        child.strongShellRef = shell
        return child.runIsolated {
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
            try child.runExitTrap()
            return status
        }
    }

    func describe(_ error: ParseError) -> String {
        switch error {
        case .incomplete(let hint, _):
            switch hint {
            case "quote": return "unexpected EOF while looking for matching `''"
            case "dquote": return "unexpected EOF while looking for matching `\"'"
            case "backtick": return "unexpected EOF while looking for matching ``'"
            case "heredoc": return "here-document delimited by end-of-file"
            default: return "syntax error: unexpected end of file (missing `\(Interpreter.closingToken(for: hint))')"
            }
        case .syntax(let message, _):
            return message
        }
    }

    static func closingToken(for hint: String) -> String {
        switch hint {
        case "if": return "fi"
        case "for", "while", "until": return "done"
        case "case": return "esac"
        case "{": return "}"
        case "(": return ")"
        case "[[": return "]]"
        case "$(": return ")"
        case "${": return "}"
        case "((", "$((": return "))"
        default: return hint
        }
    }

    /// Runs the EXIT trap once, if one is set.
    func runExitTrap() throws {
        guard let handler = ctx.traps["EXIT"], !handler.isEmpty else { return }
        ctx.traps["EXIT"] = nil
        let savedStatus = ctx.lastStatus
        let parser = Parser(source: handler, aliasLookup: { [weak self] in self?.ctx.aliases[$0] })
        do {
            while let list = try parser.parseCompleteCommand() {
                try execute(list)
            }
        } catch let error as ParseError {
            reportError(describe(error))
        } catch ControlFlow.exitShell {
            // exit inside the trap simply ends it
        }
        ctx.lastStatus = savedStatus
    }
}
