import Foundation

extension Interpreter {
    // MARK: echo

    func builtinEcho(_ args: [String], out: (String) throws -> Void) throws -> Int32 {
        var newline = true
        var interpret = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            guard argument.hasPrefix("-"), argument.count > 1, argument.dropFirst().allSatisfy({ "neE".contains($0) }) else { break }
            for flag in argument.dropFirst() {
                switch flag {
                case "n": newline = false
                case "e": interpret = true
                case "E": interpret = false
                default: break
                }
            }
            index += 1
        }
        var text = args[index...].joined(separator: " ")
        if interpret {
            let (decoded, stop) = Interpreter.decodeEchoEscapes(text)
            text = decoded
            if stop { newline = false }
        }
        try out(newline ? text + "\n" : text)
        return 0
    }

    /// Decodes echo style escapes. Returns the text and whether `\c` ended the output.
    static func decodeEchoEscapes(_ text: String) -> (String, Bool) {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "\\", index + 1 < characters.count {
                if characters[index + 1] == "c" { return (result, true) }
                if characters[index + 1] == "0" {
                    // echo uses \0NNN with up to three octal digits after the zero.
                    var end = index + 2
                    var digits = ""
                    while end < characters.count, digits.count < 3, characters[end] >= "0", characters[end] <= "7" {
                        digits.append(characters[end])
                        end += 1
                    }
                    if let value = UInt32(digits.isEmpty ? "0" : digits, radix: 8), let scalar = Unicode.Scalar(value) {
                        result.append(Character(scalar))
                    }
                    index = end
                    continue
                }
                let (decoded, consumed) = WordScanner.decodeANSIEscape(characters, index + 1)
                result += decoded
                index += 1 + consumed
                continue
            }
            result.append(c)
            index += 1
        }
        return (result, false)
    }

    // MARK: printf

    func builtinPrintf(_ args: [String], io: ShellIO) throws -> Int32 {
        var arguments = args
        var targetVariable: String?
        if arguments.first == "-v" {
            guard arguments.count >= 2 else {
                reportError("printf: -v: option requires an argument")
                return 2
            }
            targetVariable = arguments[1]
            arguments.removeFirst(2)
        }
        if arguments.first == "--" { arguments.removeFirst() }
        guard let format = arguments.first else {
            reportError("printf: usage: printf [-v var] format [arguments]")
            return 2
        }
        var values = Array(arguments.dropFirst())
        var output = ""
        var status: Int32 = 0

        while true {
            let (text, consumed, formatStatus, stopped) = formatOnce(format, &values)
            output += text
            if formatStatus != 0 { status = formatStatus }
            // The format is reused while arguments remain, unless it consumes none of them.
            if stopped || consumed == 0 || values.isEmpty { break }
        }

        if let targetVariable {
            guard Parser.isValidName(targetVariable) else {
                reportError("printf: `\(targetVariable)': not a valid identifier")
                return 2
            }
            try ctx.setValue(output, for: targetVariable)
        } else {
            try write(output, to: io.stdout)
        }
        return status
    }

    /// Formats the string once, consuming arguments. Returns (text, argumentsConsumed, status, stoppedByC).
    private func formatOnce(_ format: String, _ values: inout [String]) -> (String, Int, Int32, Bool) {
        let characters = Array(format)
        var result = ""
        var index = 0
        var consumed = 0
        var status: Int32 = 0

        func nextArgument() -> String? {
            guard !values.isEmpty else { return nil }
            consumed += 1
            return values.removeFirst()
        }

        while index < characters.count {
            let c = characters[index]
            if c == "\\" {
                if index + 1 < characters.count, characters[index + 1] == "c" {
                    return (result, consumed, status, true)
                }
                let (decoded, used) = WordScanner.decodeANSIEscape(characters, index + 1)
                result += decoded
                index += 1 + used
                continue
            }
            guard c == "%" else {
                result.append(c)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else {
                reportError("printf: missing format character")
                return (result, consumed, 1, false)
            }
            if characters[index] == "%" {
                result.append("%")
                index += 1
                continue
            }
            var flags = ""
            while index < characters.count, "-+ #0'".contains(characters[index]) {
                if characters[index] != "'" { flags.append(characters[index]) }
                index += 1
            }
            var width: Int?
            if index < characters.count, characters[index] == "*" {
                width = Int(nextArgument() ?? "0") ?? 0
                index += 1
            } else {
                var digits = ""
                while index < characters.count, characters[index].isNumber, characters[index].isASCII { digits.append(characters[index]); index += 1 }
                if !digits.isEmpty { width = Int(digits) }
            }
            var precision: Int?
            if index < characters.count, characters[index] == "." {
                index += 1
                if index < characters.count, characters[index] == "*" {
                    precision = Int(nextArgument() ?? "0") ?? 0
                    index += 1
                } else {
                    var digits = ""
                    while index < characters.count, characters[index].isNumber, characters[index].isASCII { digits.append(characters[index]); index += 1 }
                    precision = Int(digits) ?? 0
                }
            }
            // Length modifiers are accepted and ignored.
            while index < characters.count, "hlLqjzt".contains(characters[index]) { index += 1 }
            guard index < characters.count else {
                reportError("printf: missing format character")
                return (result, consumed, 1, false)
            }
            let conversion = characters[index]
            index += 1

            switch conversion {
            case "d", "i":
                let (value, ok) = Interpreter.printfInteger(nextArgument() ?? "")
                if !ok { status = 1 }
                result += Interpreter.formatInteger(value, flags: flags, width: width, precision: precision, conversion: "d")
            case "u":
                let (value, ok) = Interpreter.printfInteger(nextArgument() ?? "")
                if !ok { status = 1 }
                result += Interpreter.formatInteger(value, flags: flags, width: width, precision: precision, conversion: "u")
            case "o", "x", "X":
                let (value, ok) = Interpreter.printfInteger(nextArgument() ?? "")
                if !ok { status = 1 }
                result += Interpreter.formatInteger(value, flags: flags, width: width, precision: precision, conversion: conversion)
            case "e", "E", "f", "F", "g", "G", "a", "A":
                let argument = nextArgument() ?? ""
                let value = Interpreter.printfDouble(argument)
                if value == nil, !argument.isEmpty {
                    reportError("printf: \(argument): invalid number")
                    status = 1
                }
                result += Interpreter.formatDouble(value ?? 0, flags: flags, width: width, precision: precision, conversion: conversion)
            case "c":
                let argument = nextArgument() ?? ""
                result += Interpreter.pad(argument.isEmpty ? "" : String(argument.prefix(1)), flags: flags, width: width)
            case "s":
                var argument = nextArgument() ?? ""
                if let precision { argument = String(argument.prefix(precision)) }
                result += Interpreter.pad(argument, flags: flags, width: width)
            case "b":
                var argument = nextArgument() ?? ""
                let (decoded, stopped) = Interpreter.decodeEchoEscapes(argument)
                argument = decoded
                if let precision { argument = String(argument.prefix(precision)) }
                result += Interpreter.pad(argument, flags: flags, width: width)
                if stopped { return (result, consumed, status, true) }
            case "q":
                let argument = nextArgument() ?? ""
                result += Interpreter.pad(Interpreter.quoteForTrace(argument), flags: flags, width: width)
            default:
                reportError("printf: `\(conversion)': invalid format character")
                return (result, consumed, 1, false)
            }
        }
        return (result, consumed, status, false)
    }

    /// Parses an integer argument the way printf does: decimal, 0x hex, 0 octal, or 'c for a character code.
    static func printfInteger(_ text: String) -> (Int, Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (0, true) }
        if trimmed.hasPrefix("'") || trimmed.hasPrefix("\"") {
            if let scalar = trimmed.dropFirst().unicodeScalars.first { return (Int(scalar.value), true) }
            return (0, true)
        }
        if let value = Int(trimmed) { return (value, true) }
        var negative = false
        var body = Substring(trimmed)
        if body.hasPrefix("-") { negative = true; body = body.dropFirst() } else if body.hasPrefix("+") { body = body.dropFirst() }
        var value: Int?
        if body.hasPrefix("0x") || body.hasPrefix("0X") { value = Int(body.dropFirst(2), radix: 16) }
        else if body.hasPrefix("0"), body.count > 1 { value = Int(body.dropFirst(), radix: 8) }
        if let value { return (negative ? -value : value, true) }
        // Leading numeric prefix is used, like C's strtol; the rest is an error.
        var prefix = ""
        for c in trimmed where c.isNumber || (prefix.isEmpty && (c == "-" || c == "+")) { prefix.append(c) }
        return (Int(prefix) ?? 0, false)
    }

    static func printfDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if trimmed.hasPrefix("'") || trimmed.hasPrefix("\""), let scalar = trimmed.dropFirst().unicodeScalars.first {
            return Double(scalar.value)
        }
        return Double(trimmed)
    }

    static func formatInteger(_ value: Int, flags: String, width: Int?, precision: Int?, conversion: Character) -> String {
        var spec = "%" + flags
        if let width { spec += String(width) }
        if let precision { spec += "." + String(precision) }
        spec += "l" + String(conversion)
        switch conversion {
        case "u", "o", "x", "X":
            return String(format: spec, UInt(bitPattern: value))
        default:
            return String(format: spec, value)
        }
    }

    static func formatDouble(_ value: Double, flags: String, width: Int?, precision: Int?, conversion: Character) -> String {
        var spec = "%" + flags
        if let width { spec += String(width) }
        if let precision { spec += "." + String(precision) }
        spec += String(conversion)
        return String(format: spec, value)
    }

    static func pad(_ text: String, flags: String, width: Int?) -> String {
        guard let width, text.count < width else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return flags.contains("-") ? text + padding : padding + text
    }
}
