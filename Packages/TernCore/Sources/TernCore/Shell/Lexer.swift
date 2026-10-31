import Foundation

enum Operator: String, Equatable {
    case pipe = "|"
    case pipeBoth = "|&"
    case and = "&&"
    case or = "||"
    case ampersand = "&"
    case semicolon = ";"
    case doubleSemicolon = ";;"
    case semicolonAmpersand = ";&"
    case doubleSemicolonAmpersand = ";;&"
    case leftParen = "("
    case rightParen = ")"
    case less = "<"
    case great = ">"
    case doubleGreat = ">>"
    case clobber = ">|"
    case lessGreat = "<>"
    case lessAnd = "<&"
    case greatAnd = ">&"
    case doubleLess = "<<"
    case doubleLessDash = "<<-"
    case tripleLess = "<<<"
    case ampersandGreat = "&>"
    case ampersandDoubleGreat = "&>>"

    var isRedirection: Bool {
        switch self {
        case .less, .great, .doubleGreat, .clobber, .lessGreat, .lessAnd, .greatAnd,
             .doubleLess, .doubleLessDash, .tripleLess, .ampersandGreat, .ampersandDoubleGreat:
            return true
        default:
            return false
        }
    }
}

enum TokenKind: Equatable {
    case word(String)
    /// Digits immediately followed by `<` or `>`.
    case ioNumber(Int32)
    case op(Operator)
    case newline
    case eof
}

struct Token: Equatable {
    var kind: TokenKind
    var line: Int
    /// Byte offset of the token's first character in the lexer source.
    var start: Int

    var wordText: String? {
        if case .word(let text) = kind { return text }
        return nil
    }

    func isOperator(_ op: Operator) -> Bool {
        if case .op(let value) = kind { return value == op }
        return false
    }

    var isWordLike: Bool {
        switch kind {
        case .word, .ioNumber: return true
        default: return false
        }
    }
}

/// Errors raised while scanning. `incomplete` means more input could fix the problem.
enum LexError: Error, Equatable {
    case incomplete(hint: String, line: Int)
    case invalid(message: String, line: Int)
}

/// Splits shell source into tokens. The lexer is lazy and byte based: multi byte UTF-8 sequences are
/// never special, so they pass through untouched inside words.
final class Lexer {
    private(set) var source: [UInt8]
    private(set) var pos: Int = 0
    private(set) var line: Int = 1
    private var lookahead: Token?

    init(_ text: String) {
        source = Array(text.utf8)
    }

    // MARK: Public interface used by the parser

    func peek() throws -> Token {
        if let token = lookahead { return token }
        let token = try scan()
        lookahead = token
        return token
    }

    @discardableResult
    func next() throws -> Token {
        if let token = lookahead {
            lookahead = nil
            return token
        }
        return try scan()
    }

    /// Inserts text at the current scanning position (alias expansion). Drops any lookahead.
    func insert(_ text: String) {
        if let token = lookahead {
            pos = token.start
            lookahead = nil
        }
        source.insert(contentsOf: Array(text.utf8), at: pos)
    }

    /// Does the source at `offset` start with `prefix`?
    func sourceHasPrefix(_ prefix: String, at offset: Int) -> Bool {
        let bytes = Array(prefix.utf8)
        guard offset + bytes.count <= source.count else { return false }
        return Array(source[offset..<(offset + bytes.count)]) == bytes
    }

    /// Reads a `(( expression ))` starting at `offset` (which must point at the first paren) and
    /// returns the text between the double parentheses. Positions the lexer after the closing `))`.
    func readArithmeticCommand(from offset: Int) throws -> String {
        lookahead = nil
        pos = offset + 2
        var depth = 1
        var text: [UInt8] = []
        while pos < source.count {
            let c = source[pos]
            if c == UInt8(ascii: "(") {
                depth += 1
            } else if c == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    // Need a second closing paren to terminate.
                    if pos + 1 < source.count, source[pos + 1] == UInt8(ascii: ")") {
                        pos += 2
                        return String(decoding: text, as: UTF8.self)
                    }
                    throw LexError.invalid(message: "syntax error: missing `))'", line: line)
                }
            } else if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") {
                let quoteStart = pos
                try skipQuoted(quote: c)
                text.append(contentsOf: source[quoteStart..<pos])
                continue
            } else if c == UInt8(ascii: "\n") {
                line += 1
            }
            text.append(c)
            pos += 1
        }
        throw LexError.incomplete(hint: "((", line: line)
    }

    /// Reads heredoc bodies in order right after a newline token was consumed.
    func readHeredocBody(delimiter: String, stripTabs: Bool) throws -> String {
        lookahead = nil
        var body: [UInt8] = []
        let delimiterBytes = Array(delimiter.utf8)
        while true {
            if pos >= source.count {
                throw LexError.incomplete(hint: "heredoc", line: line)
            }
            var lineStart = pos
            while lineStart < source.count && stripTabs && source[lineStart] == UInt8(ascii: "\t") {
                lineStart += 1
            }
            var lineEnd = lineStart
            while lineEnd < source.count && source[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
            let content = Array(source[lineStart..<lineEnd])
            let hasNewline = lineEnd < source.count
            if content == delimiterBytes {
                pos = hasNewline ? lineEnd + 1 : lineEnd
                if hasNewline { line += 1 }
                return String(decoding: body, as: UTF8.self)
            }
            if !hasNewline {
                // Last line without a newline cannot be the terminator yet.
                pos = source.count
                throw LexError.incomplete(hint: "heredoc", line: line)
            }
            body.append(contentsOf: content)
            body.append(UInt8(ascii: "\n"))
            pos = lineEnd + 1
            line += 1
        }
    }

    /// Everything from the current position to the end of the current line (used for diagnostics).
    func restOfLine(from offset: Int) -> String {
        var end = offset
        while end < source.count && source[end] != UInt8(ascii: "\n") { end += 1 }
        return String(decoding: source[min(offset, end)..<end], as: UTF8.self)
    }

    // MARK: Scanning

    private func scan() throws -> Token {
        skipBlanksAndComments()
        let start = pos
        guard pos < source.count else { return Token(kind: .eof, line: line, start: start) }
        let c = source[pos]

        if c == UInt8(ascii: "\n") {
            pos += 1
            let token = Token(kind: .newline, line: line, start: start)
            line += 1
            return token
        }

        if let op = scanOperator() {
            return Token(kind: .op(op), line: line, start: start)
        }

        // io number: digits directly followed by < or >
        if isDigit(c) {
            var end = pos
            while end < source.count && isDigit(source[end]) { end += 1 }
            if end < source.count, source[end] == UInt8(ascii: "<") || source[end] == UInt8(ascii: ">") {
                let digits = String(decoding: source[pos..<end], as: UTF8.self)
                if let value = Int32(digits) {
                    pos = end
                    return Token(kind: .ioNumber(value), line: line, start: start)
                }
            }
        }

        let startLine = line
        let word = try scanWord()
        return Token(kind: .word(word), line: startLine, start: start)
    }

    private func skipBlanksAndComments() {
        while pos < source.count {
            let c = source[pos]
            if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\r") {
                pos += 1
            } else if c == UInt8(ascii: "\\"), pos + 1 < source.count, source[pos + 1] == UInt8(ascii: "\n") {
                // line continuation
                pos += 2
                line += 1
            } else if c == UInt8(ascii: "#") {
                while pos < source.count && source[pos] != UInt8(ascii: "\n") { pos += 1 }
            } else {
                return
            }
        }
    }

    private func scanOperator() -> Operator? {
        func has(_ s: String) -> Bool { sourceHasPrefix(s, at: pos) }
        // Longest match first.
        let candidates: [Operator] = [
            .doubleSemicolonAmpersand, .doubleLessDash, .tripleLess, .ampersandDoubleGreat,
            .doubleSemicolon, .semicolonAmpersand, .pipeBoth, .and, .or, .doubleGreat, .clobber,
            .lessGreat, .lessAnd, .greatAnd, .doubleLess, .ampersandGreat,
            .pipe, .ampersand, .semicolon, .leftParen, .rightParen, .less, .great,
        ]
        for op in candidates where has(op.rawValue) {
            pos += op.rawValue.utf8.count
            return op
        }
        return nil
    }

    private func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    private func isMetacharacter(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
             UInt8(ascii: "|"), UInt8(ascii: "&"), UInt8(ascii: ";"), UInt8(ascii: "("),
             UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"):
            return true
        default:
            return false
        }
    }

    /// Scans one word, keeping quotes and escapes verbatim so that expansion can interpret them.
    private func scanWord() throws -> String {
        let start = pos
        while pos < source.count {
            let c = source[pos]
            if isMetacharacter(c) { break }
            switch c {
            case UInt8(ascii: "\\"):
                if pos + 1 < source.count {
                    if source[pos + 1] == UInt8(ascii: "\n") {
                        // Line continuation inside a word: drop both characters.
                        source.removeSubrange(pos..<(pos + 2))
                        line += 1
                        continue
                    }
                    pos += 2
                } else {
                    // Trailing backslash at end of input: needs another line.
                    throw LexError.incomplete(hint: "backslash", line: line)
                }
            case UInt8(ascii: "'"), UInt8(ascii: "\""):
                try skipQuoted(quote: c)
            case UInt8(ascii: "`"):
                try skipBacktick()
            case UInt8(ascii: "$"):
                try skipDollar()
            default:
                pos += 1
            }
        }
        return String(decoding: source[start..<pos], as: UTF8.self)
    }

    /// Skips a quoted string starting at `pos` (which points at the opening quote).
    private func skipQuoted(quote: UInt8) throws {
        let startLine = line
        pos += 1
        if quote == UInt8(ascii: "'") {
            while pos < source.count {
                if source[pos] == UInt8(ascii: "'") { pos += 1; return }
                if source[pos] == UInt8(ascii: "\n") { line += 1 }
                pos += 1
            }
            throw LexError.incomplete(hint: "quote", line: startLine)
        }
        // double quotes
        while pos < source.count {
            let c = source[pos]
            switch c {
            case UInt8(ascii: "\""):
                pos += 1
                return
            case UInt8(ascii: "\\"):
                if pos + 1 < source.count {
                    if source[pos + 1] == UInt8(ascii: "\n") { line += 1 }
                    pos += 2
                } else {
                    pos += 1
                }
            case UInt8(ascii: "`"):
                try skipBacktick()
            case UInt8(ascii: "$"):
                try skipDollar()
            case UInt8(ascii: "\n"):
                line += 1
                pos += 1
            default:
                pos += 1
            }
        }
        throw LexError.incomplete(hint: "dquote", line: startLine)
    }

    private func skipBacktick() throws {
        let startLine = line
        pos += 1
        while pos < source.count {
            let c = source[pos]
            if c == UInt8(ascii: "`") { pos += 1; return }
            if c == UInt8(ascii: "\\") { pos += min(2, source.count - pos); continue }
            if c == UInt8(ascii: "\n") { line += 1 }
            pos += 1
        }
        throw LexError.incomplete(hint: "backtick", line: startLine)
    }

    /// Skips `$`, `$name`, `${...}`, `$(...)`, `$((...))`, `$'...'`, `$"..."`.
    private func skipDollar() throws {
        let startLine = line
        pos += 1
        guard pos < source.count else { return }
        let c = source[pos]
        if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") {
            try skipQuoted(quote: c)
            return
        }
        if c == UInt8(ascii: "{") {
            pos += 1
            var depth = 1
            while pos < source.count {
                let d = source[pos]
                switch d {
                case UInt8(ascii: "{"): depth += 1; pos += 1
                case UInt8(ascii: "}"):
                    depth -= 1
                    pos += 1
                    if depth == 0 { return }
                case UInt8(ascii: "'"), UInt8(ascii: "\""): try skipQuoted(quote: d)
                case UInt8(ascii: "\\"): pos += min(2, source.count - pos)
                case UInt8(ascii: "$"): try skipDollar()
                case UInt8(ascii: "`"): try skipBacktick()
                case UInt8(ascii: "\n"): line += 1; pos += 1
                default: pos += 1
                }
            }
            throw LexError.incomplete(hint: "${", line: startLine)
        }
        if c == UInt8(ascii: "(") {
            if pos + 1 < source.count, source[pos + 1] == UInt8(ascii: "(") {
                // $(( ... )) : scan to the matching ))
                pos += 2
                var depth = 1
                while pos < source.count {
                    let d = source[pos]
                    if d == UInt8(ascii: "(") { depth += 1 }
                    if d == UInt8(ascii: ")") {
                        depth -= 1
                        if depth == 0 {
                            if pos + 1 < source.count, source[pos + 1] == UInt8(ascii: ")") {
                                pos += 2
                                return
                            }
                            // `$(( ... )` with a single paren: treat as command substitution of a subshell.
                            pos += 1
                            return
                        }
                    }
                    if d == UInt8(ascii: "'") || d == UInt8(ascii: "\"") { try skipQuoted(quote: d); continue }
                    if d == UInt8(ascii: "\n") { line += 1 }
                    pos += 1
                }
                throw LexError.incomplete(hint: "$((", line: startLine)
            }
            // $( ... ) : nested shell syntax, scan with full quote awareness
            pos += 1
            try skipCommandSubstitutionBody()
            return
        }
        // $name, $?, $$ etc: plain characters, handled by the word scanner
    }

    /// Position is right after `$(`. Consumes through the matching `)`.
    private func skipCommandSubstitutionBody() throws {
        let startLine = line
        var depth = 1
        while pos < source.count {
            let c = source[pos]
            switch c {
            case UInt8(ascii: "("): depth += 1; pos += 1
            case UInt8(ascii: ")"):
                depth -= 1
                pos += 1
                if depth == 0 { return }
            case UInt8(ascii: "'"), UInt8(ascii: "\""): try skipQuoted(quote: c)
            case UInt8(ascii: "\\"):
                pos += min(2, source.count - pos)
            case UInt8(ascii: "`"): try skipBacktick()
            case UInt8(ascii: "$"): try skipDollar()
            case UInt8(ascii: "#"):
                // comment inside command substitution: only when at a word start
                let previous = pos > 0 ? source[pos - 1] : UInt8(ascii: " ")
                if previous == UInt8(ascii: " ") || previous == UInt8(ascii: "\t") || previous == UInt8(ascii: "\n") || previous == UInt8(ascii: "(") || previous == UInt8(ascii: ";") {
                    while pos < source.count && source[pos] != UInt8(ascii: "\n") { pos += 1 }
                } else {
                    pos += 1
                }
            case UInt8(ascii: "\n"): line += 1; pos += 1
            default: pos += 1
            }
        }
        throw LexError.incomplete(hint: "$(", line: startLine)
    }
}
