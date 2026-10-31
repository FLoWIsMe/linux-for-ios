import Foundation

/// A parsed piece of a raw word.
enum WordPart: Equatable {
    case text(String, quoted: Bool)
    case parameter(String, quoted: Bool)
    case commandSubstitution(String, quoted: Bool)
    case arithmetic(String, quoted: Bool)
    case tildePrefix(String)
}

/// Splits raw words into parts. Shared by expansion and by the arithmetic/heredoc paths.
enum WordScanner {
    static func scan(_ raw: String, allowTilde: Bool, assignmentTilde: Bool = false) -> [WordPart] {
        let characters = Array(raw)
        var parts: [WordPart] = []
        var index = 0
        var literal = ""

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.text(literal, quoted: false))
                literal = ""
            }
        }

        // Tilde prefix at the start of the word.
        if allowTilde, characters.first == "~" {
            var end = 1
            while end < characters.count, characters[end] != "/", characters[end] != ":" || !assignmentTilde {
                let c = characters[end]
                if c == "'" || c == "\"" || c == "\\" || c == "$" || c == "`" { break }
                end += 1
            }
            parts.append(.tildePrefix(String(characters[0..<end])))
            index = end
        }

        while index < characters.count {
            let c = characters[index]
            switch c {
            case "'":
                flushLiteral()
                var end = index + 1
                while end < characters.count, characters[end] != "'" { end += 1 }
                parts.append(.text(String(characters[(index + 1)..<min(end, characters.count)]), quoted: true))
                index = min(end + 1, characters.count)
            case "\"":
                flushLiteral()
                index += 1
                scanDoubleQuoted(characters, &index, into: &parts)
            case "\\":
                flushLiteral()
                if index + 1 < characters.count {
                    if characters[index + 1] != "\n" {
                        parts.append(.text(String(characters[index + 1]), quoted: true))
                    }
                    index += 2
                } else {
                    parts.append(.text("\\", quoted: true))
                    index += 1
                }
            case "$":
                flushLiteral()
                index = scanDollar(characters, index, quoted: false, into: &parts, literal: &literal)
            case "`":
                flushLiteral()
                index = scanBacktick(characters, index, quoted: false, into: &parts)
            default:
                if assignmentTilde, c == ":" || c == "=", index + 1 < characters.count, characters[index + 1] == "~" {
                    literal.append(c)
                    flushLiteral()
                    var end = index + 2
                    while end < characters.count, characters[end] != "/", characters[end] != ":" { end += 1 }
                    parts.append(.tildePrefix(String(characters[(index + 1)..<end])))
                    index = end
                } else {
                    literal.append(c)
                    index += 1
                }
            }
        }
        flushLiteral()
        return parts
    }

    /// Scans the inside of a `$"..."` or `"..."` string, starting after the opening quote.
    private static func scanDoubleQuoted(_ characters: [Character], _ index: inout Int, into parts: inout [WordPart]) {
        var literal = ""
        var sawAnything = false
        func flush() {
            if !literal.isEmpty || !sawAnything {
                parts.append(.text(literal, quoted: true))
                literal = ""
            }
            sawAnything = true
        }
        while index < characters.count {
            let c = characters[index]
            switch c {
            case "\"":
                flush()
                index += 1
                return
            case "\\":
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next == "$" || next == "`" || next == "\"" || next == "\\" {
                        literal.append(next)
                        index += 2
                    } else if next == "\n" {
                        index += 2
                    } else {
                        literal.append("\\")
                        index += 1
                    }
                } else {
                    literal.append("\\")
                    index += 1
                }
            case "$":
                if !literal.isEmpty { parts.append(.text(literal, quoted: true)); literal = "" }
                sawAnything = true
                var dummy = ""
                index = scanDollar(characters, index, quoted: true, into: &parts, literal: &dummy)
                if !dummy.isEmpty { literal.append(dummy) }
            case "`":
                if !literal.isEmpty { parts.append(.text(literal, quoted: true)); literal = "" }
                sawAnything = true
                index = scanBacktick(characters, index, quoted: true, into: &parts)
            default:
                literal.append(c)
                index += 1
            }
        }
        // Unterminated (cannot happen after the lexer validated the word, but stay safe).
        flush()
    }

    private static func isNameStart(_ c: Character) -> Bool { c.isLetter && c.isASCII || c == "_" }
    private static func isNameChar(_ c: Character) -> Bool { (c.isLetter || c.isNumber) && c.isASCII || c == "_" }
    static let specialParameters: Set<Character> = ["@", "*", "#", "?", "-", "$", "!", "_"]

    /// Scans a `$` construct at `index`. Returns the index after it. Plain `$` falls back to literal.
    static func scanDollar(_ characters: [Character], _ index: Int, quoted: Bool, into parts: inout [WordPart], literal: inout String) -> Int {
        let next = index + 1
        guard next < characters.count else {
            literal.append("$")
            if quoted { parts.append(.text("$", quoted: true)); literal = "" }
            return index + 1
        }
        let c = characters[next]
        if c == "'" && !quoted {
            // ANSI-C quoting
            var end = next + 1
            var result = ""
            while end < characters.count, characters[end] != "'" {
                if characters[end] == "\\", end + 1 < characters.count {
                    let (text, consumed) = decodeANSIEscape(characters, end + 1)
                    result += text
                    end += 1 + consumed
                } else {
                    result.append(characters[end])
                    end += 1
                }
            }
            parts.append(.text(result, quoted: true))
            return min(end + 1, characters.count)
        }
        if c == "\"" && !quoted {
            var end = next + 1
            scanDoubleQuoted(characters, &end, into: &parts)
            return end
        }
        if c == "{" {
            if let close = matchingBrace(characters, from: next) {
                parts.append(.parameter(String(characters[(next + 1)..<close]), quoted: quoted))
                return close + 1
            }
            literal.append("$")
            return index + 1
        }
        if c == "(" {
            if next + 1 < characters.count, characters[next + 1] == "(" {
                if let close = matchingDoubleParen(characters, from: next) {
                    parts.append(.arithmetic(String(characters[(next + 2)..<close]), quoted: quoted))
                    return close + 2
                }
            }
            if let close = matchingParen(characters, from: next) {
                parts.append(.commandSubstitution(String(characters[(next + 1)..<close]), quoted: quoted))
                return close + 1
            }
            literal.append("$")
            return index + 1
        }
        if isNameStart(c) {
            var end = next
            while end < characters.count, isNameChar(characters[end]) { end += 1 }
            parts.append(.parameter(String(characters[next..<end]), quoted: quoted))
            return end
        }
        if c.isNumber && c.isASCII {
            parts.append(.parameter(String(c), quoted: quoted))
            return next + 1
        }
        if specialParameters.contains(c) {
            parts.append(.parameter(String(c), quoted: quoted))
            return next + 1
        }
        if quoted {
            parts.append(.text("$", quoted: true))
        } else {
            literal.append("$")
        }
        return index + 1
    }

    static func scanBacktick(_ characters: [Character], _ index: Int, quoted: Bool, into parts: inout [WordPart]) -> Int {
        var end = index + 1
        var body = ""
        while end < characters.count, characters[end] != "`" {
            if characters[end] == "\\", end + 1 < characters.count {
                let next = characters[end + 1]
                if next == "$" || next == "`" || next == "\\" {
                    body.append(next)
                    end += 2
                    continue
                }
            }
            body.append(characters[end])
            end += 1
        }
        parts.append(.commandSubstitution(body, quoted: quoted))
        return min(end + 1, characters.count)
    }

    static func matchingBrace(_ characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var index = open
        var inSingle = false
        var inDouble = false
        while index < characters.count {
            let c = characters[index]
            if inSingle { if c == "'" { inSingle = false }; index += 1; continue }
            if inDouble {
                if c == "\\" { index += 2; continue }
                if c == "\"" { inDouble = false }
                index += 1
                continue
            }
            switch c {
            case "\\": index += 2; continue
            case "'": inSingle = true
            case "\"": inDouble = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    static func matchingParen(_ characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var index = open
        var inSingle = false
        var inDouble = false
        while index < characters.count {
            let c = characters[index]
            if inSingle { if c == "'" { inSingle = false }; index += 1; continue }
            if inDouble {
                if c == "\\" { index += 2; continue }
                if c == "\"" { inDouble = false }
                index += 1
                continue
            }
            switch c {
            case "\\": index += 2; continue
            case "'": inSingle = true
            case "\"": inDouble = true
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// For `$((`: returns the index of the first `)` of the closing `))`.
    static func matchingDoubleParen(_ characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < characters.count {
            let c = characters[index]
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 1, index + 1 < characters.count, characters[index + 1] == ")" {
                    return index
                }
                if depth == 0 { return nil }
            }
            index += 1
        }
        return nil
    }

    /// Decodes one backslash escape (the backslash itself already consumed) for `$'...'`, `echo -e` and `printf`.
    /// Returns the produced text and the number of characters consumed after the backslash.
    static func decodeANSIEscape(_ characters: [Character], _ index: Int) -> (String, Int) {
        guard index < characters.count else { return ("\\", 0) }
        let c = characters[index]
        switch c {
        case "n": return ("\n", 1)
        case "t": return ("\t", 1)
        case "r": return ("\r", 1)
        case "a": return ("\u{07}", 1)
        case "b": return ("\u{08}", 1)
        case "e", "E": return ("\u{1B}", 1)
        case "f": return ("\u{0C}", 1)
        case "v": return ("\u{0B}", 1)
        case "\\": return ("\\", 1)
        case "'": return ("'", 1)
        case "\"": return ("\"", 1)
        case "?": return ("?", 1)
        case "0", "1", "2", "3", "4", "5", "6", "7":
            var end = index
            var digits = ""
            while end < characters.count, digits.count < 3, characters[end] >= "0", characters[end] <= "7" {
                digits.append(characters[end])
                end += 1
            }
            if let value = UInt32(digits, radix: 8), let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), digits.count)
            }
            return ("", digits.count)
        case "x":
            var end = index + 1
            var digits = ""
            while end < characters.count, digits.count < 2, characters[end].isHexDigit {
                digits.append(characters[end])
                end += 1
            }
            if digits.isEmpty { return ("\\x", 1) }
            if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), 1 + digits.count)
            }
            return ("", 1 + digits.count)
        case "u", "U":
            let maxDigits = c == "u" ? 4 : 8
            var end = index + 1
            var digits = ""
            while end < characters.count, digits.count < maxDigits, characters[end].isHexDigit {
                digits.append(characters[end])
                end += 1
            }
            if digits.isEmpty { return ("\\" + String(c), 1) }
            if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), 1 + digits.count)
            }
            return ("", 1 + digits.count)
        case "c":
            if index + 1 < characters.count, let ascii = characters[index + 1].asciiValue {
                let control = UInt8(ascii) & 0x1F
                return (String(Character(Unicode.Scalar(control))), 2)
            }
            return ("", 1)
        default:
            return ("\\" + String(c), 1)
        }
    }
}

// MARK: - Expansion

extension Interpreter {
    /// Full expansion of command words: brace, tilde, parameter, command substitution, arithmetic,
    /// field splitting, pathname expansion, quote removal.
    func expandWords(_ words: [Word]) throws -> [String] {
        var result: [String] = []
        for word in words {
            result.append(contentsOf: try expandWord(word))
        }
        return result
    }

    func expandWord(_ word: Word) throws -> [String] {
        var result: [String] = []
        for raw in BraceExpansion.expand(word.raw) {
            let parts = WordScanner.scan(raw, allowTilde: true)
            let fields = try expandParts(parts, splitFields: true)
            for field in fields {
                if !ctx.options.noglob, let matches = PathGlobber.expand(fragments: field, workingDirectory: ctx.workingDirectory) {
                    result.append(contentsOf: matches)
                } else {
                    result.append(field.map(\.text).joined())
                }
            }
        }
        return result
    }

    /// Expansion without brace expansion, field splitting or globbing: redirection targets, `case`
    /// subjects, herestrings, `[[ ]]` operands.
    func expandSingle(_ word: Word) throws -> String {
        let parts = WordScanner.scan(word.raw, allowTilde: true)
        let fields = try expandParts(parts, splitFields: false)
        return fields.flatMap { $0 }.map(\.text).joined()
    }

    /// Right hand side of `name=value`: tilde expansion also applies after `:` and `=`.
    func expandAssignmentValue(_ word: Word) throws -> String {
        let parts = WordScanner.scan(word.raw, allowTilde: true, assignmentTilde: true)
        let fields = try expandParts(parts, splitFields: false)
        return fields.flatMap { $0 }.map(\.text).joined()
    }

    /// Expands a word into a pattern, keeping quoted characters literal.
    func expandPattern(_ word: Word) throws -> GlobPattern {
        let parts = WordScanner.scan(word.raw, allowTilde: true)
        let fields = try expandParts(parts, splitFields: false)
        return GlobPattern(fragments: fields.flatMap { $0 })
    }

    /// Expands a heredoc body or a double quoted style string: parameters, command substitutions and
    /// arithmetic are expanded; nothing is split or globbed; `\$`, `` \` `` and `\\` are unescaped.
    func expandDoubleQuotedText(_ text: String) throws -> String {
        var parts: [WordPart] = []
        let characters = Array(text)
        var index = 0
        var literal = ""
        func flush() {
            if !literal.isEmpty {
                parts.append(.text(literal, quoted: true))
                literal = ""
            }
        }
        while index < characters.count {
            let c = characters[index]
            if c == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "$" || next == "`" || next == "\\" {
                    literal.append(next)
                    index += 2
                    continue
                }
                if next == "\n" {
                    index += 2
                    continue
                }
                literal.append(c)
                index += 1
                continue
            }
            if c == "$" {
                flush()
                var unused = ""
                index = WordScanner.scanDollar(characters, index, quoted: true, into: &parts, literal: &unused)
                literal += unused
                continue
            }
            if c == "`" {
                flush()
                index = WordScanner.scanBacktick(characters, index, quoted: true, into: &parts)
                continue
            }
            literal.append(c)
            index += 1
        }
        flush()
        let fields = try expandParts(parts, splitFields: false)
        return fields.flatMap { $0 }.map(\.text).joined()
    }

    // MARK: Core

    /// Expands parts into fields. With `splitFields` false everything lands in one field.
    func expandParts(_ parts: [WordPart], splitFields: Bool) throws -> [[Fragment]] {
        var fields: [[Fragment]] = [[]]
        func append(_ fragment: Fragment) { fields[fields.count - 1].append(fragment) }
        func newField() { fields.append([]) }

        for part in parts {
            switch part {
            case .text(let text, let quoted):
                append(Fragment(text: text, kind: quoted ? .quoted : .literal))
            case .tildePrefix(let prefix):
                if let expanded = expandTilde(prefix) {
                    append(Fragment(text: expanded, kind: .quoted))
                } else {
                    append(Fragment(text: prefix, kind: .literal))
                }
            case .parameter(let expression, let quoted):
                let value = try expandParameter(expression, quoted: quoted)
                switch value {
                case .single(let text):
                    if quoted {
                        append(Fragment(text: text, kind: .quoted))
                    } else {
                        appendExpanded(text, splitFields: splitFields, fields: &fields)
                    }
                case .multiple(let values):
                    // "$@" and unquoted $@ / $*: each value is its own field.
                    for (index, value) in values.enumerated() {
                        if index > 0 { newField() }
                        if quoted {
                            append(Fragment(text: value, kind: .quoted))
                        } else {
                            appendExpanded(value, splitFields: splitFields, fields: &fields)
                        }
                    }
                }
            case .commandSubstitution(let source, let quoted):
                let output = try captureOutput(of: source)
                if quoted {
                    append(Fragment(text: output, kind: .quoted))
                } else {
                    appendExpanded(output, splitFields: splitFields, fields: &fields)
                }
            case .arithmetic(let expression, let quoted):
                let value = try evaluateArithmetic(expression)
                append(Fragment(text: String(value), kind: quoted ? .quoted : .expanded))
            }
        }
        // Drop fields that never received a fragment (unquoted empty expansions, "$@" with no params).
        return fields.filter { !$0.isEmpty }
    }

    /// Appends text produced by an unquoted expansion, splitting it on IFS when requested.
    private func appendExpanded(_ text: String, splitFields: Bool, fields: inout [[Fragment]]) {
        guard splitFields else {
            if !text.isEmpty { fields[fields.count - 1].append(Fragment(text: text, kind: .expanded)) }
            return
        }
        let ifs = ctx.value("IFS") ?? " \t\n"
        if ifs.isEmpty {
            if !text.isEmpty { fields[fields.count - 1].append(Fragment(text: text, kind: .expanded)) }
            return
        }
        guard !text.isEmpty else { return }
        let split = splitOnIFS(text, ifs: ifs)
        if split.leadingSeparator, !fields[fields.count - 1].isEmpty {
            fields.append([])
        }
        for (index, piece) in split.pieces.enumerated() {
            if index > 0 { fields.append([]) }
            fields[fields.count - 1].append(Fragment(text: piece, kind: .expanded))
        }
        if split.trailingSeparator {
            fields.append([])
        }
    }

    struct IFSSplit {
        var pieces: [String]
        var leadingSeparator: Bool
        var trailingSeparator: Bool
    }

    func splitOnIFS(_ text: String, ifs: String) -> IFSSplit {
        let whitespace = Set(ifs.filter { $0 == " " || $0 == "\t" || $0 == "\n" })
        let nonWhitespace = Set(ifs.filter { !($0 == " " || $0 == "\t" || $0 == "\n") })
        let characters = Array(text)
        var pieces: [String] = []
        var current = ""
        var index = 0
        var leading = false
        var trailing = false
        while index < characters.count, whitespace.contains(characters[index]) {
            index += 1
            leading = true
        }
        if index == characters.count {
            return IFSSplit(pieces: [], leadingSeparator: leading, trailingSeparator: true)
        }
        while index < characters.count {
            let c = characters[index]
            if whitespace.contains(c) {
                var end = index
                while end < characters.count, whitespace.contains(characters[end]) { end += 1 }
                if end == characters.count {
                    trailing = true
                    index = end
                    break
                }
                if nonWhitespace.contains(characters[end]) {
                    pieces.append(current)
                    current = ""
                    index = end + 1
                    while index < characters.count, whitespace.contains(characters[index]) { index += 1 }
                    if index == characters.count { trailing = true }
                    continue
                }
                pieces.append(current)
                current = ""
                index = end
                continue
            }
            if nonWhitespace.contains(c) {
                pieces.append(current)
                current = ""
                index += 1
                while index < characters.count, whitespace.contains(characters[index]) { index += 1 }
                if index == characters.count { trailing = true }
                continue
            }
            current.append(c)
            index += 1
        }
        if !trailing || !current.isEmpty {
            pieces.append(current)
        }
        return IFSSplit(pieces: pieces, leadingSeparator: leading, trailingSeparator: trailing)
    }

    func expandTilde(_ prefix: String) -> String? {
        switch prefix {
        case "~": return ctx.value("HOME") ?? shell.homeDirectory
        case "~+": return ctx.workingDirectory
        case "~-": return ctx.previousDirectory ?? ctx.value("OLDPWD")
        default: return nil
        }
    }

    // MARK: Parameters

    enum ParameterValue {
        case single(String)
        case multiple([String])
    }

    private static let specialNames: Set<String> = ["@", "*", "#", "?", "-", "$", "!", "0", "_"]

    private func isPositionalOrSpecial(_ name: String) -> Bool {
        Interpreter.specialNames.contains(name) || (!name.isEmpty && name.allSatisfy { $0.isNumber && $0.isASCII })
    }

    /// Raw value of a parameter (nil when unset). `@` and `*` are handled by the caller.
    func parameterValue(_ name: String) -> String? {
        switch name {
        case "#": return String(ctx.positional.count)
        case "?": return String(ctx.lastStatus)
        case "-": return ctx.optionFlags
        case "$": return String(ctx.shellPID)
        case "!": return ctx.lastBackgroundJob == 0 ? nil : String(ctx.lastBackgroundJob)
        case "0": return ctx.scriptName
        case "_": return ctx.lastArgument
        case "*": return ctx.positional.joined(separator: String(ctx.value("IFS")?.first ?? " "))
        case "@": return ctx.positional.joined(separator: " ")
        default:
            if let number = Int(name), name.allSatisfy({ $0.isNumber && $0.isASCII }) {
                if number == 0 { return ctx.scriptName }
                return number <= ctx.positional.count ? ctx.positional[number - 1] : nil
            }
            return ctx.value(name)
        }
    }

    private func positionalValues(for name: String, quoted: Bool) -> ParameterValue {
        if name == "*" && quoted {
            let separator = ctx.value("IFS").map { $0.isEmpty ? "" : String($0.first!) } ?? " "
            return .single(ctx.positional.joined(separator: separator))
        }
        return .multiple(ctx.positional)
    }

    func expandParameter(_ expression: String, quoted: Bool) throws -> ParameterValue {
        let characters = Array(expression)
        guard !characters.isEmpty else { throw ShellRuntimeError.badSubstitution("${}") }

        // ${#name} and ${#@}
        if characters[0] == "#", characters.count > 1 {
            let name = String(characters[1...])
            if name == "@" || name == "*" { return .single(String(ctx.positional.count)) }
            if isValidParameterName(name) {
                try checkUnset(name)
                return .single(String((parameterValue(name) ?? "").count))
            }
        }
        // ${!name} indirection, ${!prefix*}
        if characters[0] == "!", characters.count > 1 {
            let rest = String(characters[1...])
            if rest.hasSuffix("*") || rest.hasSuffix("@") {
                let prefix = String(rest.dropLast())
                let names = ctx.visibleVariableNames.filter { $0.hasPrefix(prefix) }
                return quoted && rest.hasSuffix("*") ? .single(names.joined(separator: " ")) : .multiple(names)
            }
            if isValidParameterName(rest) {
                let target = parameterValue(rest) ?? ""
                if target == "@" || target == "*" { return positionalValues(for: target, quoted: quoted) }
                return .single(parameterValue(target) ?? "")
            }
        }

        // Split name from operator.
        var nameEnd = 0
        if WordScanner.specialParameters.contains(characters[0]) {
            nameEnd = 1
        } else {
            while nameEnd < characters.count, (characters[nameEnd].isLetter || characters[nameEnd].isNumber) && characters[nameEnd].isASCII || characters[nameEnd] == "_" {
                nameEnd += 1
            }
        }
        guard nameEnd > 0 else { throw ShellRuntimeError.badSubstitution("${\(expression)}") }
        let name = String(characters[0..<nameEnd])
        guard isValidParameterName(name) else { throw ShellRuntimeError.badSubstitution("${\(expression)}") }

        if nameEnd == characters.count {
            if name == "@" || name == "*" {
                return positionalValues(for: name, quoted: quoted)
            }
            try checkUnset(name)
            return .single(parameterValue(name) ?? "")
        }

        let operatorText = String(characters[nameEnd...])
        let operators = [":-", ":=", ":?", ":+", "##", "%%", "//", "/#", "/%", "^^", ",,", "-", "=", "?", "+", "#", "%", "/", ":", "^", ","]
        guard let op = operators.first(where: { operatorText.hasPrefix($0) }) else {
            throw ShellRuntimeError.badSubstitution("${\(expression)}")
        }
        let argument = String(operatorText.dropFirst(op.count))
        let isPositional = name == "@" || name == "*"

        switch op {
        case ":-", "-", ":=", "=", ":?", "?", ":+", "+":
            let colon = op.hasPrefix(":")
            let currentValue: String?
            if isPositional {
                currentValue = ctx.positional.isEmpty ? nil : ctx.positional.joined(separator: " ")
            } else {
                currentValue = parameterValue(name)
            }
            let isNullOrUnset = currentValue == nil || (colon && currentValue!.isEmpty)
            switch op {
            case ":-", "-":
                if isNullOrUnset { return .single(try expandWordInContext(argument, quoted: quoted)) }
                return isPositional ? positionalValues(for: name, quoted: quoted) : .single(currentValue ?? "")
            case ":=", "=":
                if isNullOrUnset {
                    let value = try expandWordInContext(argument, quoted: quoted)
                    if isPositional || isPositionalOrSpecial(name) {
                        throw ShellRuntimeError.badSubstitution("${\(expression)}: cannot assign in this way")
                    }
                    try ctx.setValue(value, for: name)
                    return .single(value)
                }
                return .single(currentValue ?? "")
            case ":?", "?":
                if isNullOrUnset {
                    let message = argument.isEmpty ? "" : try expandWordInContext(argument, quoted: quoted)
                    throw ShellRuntimeError.parameterNull(name, message)
                }
                return isPositional ? positionalValues(for: name, quoted: quoted) : .single(currentValue ?? "")
            default: // :+ and +
                if isNullOrUnset { return .single("") }
                return .single(try expandWordInContext(argument, quoted: quoted))
            }
        case "#", "##", "%", "%%":
            if isPositional {
                return .multiple(try ctx.positional.map { try removePattern(from: $0, argument: argument, op: op) })
            }
            try checkUnset(name)
            return .single(try removePattern(from: parameterValue(name) ?? "", argument: argument, op: op))
        case "/", "//", "/#", "/%":
            let (patternText, replacement) = splitReplacement(argument)
            if isPositional {
                return .multiple(try ctx.positional.map { try replacePattern(in: $0, patternText: patternText, replacementText: replacement, op: op) })
            }
            try checkUnset(name)
            return .single(try replacePattern(in: parameterValue(name) ?? "", patternText: patternText, replacementText: replacement, op: op))
        case ":":
            // substring: ${name:offset[:length]}
            let pieces = splitTopLevelColon(argument)
            let offset = try evaluateArithmetic(pieces.first ?? "0")
            let length = pieces.count > 1 ? try evaluateArithmetic(pieces[1]) : nil
            if isPositional {
                var all = [ctx.scriptName] + ctx.positional
                let start = offset < 0 ? max(0, all.count + offset) : min(offset, all.count)
                all = Array(all[start...])
                if let length {
                    if length < 0 { throw ShellRuntimeError.badSubstitution("${\(expression)}: substring expression < 0") }
                    all = Array(all.prefix(length))
                }
                return .multiple(all)
            }
            try checkUnset(name)
            let value = Array(parameterValue(name) ?? "")
            let start = offset < 0 ? max(0, value.count + offset) : min(offset, value.count)
            var end = value.count
            if let length {
                if length < 0 {
                    end = max(start, value.count + length)
                } else {
                    end = min(value.count, start + length)
                }
            }
            return .single(String(value[start..<end]))
        case "^", "^^", ",", ",,":
            try checkUnset(name)
            let value = parameterValue(name) ?? ""
            let pattern = argument.isEmpty ? nil : try expandPattern(Word(argument))
            func convert(_ c: Character) -> String {
                if let pattern, !pattern.matches(String(c)) { return String(c) }
                return op.hasPrefix("^") ? c.uppercased() : c.lowercased()
            }
            if op == "^^" || op == ",," {
                return .single(value.map(convert).joined())
            }
            guard let first = value.first else { return .single("") }
            return .single(convert(first) + String(value.dropFirst()))
        default:
            throw ShellRuntimeError.badSubstitution("${\(expression)}")
        }
    }

    private func isValidParameterName(_ name: String) -> Bool {
        if Interpreter.specialNames.contains(name) { return true }
        if name.allSatisfy({ $0.isNumber && $0.isASCII }), !name.isEmpty { return true }
        return Parser.isValidName(name)
    }

    private func checkUnset(_ name: String) throws {
        if ctx.options.nounset, !isPositionalOrSpecial(name) || name.allSatisfy({ $0.isNumber }) {
            if parameterValue(name) == nil {
                throw ShellRuntimeError.unboundVariable(name)
            }
        }
    }

    /// Expands the word part of `${name:-word}`; inside double quotes the result is not split.
    private func expandWordInContext(_ argument: String, quoted: Bool) throws -> String {
        let parts = WordScanner.scan(argument, allowTilde: true)
        let fields = try expandParts(parts, splitFields: false)
        return fields.flatMap { $0 }.map(\.text).joined()
    }

    private func removePattern(from value: String, argument: String, op: String) throws -> String {
        let pattern = try expandPattern(Word(argument))
        let characters = Array(value)
        switch op {
        case "#", "##":
            guard let length = pattern.prefixMatchLength(in: value, longest: op == "##") else { return value }
            return String(characters[length...])
        default:
            guard let length = pattern.suffixMatchLength(in: value, longest: op == "%%") else { return value }
            return String(characters[0..<(characters.count - length)])
        }
    }

    private func splitReplacement(_ argument: String) -> (String, String) {
        // Split on the first unquoted, unescaped `/`.
        let characters = Array(argument)
        var index = 0
        var inSingle = false
        var inDouble = false
        var depth = 0
        while index < characters.count {
            let c = characters[index]
            if inSingle { if c == "'" { inSingle = false }; index += 1; continue }
            if inDouble {
                if c == "\\" { index += 2; continue }
                if c == "\"" { inDouble = false }
                index += 1
                continue
            }
            switch c {
            case "\\": index += 2; continue
            case "'": inSingle = true
            case "\"": inDouble = true
            case "[": depth += 1
            case "]": depth = max(0, depth - 1)
            case "/":
                if depth == 0 {
                    return (String(characters[0..<index]), String(characters[(index + 1)...]))
                }
            default: break
            }
            index += 1
        }
        return (argument, "")
    }

    private func replacePattern(in value: String, patternText: String, replacementText: String, op: String) throws -> String {
        let pattern = try expandPattern(Word(patternText))
        let replacement = try expandSingle(Word(replacementText))
        let characters = Array(value)
        switch op {
        case "/#":
            guard let length = pattern.prefixMatchLength(in: value, longest: true) else { return value }
            return replacement + String(characters[length...])
        case "/%":
            guard let length = pattern.suffixMatchLength(in: value, longest: true) else { return value }
            return String(characters[0..<(characters.count - length)]) + replacement
        case "//":
            var result = ""
            var remaining = value
            var guardCounter = 0
            while !remaining.isEmpty, guardCounter < 100_000 {
                guardCounter += 1
                guard let range = pattern.firstMatchRange(in: remaining) else { break }
                let chars = Array(remaining)
                if range.isEmpty {
                    // Empty match: advance one character to avoid looping forever.
                    result.append(chars[0])
                    remaining = String(chars[1...])
                    continue
                }
                result += String(chars[0..<range.lowerBound]) + replacement
                remaining = String(chars[range.upperBound...])
            }
            return result + remaining
        default:
            guard let range = pattern.firstMatchRange(in: value), !range.isEmpty else { return value }
            return String(characters[0..<range.lowerBound]) + replacement + String(characters[range.upperBound...])
        }
    }

    private func splitTopLevelColon(_ text: String) -> [String] {
        var pieces: [String] = [""]
        var depth = 0
        for c in text {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if c == ":" && depth == 0 {
                pieces.append("")
            } else {
                pieces[pieces.count - 1].append(c)
            }
        }
        return pieces
    }

    // MARK: Arithmetic

    func evaluateArithmetic(_ expression: String) throws -> Int {
        // Expand parameters and command substitutions inside the expression first.
        let expanded = try expandDoubleQuotedText(expression)
        let evaluator = ArithmeticEvaluator(
            lookup: { [weak self] name in self?.parameterValue(name) },
            assign: { [weak self] name, value in try self?.ctx.setValue(value, for: name) }
        )
        return try evaluator.evaluate(expanded)
    }
}
