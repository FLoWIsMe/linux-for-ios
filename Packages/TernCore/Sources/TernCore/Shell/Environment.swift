import Foundation

/// One shell variable. `value == nil` means the variable is declared (for example with `local`) but unset.
struct ShellVariable: Equatable {
    var value: String?
    var exported: Bool = false
    var readonly: Bool = false
}

/// A logical descriptor of the running command (0, 1, 2 or any `n` opened with `exec n<file`).
struct FDEntry: Equatable {
    /// The real descriptor, or -1 for "the terminal keyboard, opened lazily through the host".
    var fd: Int32
    /// True when this descriptor is the terminal rather than a file or a pipe.
    var isTerminal: Bool

    static let lazyTerminalInput = FDEntry(fd: -1, isTerminal: true)
}

/// Control flow transported with Swift errors so that deeply nested execution unwinds cleanly.
enum ControlFlow: Error {
    case breakLoop(levels: Int)
    case continueLoop(levels: Int)
    case returnFromFunction(status: Int32)
    case exitShell(status: Int32)
    /// `set -e` triggered; carries the failing status.
    case errexit(status: Int32)
    case interrupted
}

/// The complete mutable state of one shell (or subshell). It is a value type so that subshells
/// and pipeline stages can start from a cheap copy and never leak changes back.
struct ShellContext {
    var globals: [String: ShellVariable] = [:]
    /// Function call frames, innermost last. Each frame holds the names declared `local`.
    var scopes: [[String: ShellVariable]] = []
    var functions: [String: FunctionDefinition] = [:]
    var aliases: [String: String] = [:]
    var options = ShellOptions()
    var positional: [String] = []
    var scriptName: String
    var workingDirectory: String
    var previousDirectory: String?
    var directoryStack: [String] = []
    var lastStatus: Int32 = 0
    var lastBackgroundJob: Int = 0
    var lastArgument: String = ""
    var traps: [String: String] = [:]
    var fdTable: [Int32: FDEntry]
    var functionDepth: Int = 0
    var loopDepth: Int = 0
    var subshellDepth: Int = 0
    var currentLine: Int = 0
    /// Greater than zero while evaluating conditions and non-final parts of `&&`/`||` lists,
    /// where `set -e` must not fire.
    var errexitSuppression: Int = 0
    /// Character offset inside the option cluster `getopts` is currently scanning.
    var getoptsPosition: Int = 0
    /// Greater than zero while `source` runs a file, so `return` is allowed outside functions.
    var sourceDepth: Int = 0
    /// Set by `exec` without a command so the current redirections outlive the command.
    var keepRedirections = false
    /// `$0` inside functions is the script name; `FUNCNAME` style tracking is minimal.
    var functionStack: [String] = []
    let startTime = Date()
    let shellPID: Int32 = getpid()

    init(scriptName: String, workingDirectory: String, fdTable: [Int32: FDEntry]) {
        self.scriptName = scriptName
        self.workingDirectory = workingDirectory
        self.fdTable = fdTable
    }

    // MARK: Variables

    func variable(_ name: String) -> ShellVariable? {
        for scope in scopes.reversed() {
            if let variable = scope[name] { return variable }
        }
        return globals[name]
    }

    /// The value of a variable, including dynamic ones. nil when unset.
    func value(_ name: String) -> String? {
        switch name {
        case "RANDOM": return String(Int.random(in: 0...32767))
        case "LINENO": return String(currentLine)
        case "SECONDS": return String(Int(Date().timeIntervalSince(startTime)))
        case "EPOCHSECONDS": return String(Int(Date().timeIntervalSince1970))
        case "EPOCHREALTIME": return String(format: "%.6f", Date().timeIntervalSince1970)
        case "PWD": return workingDirectory
        case "OLDPWD": return previousDirectory ?? variable("OLDPWD")?.value
        case "SHLVL": return variable("SHLVL")?.value ?? "1"
        case "FUNCNAME": return functionStack.last
        default: return variable(name)?.value
        }
    }

    func isSet(_ name: String) -> Bool { value(name) != nil }

    /// Sets a variable in the innermost scope that declares it, otherwise globally.
    mutating func setValue(_ value: String?, for name: String, exported: Bool? = nil) throws {
        for index in scopes.indices.reversed() {
            if var existing = scopes[index][name] {
                if existing.readonly { throw ShellRuntimeError.readonly(name) }
                existing.value = value
                if let exported { existing.exported = exported }
                scopes[index][name] = existing
                return
            }
        }
        var variable = globals[name] ?? ShellVariable(value: nil)
        if variable.readonly { throw ShellRuntimeError.readonly(name) }
        variable.value = value
        if let exported { variable.exported = exported }
        if options.allexport { variable.exported = true }
        globals[name] = variable
        if name == "OLDPWD" { previousDirectory = value }
    }

    /// Declares `name` in the current function scope.
    mutating func declareLocal(_ name: String, value: String?) {
        guard !scopes.isEmpty else { return }
        var variable = scopes[scopes.count - 1][name] ?? ShellVariable(value: nil)
        variable.value = value
        scopes[scopes.count - 1][name] = variable
    }

    mutating func unset(_ name: String) throws {
        for index in scopes.indices.reversed() {
            if let existing = scopes[index][name] {
                if existing.readonly { throw ShellRuntimeError.readonly(name) }
                scopes[index][name] = ShellVariable(value: nil, exported: existing.exported)
                return
            }
        }
        if let existing = globals[name] {
            if existing.readonly { throw ShellRuntimeError.readonly(name) }
            globals.removeValue(forKey: name)
        }
    }

    mutating func setExported(_ name: String, _ exported: Bool) {
        for index in scopes.indices.reversed() {
            if var existing = scopes[index][name] {
                existing.exported = exported
                scopes[index][name] = existing
                return
            }
        }
        var variable = globals[name] ?? ShellVariable(value: nil)
        variable.exported = exported
        globals[name] = variable
    }

    mutating func setReadonly(_ name: String) {
        for index in scopes.indices.reversed() {
            if var existing = scopes[index][name] {
                existing.readonly = true
                scopes[index][name] = existing
                return
            }
        }
        var variable = globals[name] ?? ShellVariable(value: nil)
        variable.readonly = true
        globals[name] = variable
    }

    /// All variable names visible from the current scope, sorted.
    var visibleVariableNames: [String] {
        var names = Set(globals.keys)
        for scope in scopes { names.formUnion(scope.keys) }
        return names.sorted()
    }

    /// The environment passed to external commands: every exported variable plus PWD.
    func exportedEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        for (name, variable) in globals where variable.exported {
            if let value = variable.value { result[name] = value }
        }
        for scope in scopes {
            for (name, variable) in scope where variable.exported {
                if let value = variable.value { result[name] = value } else { result.removeValue(forKey: name) }
            }
        }
        result["PWD"] = workingDirectory
        if let previous = previousDirectory { result["OLDPWD"] = previous }
        return result
    }

    /// The `$-` string.
    var optionFlags: String {
        var flags = ""
        if options.allexport { flags += "a" }
        if options.noclobber { flags += "C" }
        if options.errexit { flags += "e" }
        if options.noglob { flags += "f" }
        if options.nounset { flags += "u" }
        if options.verbose { flags += "v" }
        if options.xtrace { flags += "x" }
        return flags + "h"
    }

    // MARK: Paths

    /// Resolves `path` against the working directory, expanding a leading `~`.
    func absolutePath(_ path: String) -> String {
        var result = path
        if result == "~" || result.hasPrefix("~/") {
            let home = value("HOME") ?? workingDirectory
            result = home + result.dropFirst()
        }
        if !result.hasPrefix("/") {
            result = workingDirectory.hasSuffix("/") ? workingDirectory + result : workingDirectory + "/" + result
        }
        return PathNormalizer.normalize(result)
    }
}

enum PathNormalizer {
    /// Collapses `.`, `..` and duplicate slashes without touching the file system.
    static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

enum ShellRuntimeError: Error {
    case readonly(String)
    case badSubstitution(String)
    case unboundVariable(String)
    case parameterNull(String, String)
    case arithmetic(String)
    case redirection(String)
    case syntax(String)
    case notFound(String)
    case generic(String)

    var message: String {
        switch self {
        case .readonly(let name): return "\(name): readonly variable"
        case .badSubstitution(let text): return "\(text): bad substitution"
        case .unboundVariable(let name): return "\(name): unbound variable"
        case .parameterNull(let name, let message): return "\(name): \(message.isEmpty ? "parameter null or not set" : message)"
        case .arithmetic(let message): return message
        case .redirection(let message): return message
        case .syntax(let message): return message
        case .notFound(let name): return "\(name): command not found"
        case .generic(let message): return message
        }
    }
}
