import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension Interpreter {
    static let declarationBuiltins: Set<String> = ["local", "export", "readonly", "declare", "typeset"]

    /// Runs a builtin. Returns nil when `argv[0]` is not a builtin.
    func runBuiltin(argv: [String], io: ShellIO, builtinsOnly: Bool) throws -> Int32? {
        let name = argv[0]
        let args = Array(argv.dropFirst())
        guard Shell.builtinNames.contains(name) else { return nil }

        func out(_ text: String) throws { try write(text, to: io.stdout) }
        func err(_ text: String) { FileDescriptorIO.writeAll(io.stderr, text) }
        func usage(_ message: String) -> Int32 {
            reportError("\(name): \(message)")
            return 2
        }

        switch name {
        case ":", "true":
            return 0
        case "false":
            return 1

        case "echo":
            return try builtinEcho(args, out: out)

        case "printf":
            return try builtinPrintf(args, io: io)

        case "test", "[":
            var operands = args
            if name == "[" {
                guard operands.last == "]" else {
                    reportError("[: missing `]'")
                    return 2
                }
                operands.removeLast()
            }
            do {
                return try TestEvaluator.evaluate(operands, workingDirectory: ctx.workingDirectory, options: ctx.options) ? 0 : 1
            } catch let error as ShellRuntimeError {
                reportError("\(name): \(error.message)")
                return 2
            }

        case "cd":
            return try builtinCD(args)

        case "pwd":
            var path = ctx.workingDirectory
            if args.contains("-P") {
                path = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { PathNormalizer.normalize($0.hasPrefix("/") ? $0 : ctx.workingDirectory + "/" + $0) } ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
            try out(path + "\n")
            return 0

        case "pushd":
            let target = args.first ?? ctx.directoryStack.first
            guard let target else {
                reportError("pushd: no other directory")
                return 1
            }
            let previous = ctx.workingDirectory
            let status = try builtinCD([target])
            if status == 0 {
                if args.isEmpty, !ctx.directoryStack.isEmpty { ctx.directoryStack.removeFirst() }
                ctx.directoryStack.insert(previous, at: 0)
                try out(([ctx.workingDirectory] + ctx.directoryStack).map(prettyDirectory).joined(separator: " ") + "\n")
            }
            return status

        case "popd":
            guard !ctx.directoryStack.isEmpty else {
                reportError("popd: directory stack empty")
                return 1
            }
            let target = ctx.directoryStack.removeFirst()
            let status = try builtinCD([target])
            if status == 0 {
                try out(([ctx.workingDirectory] + ctx.directoryStack).map(prettyDirectory).joined(separator: " ") + "\n")
            }
            return status

        case "dirs":
            if args.contains("-c") {
                ctx.directoryStack.removeAll()
                return 0
            }
            let entries = [ctx.workingDirectory] + ctx.directoryStack
            if args.contains("-v") {
                for (index, entry) in entries.enumerated() { try out(" \(index)  \(prettyDirectory(entry))\n") }
            } else {
                try out(entries.map(prettyDirectory).joined(separator: " ") + "\n")
            }
            return 0

        case "exit":
            if let first = args.first {
                guard let code = Int32(first) else {
                    reportError("exit: \(first): numeric argument required")
                    throw ControlFlow.exitShell(status: 2)
                }
                throw ControlFlow.exitShell(status: code & 0xFF)
            }
            throw ControlFlow.exitShell(status: ctx.lastStatus)

        case "return":
            guard ctx.functionDepth > 0 || ctx.sourceDepth > 0 else {
                reportError("return: can only `return' from a function or sourced script")
                return 1
            }
            if let first = args.first {
                guard let code = Int32(first) else {
                    reportError("return: \(first): numeric argument required")
                    throw ControlFlow.returnFromFunction(status: 2)
                }
                throw ControlFlow.returnFromFunction(status: code & 0xFF)
            }
            throw ControlFlow.returnFromFunction(status: ctx.lastStatus)

        case "break", "continue":
            guard ctx.loopDepth > 0 else {
                reportError("\(name): only meaningful in a `for', `while', or `until' loop")
                return 0
            }
            var levels = 1
            if let first = args.first {
                guard let value = Int(first), value >= 1 else {
                    reportError("\(name): \(first): loop count out of range")
                    return 1
                }
                levels = min(value, ctx.loopDepth)
            }
            if name == "break" { throw ControlFlow.breakLoop(levels: levels) }
            throw ControlFlow.continueLoop(levels: levels)

        case "shift":
            var count = 1
            if let first = args.first {
                guard let value = Int(first), value >= 0 else {
                    reportError("shift: \(first): numeric argument required")
                    return 1
                }
                count = value
            }
            guard count <= ctx.positional.count else {
                reportError("shift: shift count out of range")
                return 1
            }
            ctx.positional.removeFirst(count)
            return 0

        case "set":
            return try builtinSet(args, out: out)

        case "export", "readonly", "declare", "typeset", "local":
            return try builtinDeclare(name, args, out: out)

        case "unset":
            var unsetFunctions = false
            var names = args
            if let first = args.first, first == "-f" { unsetFunctions = true; names.removeFirst() }
            if let first = args.first, first == "-v" { names.removeFirst() }
            for variable in names {
                if unsetFunctions {
                    ctx.functions.removeValue(forKey: variable)
                } else {
                    do { try ctx.unset(variable) } catch let error as ShellRuntimeError {
                        reportError("unset: \(error.message)")
                        return 1
                    }
                }
            }
            return 0

        case "alias":
            if args.isEmpty {
                for (key, value) in ctx.aliases.sorted(by: { $0.key < $1.key }) {
                    try out("alias \(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'\n")
                }
                return 0
            }
            var status: Int32 = 0
            for argument in args where argument != "-p" {
                if let equals = argument.firstIndex(of: "=") {
                    let key = String(argument[..<equals])
                    ctx.aliases[key] = String(argument[argument.index(after: equals)...])
                } else if let value = ctx.aliases[argument] {
                    try out("alias \(argument)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'\n")
                } else {
                    reportError("alias: \(argument): not found")
                    status = 1
                }
            }
            return status

        case "unalias":
            if args.contains("-a") {
                ctx.aliases.removeAll()
                return 0
            }
            var status: Int32 = 0
            for argument in args {
                if ctx.aliases.removeValue(forKey: argument) == nil {
                    reportError("unalias: \(argument): not found")
                    status = 1
                }
            }
            return status

        case "source", ".":
            return try builtinSource(args)

        case "eval":
            let source = args.joined(separator: " ")
            guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
            return try evaluateSource(source)

        case "exec":
            if args.isEmpty {
                ctx.keepRedirections = true
                return 0
            }
            let status = try executeResolved(argv: args, assignments: [], redirections: [], line: ctx.currentLine, skipFunctions: true)
            throw ControlFlow.exitShell(status: status)

        case "command":
            var remaining = args
            var describe = false
            var verbose = false
            while let first = remaining.first, first.hasPrefix("-"), first != "--" {
                if first.contains("v") { describe = true }
                if first.contains("V") { verbose = true; describe = true }
                remaining.removeFirst()
            }
            if remaining.first == "--" { remaining.removeFirst() }
            guard !remaining.isEmpty else { return describe ? 1 : 0 }
            if describe {
                var status: Int32 = 0
                for candidate in remaining {
                    if let description = describeCommand(candidate, verbose: verbose, forType: false) {
                        try out(description + "\n")
                    } else {
                        status = 1
                    }
                }
                return status
            }
            return try executeResolved(argv: remaining, assignments: [], redirections: [], line: ctx.currentLine, skipFunctions: true)

        case "builtin":
            guard let target = args.first else { return 0 }
            guard let status = try runBuiltin(argv: args, io: io, builtinsOnly: true) else {
                reportError("builtin: \(target): not a shell builtin")
                return 1
            }
            return status

        case "type":
            var remaining = args
            var typeOnly = false
            var all = false
            var pathOnly = false
            while let first = remaining.first, first.hasPrefix("-"), first.count > 1 {
                for flag in first.dropFirst() {
                    switch flag {
                    case "t": typeOnly = true
                    case "a": all = true
                    case "p", "P": pathOnly = true
                    default: break
                    }
                }
                remaining.removeFirst()
            }
            var status: Int32 = 0
            for candidate in remaining {
                if typeOnly {
                    if let kind = commandKind(candidate) {
                        try out(kind + "\n")
                    } else {
                        status = 1
                    }
                } else if pathOnly {
                    if let path = externalPath(for: candidate) { try out(path + "\n") } else { status = 1 }
                } else if let description = describeCommand(candidate, verbose: true, forType: true, all: all) {
                    try out(description + "\n")
                } else {
                    reportError("type: \(candidate): not found")
                    status = 1
                }
            }
            return status

        case "which":
            var status: Int32 = 0
            var remaining = args
            remaining.removeAll { $0.hasPrefix("-") }
            for candidate in remaining {
                if ctx.functions[candidate] != nil || Shell.builtinNames.contains(candidate) || ctx.aliases[candidate] != nil {
                    try out("\(candidate): shell built-in command\n")
                } else if let path = externalPath(for: candidate) {
                    try out(path + "\n")
                } else if executor.commandExists(candidate) || (host?.hostCommandNames().contains(candidate) ?? false) {
                    try out(candidate + "\n")
                } else {
                    status = 1
                }
            }
            return status

        case "hash":
            return 0

        case "help", "history":
            if let status = host?.runHostCommand(argv, io: io) { return status }
            reportError("\(name): not available")
            return 1

        case "clear":
            if let status = host?.runHostCommand(argv, io: io) { return status }
            try out("\u{1B}[H\u{1B}[2J\u{1B}[3J")
            return 0

        case "read":
            return try builtinRead(args, io: io)

        case "getopts":
            return try builtinGetopts(args)

        case "let":
            guard !args.isEmpty else { return usage("expression expected") }
            var result = 0
            for expression in args {
                do {
                    result = try evaluateArithmetic(expression)
                } catch let error as ShellRuntimeError {
                    reportError("let: \(error.message)")
                    return 1
                }
            }
            return result != 0 ? 0 : 1

        case "trap":
            return try builtinTrap(args, out: out)

        case "jobs":
            for job in jobs.all {
                let state = job.isFinished ? (job.status == 0 ? "Done" : "Exit \(job.status)") : "Running"
                try out("[\(job.id)]  \(state.padding(toLength: 24, withPad: " ", startingAt: 0))\(job.command)\n")
            }
            jobs.reap()
            return 0

        case "wait":
            if args.isEmpty {
                var status: Int32 = 0
                for job in jobs.all {
                    while !job.wait(until: Date().addingTimeInterval(0.05)) {
                        try checkInterrupt()
                    }
                    status = job.status
                }
                jobs.reap()
                return status
            }
            var status: Int32 = 0
            for argument in args {
                guard let job = jobFromSpecifier(argument) else {
                    reportError("wait: \(argument): no such job")
                    status = 127
                    continue
                }
                while !job.wait(until: Date().addingTimeInterval(0.05)) {
                    try checkInterrupt()
                }
                status = job.status
            }
            jobs.reap()
            return status

        case "kill":
            return builtinKill(args, out: out)

        case "bg", "fg":
            reportError("\(name): job control is not supported on iOS")
            return 1

        case "umask":
            if args.isEmpty || args == ["-S"] || args == ["-p"] {
                try out(args == ["-S"] ? "u=rwx,g=rx,o=rx\n" : "0022\n")
            }
            return 0

        case "ulimit":
            if args.contains("-a") {
                try out("open files                      (-n) 256\nstack size              (kbytes, -s) 16384\n")
            } else if args.contains("-n") {
                try out("256\n")
            } else if args.contains("-s") {
                try out("16384\n")
            } else if args.allSatisfy({ $0.hasPrefix("-") || Int($0) != nil }) {
                try out("unlimited\n")
            }
            return 0

        case "times":
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func format(_ time: timeval) -> String {
                let total = Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
                return String(format: "%dm%.3fs", Int(total) / 60, total - Double(Int(total) / 60 * 60))
            }
            try out("\(format(usage.ru_utime)) \(format(usage.ru_stime))\n0m0.000s 0m0.000s\n")
            return 0

        default:
            return nil
        }
    }

    // MARK: Helpers

    func prettyDirectory(_ path: String) -> String {
        let home = ctx.value("HOME") ?? shell.homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Where `type`/`which` say an external command lives. Scans PATH for a matching file; otherwise
    /// reports the bundled toolchain.
    func externalPath(for name: String) -> String? {
        if name.contains("/") {
            let path = ctx.absolutePath(name)
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in (ctx.value("PATH") ?? "").split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func commandKind(_ name: String) -> String? {
        if ctx.aliases[name] != nil { return "alias" }
        if Parser.reservedWords.contains(name) { return "keyword" }
        if ctx.functions[name] != nil { return "function" }
        if Shell.builtinNames.contains(name) { return "builtin" }
        if host?.hostCommandNames().contains(name) ?? false { return "builtin" }
        if executor.commandExists(name) || externalPath(for: name) != nil { return "file" }
        return nil
    }

    private func describeCommand(_ name: String, verbose: Bool, forType: Bool, all: Bool = false) -> String? {
        var lines: [String] = []
        if let alias = ctx.aliases[name] {
            lines.append(verbose ? "\(name) is an alias for `\(alias)'" : "alias \(name)='\(alias)'")
            if !all { return lines.joined(separator: "\n") }
        }
        if Parser.reservedWords.contains(name) {
            lines.append(verbose ? "\(name) is a shell keyword" : name)
            if !all { return lines.joined(separator: "\n") }
        }
        if let function = ctx.functions[name] {
            lines.append(verbose ? "\(name) is a function\n\(name) () \(describeBody(function.body))" : name)
            if !all { return lines.joined(separator: "\n") }
        }
        if Shell.builtinNames.contains(name) || (host?.hostCommandNames().contains(name) ?? false) {
            lines.append(verbose ? "\(name) is a shell builtin" : name)
            if !all { return lines.joined(separator: "\n") }
        }
        if let path = externalPath(for: name) {
            lines.append(verbose ? "\(name) is \(path)" : path)
        } else if executor.commandExists(name) {
            lines.append(verbose ? "\(name) is a toolchain command" : name)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func describeBody(_ command: Command) -> String {
        switch command {
        case .compound(.braceGroup, _, _): return "{ ... }"
        case .compound(.subshell, _, _): return "( ... )"
        default: return "{ ... }"
        }
    }

    private func jobFromSpecifier(_ specifier: String) -> Job? {
        var text = specifier
        if text.hasPrefix("%") { text.removeFirst() }
        if text == "%" || text == "+" { return jobs.all.last }
        guard let id = Int(text) else { return nil }
        return jobs.job(withID: id)
    }

    private func builtinKill(_ args: [String], out: (String) throws -> Void) -> Int32 {
        var remaining = args
        if remaining.first == "-l" || remaining.first == "-L" {
            let names = ["HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "EMT", "FPE", "KILL", "BUS", "SEGV", "SYS", "PIPE", "ALRM", "TERM", "URG", "STOP", "TSTP", "CONT", "CHLD", "TTIN", "TTOU", "IO", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "INFO", "USR1", "USR2"]
            try? out(names.enumerated().map { "\($0.offset + 1)) SIG\($0.element)" }.joined(separator: "\n") + "\n")
            return 0
        }
        while let first = remaining.first, first.hasPrefix("-"), first.count > 1, Int(first) == nil {
            // -9, -TERM, -s SIG: the signal does not matter, every signal interrupts the job.
            if first == "-s" { remaining.removeFirst() }
            remaining.removeFirst()
        }
        guard !remaining.isEmpty else {
            reportError("kill: usage: kill [-s sigspec | -signum] jobspec")
            return 2
        }
        var status: Int32 = 0
        for specifier in remaining {
            guard let job = jobFromSpecifier(specifier) else {
                reportError("kill: \(specifier): no such job")
                status = 1
                continue
            }
            job.cancel()
            executor.interruptRunningCommand()
        }
        return status
    }

    // MARK: cd

    private func builtinCD(_ args: [String]) throws -> Int32 {
        var remaining = args
        remaining.removeAll { $0 == "-L" || $0 == "-P" || $0 == "-e" || $0 == "-@" }
        var target: String
        var printTarget = false
        if remaining.isEmpty {
            guard let home = ctx.value("HOME") else {
                reportError("cd: HOME not set")
                return 1
            }
            target = home
        } else if remaining[0] == "-" {
            guard let previous = ctx.previousDirectory ?? ctx.value("OLDPWD") else {
                reportError("cd: OLDPWD not set")
                return 1
            }
            target = previous
            printTarget = true
        } else {
            target = remaining[0]
        }

        var candidates = [ctx.absolutePath(target)]
        if !target.hasPrefix("/"), !target.hasPrefix("."), !target.hasPrefix("~"), let cdpath = ctx.value("CDPATH") {
            for directory in cdpath.split(separator: ":", omittingEmptySubsequences: false) {
                let base = directory.isEmpty ? ctx.workingDirectory : String(directory)
                candidates.append(PathNormalizer.normalize(ctx.absolutePath(base) + "/" + target))
            }
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    reportError("cd: \(target): Not a directory")
                    return 1
                }
                guard FileManager.default.isReadableFile(atPath: candidate) || access(candidate, X_OK) == 0 else {
                    reportError("cd: \(target): Permission denied")
                    return 1
                }
                let previous = ctx.workingDirectory
                ctx.previousDirectory = previous
                ctx.workingDirectory = candidate
                try? ctx.setValue(previous, for: "OLDPWD", exported: true)
                try? ctx.setValue(candidate, for: "PWD", exported: true)
                if printTarget || candidate != candidates[0] {
                    try write(candidate + "\n", to: outputDescriptor)
                }
                host?.shellDidChangeDirectory(candidate)
                return 0
            }
        }
        reportError("cd: \(target): No such file or directory")
        return 1
    }

    // MARK: source and eval

    private func builtinSource(_ args: [String]) throws -> Int32 {
        guard let file = args.first else {
            reportError("source: filename argument required")
            return 2
        }
        var path = ctx.absolutePath(file)
        if !file.contains("/"), !FileManager.default.fileExists(atPath: path) {
            if let found = externalPath(for: file) ?? searchPathForReadable(file) { path = found }
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            reportError("source: \(file): No such file or directory")
            return 1
        }
        let source = String(decoding: data, as: UTF8.self)
        let savedPositional = ctx.positional
        let savedScriptName = ctx.scriptName
        if args.count > 1 { ctx.positional = Array(args.dropFirst()) }
        ctx.scriptName = file
        ctx.sourceDepth += 1
        defer {
            ctx.sourceDepth -= 1
            ctx.scriptName = savedScriptName
            if args.count > 1 { ctx.positional = savedPositional }
        }
        do {
            return try evaluateSource(source)
        } catch ControlFlow.returnFromFunction(let status) {
            ctx.lastStatus = status
            return status
        }
    }

    private func searchPathForReadable(_ name: String) -> String? {
        for directory in (ctx.value("PATH") ?? "").split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isReadableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Parses and runs `source` in the current interpreter (used by eval, source and traps).
    func evaluateSource(_ source: String) throws -> Int32 {
        let parser = Parser(source: source, aliasLookup: { [weak self] in self?.ctx.aliases[$0] })
        var status: Int32 = ctx.lastStatus
        do {
            while let list = try parser.parseCompleteCommand() {
                status = try execute(list)
            }
        } catch let error as ParseError {
            reportError(describe(error), line: error.line)
            ctx.lastStatus = 2
            return 2
        }
        return status
    }

    // MARK: set

    private func builtinSet(_ args: [String], out: (String) throws -> Void) throws -> Int32 {
        if args.isEmpty {
            for name in ctx.visibleVariableNames {
                if let value = ctx.value(name) {
                    try out("\(name)=\(Interpreter.quoteForTrace(value))\n")
                }
            }
            return 0
        }
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                ctx.positional = Array(args[(index + 1)...])
                return 0
            }
            if argument == "-" {
                ctx.positional = Array(args[(index + 1)...])
                return 0
            }
            guard argument.hasPrefix("-") || argument.hasPrefix("+") else {
                ctx.positional = Array(args[index...])
                return 0
            }
            let enable = argument.hasPrefix("-")
            let flags = argument.dropFirst()
            if flags == "o" {
                index += 1
                if index >= args.count {
                    try printOptions(out: out, enable: enable)
                    return 0
                }
                guard setLongOption(String(args[index]), enable: enable) else {
                    reportError("set: \(args[index]): invalid option name")
                    return 2
                }
                index += 1
                continue
            }
            for flag in flags {
                switch flag {
                case "e": ctx.options.errexit = enable
                case "x": ctx.options.xtrace = enable
                case "u": ctx.options.nounset = enable
                case "f": ctx.options.noglob = enable
                case "C": ctx.options.noclobber = enable
                case "a": ctx.options.allexport = enable
                case "v": ctx.options.verbose = enable
                case "h", "m", "B", "H", "b", "p", "n", "T", "k", "E", "t": break
                default:
                    reportError("set: -\(flag): invalid option")
                    return 2
                }
            }
            index += 1
        }
        return 0
    }

    private func setLongOption(_ name: String, enable: Bool) -> Bool {
        switch name {
        case "errexit": ctx.options.errexit = enable
        case "xtrace": ctx.options.xtrace = enable
        case "nounset": ctx.options.nounset = enable
        case "noglob": ctx.options.noglob = enable
        case "noclobber": ctx.options.noclobber = enable
        case "allexport": ctx.options.allexport = enable
        case "pipefail": ctx.options.pipefail = enable
        case "verbose": ctx.options.verbose = enable
        case "posix", "emacs", "vi", "monitor", "braceexpand", "hashall", "histexpand", "history", "interactive-comments", "notify", "nolog", "onecmd", "physical", "privileged", "errtrace", "functrace", "ignoreeof", "keyword": break
        default: return false
        }
        return true
    }

    private func printOptions(out: (String) throws -> Void, enable: Bool) throws {
        let settings: [(String, Bool)] = [
            ("allexport", ctx.options.allexport), ("errexit", ctx.options.errexit), ("noclobber", ctx.options.noclobber),
            ("noglob", ctx.options.noglob), ("nounset", ctx.options.nounset), ("pipefail", ctx.options.pipefail),
            ("verbose", ctx.options.verbose), ("xtrace", ctx.options.xtrace),
        ]
        for (name, value) in settings {
            if enable {
                try out("\(name.padding(toLength: 15, withPad: " ", startingAt: 0))\(value ? "on" : "off")\n")
            } else {
                try out("set \(value ? "-o" : "+o") \(name)\n")
            }
        }
    }

    // MARK: export, readonly, declare, local

    private func builtinDeclare(_ name: String, _ args: [String], out: (String) throws -> Void) throws -> Int32 {
        var remaining = args
        var exportFlag = name == "export"
        var unexport = false
        var readonlyFlag = name == "readonly"
        var print = false
        var functionMode = false
        var local = name == "local"
        while let first = remaining.first, first.hasPrefix("-") || first.hasPrefix("+"), first.count > 1, first != "--" {
            let enable = first.hasPrefix("-")
            for flag in first.dropFirst() {
                switch flag {
                case "x": if enable { exportFlag = true } else { unexport = true }
                case "n": unexport = true
                case "p": print = true
                case "r": readonlyFlag = enable
                case "f": functionMode = true
                case "g": local = false
                case "a", "A":
                    reportError("\(name): arrays are not supported")
                    return 1
                case "i", "l", "u", "t", "F", "I": break
                default:
                    reportError("\(name): -\(flag): invalid option")
                    return 2
                }
            }
            remaining.removeFirst()
        }
        if remaining.first == "--" { remaining.removeFirst() }

        if local, ctx.scopes.isEmpty {
            reportError("local: can only be used in a function")
            return 1
        }

        if remaining.isEmpty || print {
            if functionMode {
                for functionName in ctx.functions.keys.sorted() { try out("\(functionName) () { ... }\n") }
                return 0
            }
            for variableName in ctx.visibleVariableNames {
                guard let variable = ctx.variable(variableName) else { continue }
                if name == "export", !variable.exported { continue }
                if name == "readonly", !variable.readonly { continue }
                if print, !remaining.isEmpty, !remaining.contains(variableName) { continue }
                let prefix = name == "export" ? "export" : (name == "readonly" ? "readonly" : "declare -\(variable.exported ? "x" : "-")")
                if let value = variable.value {
                    try out("\(prefix) \(variableName)=\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"\n")
                } else {
                    try out("\(prefix) \(variableName)\n")
                }
            }
            return 0
        }

        var status: Int32 = 0
        for argument in remaining {
            var variableName = argument
            var value: String?
            var append = false
            if let assignment = Parser.splitAssignment(argument) {
                variableName = assignment.name
                value = assignment.value
                append = assignment.append
            }
            guard Parser.isValidName(variableName) else {
                reportError("\(name): `\(argument)': not a valid identifier")
                status = 1
                continue
            }
            do {
                if local {
                    // `local x` declares an unset local; `local x=v` sets it in the function scope.
                    let newValue = append ? (ctx.value(variableName) ?? "") + (value ?? "") : value
                    ctx.declareLocal(variableName, value: newValue)
                } else if let value {
                    let newValue = append ? (ctx.value(variableName) ?? "") + value : value
                    try ctx.setValue(newValue, for: variableName)
                }
                if exportFlag { ctx.setExported(variableName, true) }
                if unexport { ctx.setExported(variableName, false) }
                if readonlyFlag { ctx.setReadonly(variableName) }
            } catch let error as ShellRuntimeError {
                reportError("\(name): \(error.message)")
                status = 1
            }
        }
        return status
    }

    // MARK: trap

    private static let signalNames: [String: String] = [
        "0": "EXIT", "EXIT": "EXIT", "1": "HUP", "HUP": "HUP", "2": "INT", "INT": "INT", "3": "QUIT", "QUIT": "QUIT",
        "9": "KILL", "KILL": "KILL", "13": "PIPE", "PIPE": "PIPE", "14": "ALRM", "ALRM": "ALRM", "15": "TERM", "TERM": "TERM",
        "ERR": "ERR", "DEBUG": "DEBUG", "RETURN": "RETURN", "USR1": "USR1", "USR2": "USR2", "WINCH": "WINCH", "CHLD": "CHLD",
    ]

    private func builtinTrap(_ args: [String], out: (String) throws -> Void) throws -> Int32 {
        if args.isEmpty || args == ["-p"] {
            for (signal, action) in ctx.traps.sorted(by: { $0.key < $1.key }) {
                try out("trap -- '\(action.replacingOccurrences(of: "'", with: "'\\''"))' \(signal)\n")
            }
            return 0
        }
        if args == ["-l"] {
            try out(" 1) SIGHUP\t 2) SIGINT\t 3) SIGQUIT\t 9) SIGKILL\t13) SIGPIPE\t14) SIGALRM\t15) SIGTERM\n")
            return 0
        }
        var remaining = args
        if remaining.first == "--" { remaining.removeFirst() }
        guard let first = remaining.first else { return 0 }
        var action: String? = first
        var signals = Array(remaining.dropFirst())
        if signals.isEmpty {
            // `trap EXIT` resets the handler.
            signals = [first]
            action = nil
        }
        if action == "-" { action = nil }
        for signal in signals {
            let key = signal.uppercased().replacingOccurrences(of: "SIG", with: "")
            guard let normalized = Interpreter.signalNames[key] else {
                reportError("trap: \(signal): invalid signal specification")
                return 1
            }
            if let action {
                ctx.traps[normalized] = action
            } else {
                ctx.traps.removeValue(forKey: normalized)
            }
        }
        return 0
    }

    // MARK: getopts

    private func builtinGetopts(_ args: [String]) throws -> Int32 {
        guard args.count >= 2 else {
            reportError("getopts: usage: getopts optstring name [arg ...]")
            return 2
        }
        var optstring = args[0]
        let variable = args[1]
        let silent = optstring.hasPrefix(":")
        if silent { optstring.removeFirst() }
        let arguments = args.count > 2 ? Array(args[2...]) : ctx.positional
        var optind = Int(ctx.value("OPTIND") ?? "1") ?? 1
        if optind < 1 { optind = 1; ctx.getoptsPosition = 0 }

        func finish(_ value: String) throws -> Int32 {
            try ctx.setValue(value, for: variable)
            try ctx.setValue(String(optind), for: "OPTIND")
            return 0
        }
        func done() throws -> Int32 {
            try ctx.setValue("?", for: variable)
            try ctx.setValue(String(optind), for: "OPTIND")
            ctx.getoptsPosition = 0
            return 1
        }

        if ctx.getoptsPosition == 0 {
            guard optind <= arguments.count else { return try done() }
            let current = arguments[optind - 1]
            if current == "--" {
                optind += 1
                return try done()
            }
            guard current.hasPrefix("-"), current.count > 1 else { return try done() }
            ctx.getoptsPosition = 1
        }
        let current = Array(arguments[optind - 1])
        let option = current[ctx.getoptsPosition]
        ctx.getoptsPosition += 1
        let atEnd = ctx.getoptsPosition >= current.count

        guard option != ":", let location = optstring.firstIndex(of: option) else {
            if atEnd { optind += 1; ctx.getoptsPosition = 0 }
            if silent {
                try ctx.setValue(String(option), for: "OPTARG")
            } else {
                try ctx.unset("OPTARG")
                reportError("illegal option -- \(option)")
            }
            return try finish("?")
        }
        let next = optstring.index(after: location)
        let requiresArgument = next < optstring.endIndex && optstring[next] == ":"
        if requiresArgument {
            if !atEnd {
                try ctx.setValue(String(current[ctx.getoptsPosition...]), for: "OPTARG")
                optind += 1
                ctx.getoptsPosition = 0
                return try finish(String(option))
            }
            ctx.getoptsPosition = 0
            if optind < arguments.count {
                try ctx.setValue(arguments[optind], for: "OPTARG")
                optind += 2
                return try finish(String(option))
            }
            optind += 1
            if silent {
                try ctx.setValue(String(option), for: "OPTARG")
                return try finish(":")
            }
            try ctx.unset("OPTARG")
            reportError("option requires an argument -- \(option)")
            return try finish("?")
        }
        try ctx.unset("OPTARG")
        if atEnd {
            optind += 1
            ctx.getoptsPosition = 0
        }
        return try finish(String(option))
    }

    // MARK: read

    private func builtinRead(_ args: [String], io: ShellIO) throws -> Int32 {
        var raw = false
        var silent = false
        var prompt = ""
        var delimiter: Character? = "\n"
        var maxCharacters: Int?
        var timeout: Double?
        var names: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { index += 1; break }
            guard argument.hasPrefix("-"), argument.count > 1 else { break }
            var flags = Array(argument.dropFirst())
            while !flags.isEmpty {
                let flag = flags.removeFirst()
                switch flag {
                case "r": raw = true
                case "s": silent = true
                case "e", "i": break
                case "a":
                    reportError("read: -a: arrays are not supported")
                    return 2
                case "p", "d", "n", "N", "t", "u":
                    var value = String(flags)
                    flags.removeAll()
                    if value.isEmpty {
                        index += 1
                        guard index < args.count else {
                            reportError("read: -\(flag): option requires an argument")
                            return 2
                        }
                        value = args[index]
                    }
                    switch flag {
                    case "p": prompt = value
                    case "d": delimiter = value.first
                    case "n", "N": maxCharacters = Int(value)
                    case "t": timeout = Double(value)
                    default: break
                    }
                default:
                    reportError("read: -\(flag): invalid option")
                    return 2
                }
            }
            index += 1
        }
        names = Array(args[index...])
        for variable in names where !Parser.isValidName(variable) {
            reportError("read: `\(variable)': not a valid identifier")
            return 2
        }

        var line: String
        var sawEOF = false
        if io.stdin < 0 {
            guard let host else { return 1 }
            guard let input = host.readLine(prompt: prompt, secure: silent) else { return 1 }
            line = input
            if !raw {
                line = Interpreter.processReadEscapes(line)
            }
            if let maxCharacters { line = String(line.prefix(maxCharacters)) }
        } else {
            if !prompt.isEmpty {
                FileDescriptorIO.writeAll(io.stderr, prompt)
            }
            var bytes: [UInt8] = []
            var escaped = false
            var count = 0
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            readLoop: while true {
                if let deadline {
                    var pollfd = pollfd(fd: io.stdin, events: Int16(POLLIN), revents: 0)
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    let ready = poll(&pollfd, 1, Int32(remaining * 1000))
                    if ready <= 0 {
                        try assignReadResults(String(decoding: bytes, as: UTF8.self), names: names)
                        return 142
                    }
                }
                var byte: UInt8 = 0
                let result = read(io.stdin, &byte, 1)
                if result < 0 {
                    if errno == EINTR { continue }
                    sawEOF = true
                    break
                }
                if result == 0 { sawEOF = true; break }
                if !raw, escaped {
                    escaped = false
                    if byte == UInt8(ascii: "\n") { continue }
                    bytes.append(byte)
                    count += 1
                } else if !raw, byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if let delimiter, byte == delimiter.asciiValue {
                    break readLoop
                } else {
                    bytes.append(byte)
                    count += 1
                }
                if let maxCharacters, count >= maxCharacters { break }
            }
            line = String(decoding: bytes, as: UTF8.self)
            if sawEOF && line.isEmpty {
                try assignReadResults("", names: names)
                return 1
            }
        }
        try assignReadResults(line, names: names)
        return sawEOF ? 1 : 0
    }

    private static func processReadEscapes(_ line: String) -> String {
        var result = ""
        var iterator = line.makeIterator()
        while let c = iterator.next() {
            if c == "\\" {
                if let next = iterator.next() { result.append(next) }
            } else {
                result.append(c)
            }
        }
        return result
    }

    private func assignReadResults(_ line: String, names: [String]) throws {
        guard !names.isEmpty else {
            try ctx.setValue(line, for: "REPLY")
            return
        }
        let ifs = ctx.value("IFS") ?? " \t\n"
        let whitespace = Set(ifs.filter { $0 == " " || $0 == "\t" || $0 == "\n" })
        var remaining = Substring(line)
        // Trim leading and trailing IFS whitespace.
        while let first = remaining.first, whitespace.contains(first) { remaining.removeFirst() }
        while let last = remaining.last, whitespace.contains(last) { remaining.removeLast() }
        var values: [String] = []
        for position in names.indices {
            if position == names.count - 1 {
                values.append(String(remaining))
                break
            }
            if remaining.isEmpty {
                values.append("")
                continue
            }
            // Next field ends at the first IFS character.
            if let separatorIndex = remaining.firstIndex(where: { ifs.contains($0) }) {
                values.append(String(remaining[..<separatorIndex]))
                remaining = remaining[separatorIndex...]
                // Skip one non whitespace separator plus surrounding whitespace, or a run of whitespace.
                if let first = remaining.first, !whitespace.contains(first) {
                    remaining.removeFirst()
                }
                while let first = remaining.first, whitespace.contains(first) { remaining.removeFirst() }
            } else {
                values.append(String(remaining))
                remaining = ""
            }
        }
        while values.count < names.count { values.append("") }
        for (name, value) in zip(names, values) {
            try ctx.setValue(value, for: name)
        }
    }
}
