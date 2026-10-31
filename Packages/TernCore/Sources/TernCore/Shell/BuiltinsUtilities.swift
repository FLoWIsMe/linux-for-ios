import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Small Unix utilities that the ios_system toolchain does not ship (it has sort, uniq, tr, wc,
/// head, tail, grep, sed and awk, but no cut, seq, yes, rev or tac). They are builtins so that
/// scripts written for a normal Linux box keep working. Each one reads files named on the
/// command line or standard input, like its coreutils namesake, and uses the same options people
/// reach for every day; exotic flags are left out on purpose.
extension Interpreter {
    static let utilityBuiltins: Set<String> = ["cut", "mktemp", "realpath", "rev", "seq", "tac", "tty", "yes"]

    func runUtilityBuiltin(name: String, args: [String], io: ShellIO) throws -> Int32 {
        switch name {
        case "seq": return try utilitySeq(args, io: io)
        case "yes": return try utilityYes(args, io: io)
        case "cut": return try utilityCut(args, io: io)
        case "rev": return try utilityRev(args, io: io)
        case "tac": return try utilityTac(args, io: io)
        case "mktemp": return try utilityMktemp(args, io: io)
        case "realpath": return try utilityRealpath(args, io: io)
        case "tty": return try utilityTty(io: io)
        default: return 127
        }
    }

    // MARK: Input helpers

    private func utilityPath(_ path: String) -> String {
        path.hasPrefix("/") ? PathNormalizer.normalize(path) : PathNormalizer.normalize(ctx.workingDirectory + "/" + path)
    }

    /// The lines of every named file ("-" or no file means standard input), without their newlines.
    private func utilityInputLines(_ files: [String], name: String, io: ShellIO) throws -> [String]? {
        var text = ""
        let sources = files.isEmpty ? ["-"] : files
        var failed = false
        for file in sources {
            if file == "-" {
                text += utilityReadStandardInput(io)
            } else {
                guard let data = FileManager.default.contents(atPath: utilityPath(file)) else {
                    reportError("\(name): \(file): No such file or directory")
                    failed = true
                    continue
                }
                text += String(decoding: data, as: UTF8.self)
            }
        }
        if failed { return nil }
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func utilityReadStandardInput(_ io: ShellIO) -> String {
        if io.stdin < 0 {
            // The keyboard: take lines until the user sends end of file.
            var collected = ""
            while let line = host?.readLine(prompt: "", secure: false) {
                collected += line + "\n"
            }
            return collected
        }
        return String(decoding: FileDescriptorIO.readAll(io.stdin), as: UTF8.self)
    }

    // MARK: seq

    private func utilitySeq(_ args: [String], io: ShellIO) throws -> Int32 {
        var separator = "\n"
        var equalWidth = false
        var format: String?
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "-s", "--separator":
                index += 1
                guard index < args.count else { reportError("seq: option requires an argument -- s"); return 2 }
                separator = args[index]
            case "-w", "--equal-width":
                equalWidth = true
            case "-f", "--format":
                index += 1
                guard index < args.count else { reportError("seq: option requires an argument -- f"); return 2 }
                format = args[index]
            case "--":
                operands.append(contentsOf: args[(index + 1)...])
                index = args.count
            default:
                if argument.hasPrefix("-s") { separator = String(argument.dropFirst(2)) }
                else if argument.hasPrefix("-f") { format = String(argument.dropFirst(2)) }
                else { operands.append(argument) }
            }
            index += 1
        }
        guard (1...3).contains(operands.count) else {
            reportError(operands.isEmpty ? "seq: missing operand" : "seq: extra operand '\(operands[3])'")
            return 2
        }
        if let format {
            // One floating point conversion, nothing else: String(format:) would crash on a bad one.
            let pattern = #"^([^%]|%%)*%[-+ #0]*[0-9]*(\.[0-9]+)?[eEfFgGaA]([^%]|%%)*$"#
            guard format.range(of: pattern, options: .regularExpression) != nil else {
                reportError("seq: invalid format string: '\(format)'")
                return 2
            }
        }
        var values: [Double] = []
        for operand in operands {
            guard let value = Double(operand) else {
                reportError("seq: invalid floating point argument: '\(operand)'")
                return 2
            }
            values.append(value)
        }
        let first = values.count == 1 ? 1 : values[0]
        let increment = values.count == 3 ? values[1] : 1
        let last = values[values.count - 1]
        guard increment != 0 else {
            reportError("seq: invalid Zero increment value: '\(operands[1])'")
            return 2
        }
        // Precision follows the operands, like coreutils: "seq 0 0.5 2" prints one decimal.
        let decimals = operands.map { operand -> Int in
            guard let dot = operand.firstIndex(of: ".") else { return 0 }
            return operand.distance(from: operand.index(after: dot), to: operand.endIndex)
        }.max() ?? 0
        var numbers: [String] = []
        var cursor = first
        var count = 0
        while increment > 0 ? cursor <= last + 1e-9 : cursor >= last - 1e-9 {
            if let format {
                numbers.append(String(format: format, cursor))
            } else {
                numbers.append(String(format: "%.\(decimals)f", cursor))
            }
            count += 1
            cursor = first + Double(count) * increment
            if count % 1024 == 0 { try checkInterrupt() }
        }
        if equalWidth, let width = numbers.map(\.count).max() {
            numbers = numbers.map { number in
                let negative = number.hasPrefix("-")
                let digits = negative ? String(number.dropFirst()) : number
                return (negative ? "-" : "") + String(repeating: "0", count: max(0, width - number.count)) + digits
            }
        }
        if numbers.isEmpty { return 0 }
        try write(numbers.joined(separator: separator) + "\n", to: io.stdout)
        return 0
    }

    // MARK: yes

    private func utilityYes(_ args: [String], io: ShellIO) throws -> Int32 {
        let line = (args.isEmpty ? "y" : args.joined(separator: " ")) + "\n"
        let chunk = String(repeating: line, count: max(1, 4096 / max(1, line.utf8.count)))
        while true {
            try checkInterrupt()
            try write(chunk, to: io.stdout)
        }
    }

    // MARK: cut

    private struct FieldRange {
        let lower: Int       // 1 based, inclusive
        let upper: Int?      // nil means open ended

        func contains(_ position: Int) -> Bool {
            position >= lower && (upper == nil || position <= upper!)
        }
    }

    private func parseCutList(_ list: String) -> [FieldRange]? {
        var ranges: [FieldRange] = []
        for part in list.split(separator: ",", omittingEmptySubsequences: true) {
            let text = String(part)
            if let dash = text.firstIndex(of: "-") {
                let lowerText = String(text[..<dash])
                let upperText = String(text[text.index(after: dash)...])
                let lower = lowerText.isEmpty ? 1 : Int(lowerText)
                let upper = upperText.isEmpty ? nil : Int(upperText)
                guard let lower, lower >= 1 else { return nil }
                if let upper, upper < lower { return nil }
                if upperText.isEmpty == false, upper == nil { return nil }
                ranges.append(FieldRange(lower: lower, upper: upper))
            } else {
                guard let value = Int(text), value >= 1 else { return nil }
                ranges.append(FieldRange(lower: value, upper: value))
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    private func utilityCut(_ args: [String], io: ShellIO) throws -> Int32 {
        enum Mode { case bytes, characters, fields }
        var mode: Mode?
        var list: String?
        var delimiter: Character = "\t"
        var outputDelimiter: String?
        var onlyDelimited = false
        var complement = false
        var files: [String] = []
        var index = 0
        func takeValue(_ flag: String, inline: String) -> String? {
            if !inline.isEmpty { return inline }
            index += 1
            guard index < args.count else {
                reportError("cut: option requires an argument -- '\(flag)'")
                return nil
            }
            return args[index]
        }
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                files.append(contentsOf: args[(index + 1)...])
                break
            }
            if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                let key = body.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                let inline = body.contains("=") ? String(body.split(separator: "=", maxSplits: 1)[1]) : ""
                switch key {
                case "bytes": mode = .bytes; guard let value = takeValue(key, inline: inline) else { return 2 }; list = value
                case "characters": mode = .characters; guard let value = takeValue(key, inline: inline) else { return 2 }; list = value
                case "fields": mode = .fields; guard let value = takeValue(key, inline: inline) else { return 2 }; list = value
                case "delimiter": guard let value = takeValue(key, inline: inline), let first = value.first else { return 2 }; delimiter = first
                case "output-delimiter": guard let value = takeValue(key, inline: inline) else { return 2 }; outputDelimiter = value
                case "only-delimited": onlyDelimited = true
                case "complement": complement = true
                default:
                    reportError("cut: unrecognized option '\(argument)'")
                    return 2
                }
            } else if argument.hasPrefix("-"), argument.count > 1 {
                let flag = String(argument[argument.index(after: argument.startIndex)])
                let inline = String(argument.dropFirst(2))
                switch flag {
                case "b": mode = .bytes; guard let value = takeValue(flag, inline: inline) else { return 2 }; list = value
                case "c": mode = .characters; guard let value = takeValue(flag, inline: inline) else { return 2 }; list = value
                case "f": mode = .fields; guard let value = takeValue(flag, inline: inline) else { return 2 }; list = value
                case "d":
                    guard let value = takeValue(flag, inline: inline) else { return 2 }
                    guard let first = value.first else { reportError("cut: the delimiter must be a single character"); return 2 }
                    delimiter = first
                case "s": onlyDelimited = true
                case "n": break
                default:
                    reportError("cut: invalid option -- '\(flag)'")
                    return 2
                }
            } else {
                files.append(argument)
            }
            index += 1
        }
        guard let mode, let list else {
            reportError("cut: you must specify a list of bytes, characters, or fields")
            return 2
        }
        guard let ranges = parseCutList(list) else {
            reportError("cut: invalid list '\(list)'")
            return 2
        }
        func selected(_ position: Int) -> Bool {
            let inList = ranges.contains { $0.contains(position) }
            return complement ? !inList : inList
        }
        guard let lines = try utilityInputLines(files, name: "cut", io: io) else { return 1 }
        var output = ""
        for line in lines {
            switch mode {
            case .characters:
                output += String(line.enumerated().filter { selected($0.offset + 1) }.map(\.element))
            case .bytes:
                let bytes = Array(line.utf8).enumerated().filter { selected($0.offset + 1) }.map(\.element)
                output += String(decoding: bytes, as: UTF8.self)
            case .fields:
                if !line.contains(delimiter) {
                    // Lines without the delimiter are passed through whole unless -s says to drop them.
                    if onlyDelimited { continue }
                    output += line
                } else {
                    let fields = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
                    let picked = fields.enumerated().filter { selected($0.offset + 1) }.map(\.element)
                    output += picked.joined(separator: outputDelimiter ?? String(delimiter))
                }
            }
            output += "\n"
        }
        try write(output, to: io.stdout)
        return 0
    }

    // MARK: rev, tac

    private func utilityRev(_ args: [String], io: ShellIO) throws -> Int32 {
        guard let lines = try utilityInputLines(args.filter { $0 != "--" }, name: "rev", io: io) else { return 1 }
        try write(lines.map { String($0.reversed()) + "\n" }.joined(), to: io.stdout)
        return 0
    }

    private func utilityTac(_ args: [String], io: ShellIO) throws -> Int32 {
        guard let lines = try utilityInputLines(args.filter { $0 != "--" }, name: "tac", io: io) else { return 1 }
        try write(lines.reversed().map { $0 + "\n" }.joined(), to: io.stdout)
        return 0
    }

    // MARK: mktemp

    private func utilityMktemp(_ args: [String], io: ShellIO) throws -> Int32 {
        var directory = false
        var quiet = false
        var prefix: String?
        var template: String?
        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "-d", "--directory": directory = true
            case "-q", "--quiet": quiet = true
            case "-u", "--dry-run": break
            case "-t":
                index += 1
                guard index < args.count else { reportError("mktemp: option requires an argument -- 't'"); return 2 }
                prefix = args[index]
            case "--": break
            default:
                if argument.hasPrefix("-t") { prefix = String(argument.dropFirst(2)) }
                else if argument.hasPrefix("--tmpdir=") { break }
                else if argument.hasPrefix("-") { reportError("mktemp: invalid option -- '\(argument)'"); return 2 }
                else { template = argument }
            }
            index += 1
        }
        let temporaryDirectory = ctx.value("TMPDIR").flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        var pattern: String
        if let template {
            pattern = template.contains("/") ? utilityPath(template) : (prefix == nil ? utilityPath(template) : PathNormalizer.normalize(temporaryDirectory + "/" + template))
        } else {
            pattern = PathNormalizer.normalize(temporaryDirectory + "/" + (prefix ?? "tmp") + ".XXXXXXXXXX")
        }
        let trailing = pattern.reversed().prefix { $0 == "X" }.count
        guard trailing >= 3 else {
            if !quiet { reportError("mktemp: too few X's in template '\(pattern)'") }
            return 1
        }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let base = String(pattern.dropLast(trailing))
        for _ in 0..<100 {
            let suffix = String((0..<trailing).map { _ in alphabet.randomElement()! })
            let candidate = base + suffix
            if directory {
                if mkdir(candidate, 0o700) == 0 {
                    try write(candidate + "\n", to: io.stdout)
                    return 0
                }
            } else {
                let fd = open(candidate, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if fd >= 0 {
                    close(fd)
                    try write(candidate + "\n", to: io.stdout)
                    return 0
                }
            }
            if errno != EEXIST { break }
        }
        if !quiet { reportError("mktemp: failed to create \(directory ? "directory" : "file") via template '\(pattern)': \(String(cString: strerror(errno)))") }
        return 1
    }

    // MARK: realpath, tty

    private func utilityRealpath(_ args: [String], io: ShellIO) throws -> Int32 {
        var allowMissing = false
        var quiet = false
        var paths: [String] = []
        for argument in args {
            switch argument {
            case "-m", "--canonicalize-missing": allowMissing = true
            case "-e", "--canonicalize-existing": allowMissing = false
            case "-q", "--quiet": quiet = true
            case "-s", "--strip", "--no-symlinks", "-P", "--physical", "--": break
            default:
                if argument.hasPrefix("-") { reportError("realpath: invalid option -- '\(argument)'"); return 2 }
                paths.append(argument)
            }
        }
        guard !paths.isEmpty else {
            reportError("realpath: missing operand")
            return 2
        }
        var status: Int32 = 0
        var output = ""
        for path in paths {
            let absolute = utilityPath(path)
            if !allowMissing, !FileManager.default.fileExists(atPath: absolute) {
                if !quiet { reportError("realpath: \(path): No such file or directory") }
                status = 1
                continue
            }
            output += URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path + "\n"
        }
        try write(output, to: io.stdout)
        return status
    }

    private func utilityTty(io: ShellIO) throws -> Int32 {
        if io.stdin < 0 {
            try write("/dev/tty\n", to: io.stdout)
            return 0
        }
        try write("not a tty\n", to: io.stdout)
        return 1
    }
}
