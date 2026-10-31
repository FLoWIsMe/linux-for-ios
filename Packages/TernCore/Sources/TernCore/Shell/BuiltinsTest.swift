import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `test`, `[` and the primaries shared with `[[ ]]`.
enum TestEvaluator {
    static let unaryOperators: Set<String> = [
        "-a", "-b", "-c", "-d", "-e", "-f", "-g", "-h", "-k", "-p", "-r", "-s", "-t", "-u", "-w", "-x",
        "-G", "-L", "-N", "-O", "-S", "-z", "-n", "-o", "-v", "-R",
    ]
    static let binaryOperators: Set<String> = [
        "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef",
    ]

    static func evaluate(_ args: [String], workingDirectory: String, options: ShellOptions) throws -> Bool {
        switch args.count {
        case 0:
            return false
        case 1:
            return !args[0].isEmpty
        case 2:
            if args[0] == "!" { return args[1].isEmpty }
            if unaryOperators.contains(args[0]) { return try unaryWithOptions(args[0], args[1], workingDirectory: workingDirectory, options: options) }
            throw ShellRuntimeError.generic("\(args[1]): unary operator expected")
        case 3:
            if binaryOperators.contains(args[1]) { return try binary(args[1], args[0], args[2], workingDirectory: workingDirectory) }
            if args[0] == "!" { return try !evaluate(Array(args[1...]), workingDirectory: workingDirectory, options: options) }
            if args[0] == "(", args[2] == ")" { return !args[1].isEmpty }
            if args[1] == "-a" { return !args[0].isEmpty && !args[2].isEmpty }
            if args[1] == "-o" { return !args[0].isEmpty || !args[2].isEmpty }
            throw ShellRuntimeError.generic("\(args[1]): binary operator expected")
        case 4:
            if args[0] == "!" { return try !evaluate(Array(args[1...]), workingDirectory: workingDirectory, options: options) }
            if args[0] == "(", args[3] == ")" { return try evaluate(Array(args[1...2]), workingDirectory: workingDirectory, options: options) }
            fallthrough
        default:
            var parser = ExpressionParser(args: args, workingDirectory: workingDirectory, options: options)
            let result = try parser.parseOr()
            if parser.index < args.count {
                throw ShellRuntimeError.generic("too many arguments")
            }
            return result
        }
    }

    private struct ExpressionParser {
        let args: [String]
        let workingDirectory: String
        let options: ShellOptions
        var index = 0

        init(args: [String], workingDirectory: String, options: ShellOptions) {
            self.args = args
            self.workingDirectory = workingDirectory
            self.options = options
        }

        var current: String? { index < args.count ? args[index] : nil }

        mutating func parseOr() throws -> Bool {
            var result = try parseAnd()
            while current == "-o" {
                index += 1
                let rhs = try parseAnd()
                result = result || rhs
            }
            return result
        }

        mutating func parseAnd() throws -> Bool {
            var result = try parseNot()
            while current == "-a" {
                index += 1
                let rhs = try parseNot()
                result = result && rhs
            }
            return result
        }

        mutating func parseNot() throws -> Bool {
            if current == "!" {
                index += 1
                return try !parseNot()
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Bool {
            guard let token = current else { throw ShellRuntimeError.generic("argument expected") }
            if token == "(" {
                index += 1
                let inner = try parseOr()
                guard current == ")" else { throw ShellRuntimeError.generic("`)' expected") }
                index += 1
                return inner
            }
            if index + 2 < args.count, TestEvaluator.binaryOperators.contains(args[index + 1]) {
                let result = try TestEvaluator.binary(args[index + 1], token, args[index + 2], workingDirectory: workingDirectory)
                index += 3
                return result
            }
            if TestEvaluator.unaryOperators.contains(token), index + 1 < args.count {
                let result = try TestEvaluator.unaryWithOptions(token, args[index + 1], workingDirectory: workingDirectory, options: options)
                index += 2
                return result
            }
            index += 1
            return !token.isEmpty
        }
    }

    static func optionIsSet(_ name: String, options: ShellOptions) -> Bool {
        switch name {
        case "errexit", "e": return options.errexit
        case "xtrace", "x": return options.xtrace
        case "nounset", "u": return options.nounset
        case "noglob", "f": return options.noglob
        case "noclobber", "C": return options.noclobber
        case "allexport", "a": return options.allexport
        case "pipefail": return options.pipefail
        case "verbose", "v": return options.verbose
        default: return false
        }
    }

    private static func unaryWithOptions(_ op: String, _ operand: String, workingDirectory: String, options: ShellOptions) throws -> Bool {
        if op == "-o" { return optionIsSet(operand, options: options) }
        if op == "-v" { return false }
        return unary(op, operand, workingDirectory: workingDirectory)
    }

    private static func resolve(_ path: String, _ workingDirectory: String) -> String {
        if path.hasPrefix("/") { return path }
        return workingDirectory.hasSuffix("/") ? workingDirectory + path : workingDirectory + "/" + path
    }

    private static func statInfo(_ path: String, followLinks: Bool = true) -> stat? {
        var info = stat()
        let result = followLinks ? stat(path, &info) : lstat(path, &info)
        return result == 0 ? info : nil
    }

    static func unary(_ op: String, _ operand: String, workingDirectory: String) -> Bool {
        switch op {
        case "-z": return operand.isEmpty
        case "-n": return !operand.isEmpty
        case "-t":
            guard let fd = Int32(operand) else { return false }
            return isatty(fd) != 0
        default: break
        }
        let path = resolve(operand, workingDirectory)
        switch op {
        case "-e", "-a": return statInfo(path) != nil
        case "-f": return statInfo(path).map { ($0.st_mode & S_IFMT) == S_IFREG } ?? false
        case "-d": return statInfo(path).map { ($0.st_mode & S_IFMT) == S_IFDIR } ?? false
        case "-h", "-L": return statInfo(path, followLinks: false).map { ($0.st_mode & S_IFMT) == S_IFLNK } ?? false
        case "-b": return statInfo(path).map { ($0.st_mode & S_IFMT) == S_IFBLK } ?? false
        case "-c": return statInfo(path).map { ($0.st_mode & S_IFMT) == S_IFCHR } ?? false
        case "-p": return statInfo(path).map { ($0.st_mode & S_IFMT) == S_IFIFO } ?? false
        case "-S": return statInfo(path).map { ($0.st_mode & S_IFMT) == S_IFSOCK } ?? false
        case "-s": return statInfo(path).map { $0.st_size > 0 } ?? false
        case "-r": return access(path, R_OK) == 0
        case "-w": return access(path, W_OK) == 0
        case "-x": return access(path, X_OK) == 0
        case "-g": return statInfo(path).map { ($0.st_mode & mode_t(S_ISGID)) != 0 } ?? false
        case "-u": return statInfo(path).map { ($0.st_mode & mode_t(S_ISUID)) != 0 } ?? false
        case "-k": return statInfo(path).map { ($0.st_mode & mode_t(S_ISVTX)) != 0 } ?? false
        case "-O": return statInfo(path).map { $0.st_uid == geteuid() } ?? false
        case "-G": return statInfo(path).map { $0.st_gid == getegid() } ?? false
        case "-N":
            guard let info = statInfo(path) else { return false }
            return modificationTime(info) > accessTime(info)
        case "-R": return false
        default: return false
        }
    }

    private static func modificationTime(_ info: stat) -> Double {
        #if canImport(Darwin)
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        #else
        return Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
        #endif
    }

    private static func accessTime(_ info: stat) -> Double {
        #if canImport(Darwin)
        return Double(info.st_atimespec.tv_sec) + Double(info.st_atimespec.tv_nsec) / 1e9
        #else
        return Double(info.st_atim.tv_sec) + Double(info.st_atim.tv_nsec) / 1e9
        #endif
    }

    static func integer(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return value }
        throw ShellRuntimeError.generic("\(text): integer expression expected")
    }

    static func binary(_ op: String, _ lhs: String, _ rhs: String, workingDirectory: String) throws -> Bool {
        switch op {
        case "=", "==": return lhs == rhs
        case "!=": return lhs != rhs
        case "<": return lhs < rhs
        case ">": return lhs > rhs
        case "-eq": return try integer(lhs) == integer(rhs)
        case "-ne": return try integer(lhs) != integer(rhs)
        case "-lt": return try integer(lhs) < integer(rhs)
        case "-le": return try integer(lhs) <= integer(rhs)
        case "-gt": return try integer(lhs) > integer(rhs)
        case "-ge": return try integer(lhs) >= integer(rhs)
        case "-nt", "-ot":
            let left = statInfo(resolve(lhs, workingDirectory))
            let right = statInfo(resolve(rhs, workingDirectory))
            guard let left else { return false }
            guard let right else { return op == "-nt" }
            return op == "-nt" ? modificationTime(left) > modificationTime(right) : modificationTime(left) < modificationTime(right)
        case "-ef":
            guard let left = statInfo(resolve(lhs, workingDirectory)), let right = statInfo(resolve(rhs, workingDirectory)) else { return false }
            return left.st_dev == right.st_dev && left.st_ino == right.st_ino
        default:
            throw ShellRuntimeError.generic("\(op): binary operator expected")
        }
    }
}
