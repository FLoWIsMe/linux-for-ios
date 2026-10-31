import Foundation

enum ParseError: Error, Equatable {
    /// More input would make the program valid. `hint` names the open construct.
    case incomplete(hint: String, line: Int)
    /// The program is invalid.
    case syntax(message: String, line: Int)

    var line: Int {
        switch self {
        case .incomplete(_, let line), .syntax(_, let line): return line
        }
    }
}

private struct PendingHeredoc {
    let id: Int
    let delimiter: String
    let stripTabs: Bool
}

/// Recursive descent parser for the shell grammar. Parses one complete command at a time so that
/// aliases and options defined by earlier commands affect later ones, like a real shell.
final class Parser {
    private let lexer: Lexer
    private var buffer: [Token] = []
    private let aliasLookup: (String) -> String?
    private var pendingHeredocs: [PendingHeredoc] = []
    private var heredocBodies: [Int: String] = [:]
    private var nextHeredocID = 1
    /// Aliases expanded for the simple command being parsed, to stop recursion.
    private var activeAliases: Set<String> = []

    static let reservedWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "in", "{", "}", "!", "function", "time", "[[", "]]", "select",
    ]

    /// Reserved words that may only appear where a construct expects them.
    private static let terminatorWords: Set<String> = [
        "then", "else", "elif", "fi", "do", "done", "esac", "}", "in", "]]",
    ]

    init(source: String, aliasLookup: @escaping (String) -> String? = { _ in nil }) {
        self.lexer = Lexer(source)
        self.aliasLookup = aliasLookup
    }

    // MARK: Token access

    /// Runs a lexer operation, converting lexer errors into parse errors.
    private func lex<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as LexError {
            switch error {
            case .incomplete(let hint, let line): throw ParseError.incomplete(hint: hint, line: line)
            case .invalid(let message, let line): throw ParseError.syntax(message: message, line: line)
            }
        }
    }

    private func peek(_ offset: Int = 0) throws -> Token {
        while buffer.count <= offset {
            buffer.append(try lex { try lexer.next() })
        }
        return buffer[offset]
    }

    @discardableResult
    private func advance() throws -> Token {
        let token = try peek()
        buffer.removeFirst()
        return token
    }

    private func consumeNewline() throws {
        let token = try advance()
        precondition(token.kind == .newline)
        try readPendingHeredocs()
    }

    private func readPendingHeredocs() throws {
        guard !pendingHeredocs.isEmpty else { return }
        // Any lookahead must be discarded: the heredoc body starts right after the newline.
        buffer.removeAll()
        let pending = pendingHeredocs
        pendingHeredocs.removeAll()
        for heredoc in pending {
            heredocBodies[heredoc.id] = try lex { try lexer.readHeredocBody(delimiter: heredoc.delimiter, stripTabs: heredoc.stripTabs) }
        }
    }

    private func skipNewlines() throws {
        while try peek().kind == .newline {
            try consumeNewline()
        }
    }

    private func isUnquotedWord(_ token: Token, _ text: String) -> Bool {
        token.wordText == text
    }

    private func unexpected(_ token: Token) -> ParseError {
        switch token.kind {
        case .eof:
            return .incomplete(hint: "eof", line: token.line)
        case .newline:
            return .syntax(message: "syntax error near unexpected token `newline'", line: token.line)
        case .op(let op):
            return .syntax(message: "syntax error near unexpected token `\(op.rawValue)'", line: token.line)
        case .word(let text):
            return .syntax(message: "syntax error near unexpected token `\(text)'", line: token.line)
        case .ioNumber(let n):
            return .syntax(message: "syntax error near unexpected token `\(n)'", line: token.line)
        }
    }

    /// Expects a reserved word; converts EOF into an incomplete error with `hint`.
    private func expectWord(_ word: String, hint: String) throws {
        let token = try peek()
        if isUnquotedWord(token, word) {
            try advance()
            return
        }
        if token.kind == .eof { throw ParseError.incomplete(hint: hint, line: token.line) }
        throw unexpected(token)
    }

    private func expectOperator(_ op: Operator, hint: String) throws {
        let token = try peek()
        if token.isOperator(op) {
            try advance()
            return
        }
        if token.kind == .eof { throw ParseError.incomplete(hint: hint, line: token.line) }
        throw unexpected(token)
    }

    // MARK: Entry points

    /// Parses the next top level command list, which ends at a newline (outside compound commands)
    /// or at the end of input. Returns nil when the input is exhausted.
    func parseCompleteCommand() throws -> CommandList? {
        try skipNewlines()
        let first = try peek()
        if first.kind == .eof { return nil }
        if isListTerminator(first, terminators: []) { throw unexpected(first) }
        var list = try parseList(terminators: [], topLevel: true)
        if !pendingHeredocs.isEmpty {
            // Input ended before the heredoc body was supplied.
            throw ParseError.incomplete(hint: "heredoc", line: try peek().line)
        }
        fillHeredocs(in: &list)
        return list
    }

    /// Parses everything. Used by `parseState`.
    func parseAll() throws -> [CommandList] {
        var lists: [CommandList] = []
        while let list = try parseCompleteCommand() {
            lists.append(list)
        }
        return lists
    }

    // MARK: Lists

    private func isListTerminator(_ token: Token, terminators: Set<String>) -> Bool {
        switch token.kind {
        case .eof: return true
        case .word(let text): return terminators.contains(text)
        case .op(let op):
            return op == .rightParen || op == .doubleSemicolon || op == .semicolonAmpersand || op == .doubleSemicolonAmpersand
        default: return false
        }
    }

    private func parseList(terminators: Set<String>, topLevel: Bool, allowEmpty: Bool = false) throws -> CommandList {
        var list = CommandList()
        try skipNewlines()
        list.line = try peek().line
        while true {
            let token = try peek()
            if isListTerminator(token, terminators: terminators) {
                if list.items.isEmpty, !topLevel, !allowEmpty, token.kind != .eof {
                    // Compound commands need at least one command, like bash: `if then` is an error.
                    // At EOF the caller reports which construct is still open.
                    throw unexpected(token)
                }
                break
            }
            let andOr = try parseAndOr()
            let separatorToken = try peek()
            switch separatorToken.kind {
            case .op(.semicolon):
                try advance()
                list.items.append(ListItem(andOr: andOr, separator: .sequential))
                if topLevel {
                    // `a; b` on one line is one complete command; a newline ends it.
                    if try peek().kind == .newline {
                        try consumeNewline()
                        return list
                    }
                } else {
                    try skipNewlines()
                }
            case .op(.ampersand):
                try advance()
                list.items.append(ListItem(andOr: andOr, separator: .background))
                if topLevel {
                    if try peek().kind == .newline {
                        try consumeNewline()
                        return list
                    }
                } else {
                    try skipNewlines()
                }
            case .newline:
                list.items.append(ListItem(andOr: andOr, separator: .sequential))
                try consumeNewline()
                if topLevel { return list }
                try skipNewlines()
            case .eof:
                list.items.append(ListItem(andOr: andOr, separator: .sequential))
                return list
            default:
                if isListTerminator(separatorToken, terminators: terminators) {
                    list.items.append(ListItem(andOr: andOr, separator: .sequential))
                    return list
                }
                throw unexpected(separatorToken)
            }
        }
        return list
    }

    private func parseAndOr() throws -> AndOrList {
        let first = try parsePipeline()
        var rest: [(ListOperator, Pipeline)] = []
        while true {
            let token = try peek()
            if token.isOperator(.and) {
                try advance()
                try skipNewlines()
                rest.append((.and, try parsePipeline()))
            } else if token.isOperator(.or) {
                try advance()
                try skipNewlines()
                rest.append((.or, try parsePipeline()))
            } else {
                break
            }
        }
        return AndOrList(first: first, rest: rest)
    }

    private func parsePipeline() throws -> Pipeline {
        var negated = false
        var timed = false
        let line = try peek().line
        while true {
            let token = try peek()
            if isUnquotedWord(token, "!") {
                try advance()
                negated.toggle()
            } else if isUnquotedWord(token, "time") {
                try advance()
                timed = true
                // `time -p` is accepted and ignored.
                if isUnquotedWord(try peek(), "-p") { try advance() }
            } else {
                break
            }
        }
        var stages = [PipelineStage(command: try parseCommand())]
        while true {
            let token = try peek()
            if token.isOperator(.pipe) || token.isOperator(.pipeBoth) {
                try advance()
                stages[stages.count - 1].pipesStderr = token.isOperator(.pipeBoth)
                try skipNewlines()
                stages.append(PipelineStage(command: try parseCommand()))
            } else {
                break
            }
        }
        return Pipeline(stages: stages, negated: negated, timed: timed, line: line)
    }

    // MARK: Commands

    private var nestingDepth = 0

    private func parseCommand() throws -> Command {
        activeAliases.removeAll()
        nestingDepth += 1
        defer { nestingDepth -= 1 }
        if nestingDepth > 200 {
            throw ParseError.syntax(message: "syntax error: commands are nested too deeply", line: try peek().line)
        }
        return try parseCommandAfterAliases()
    }

    private func parseCommandAfterAliases() throws -> Command {
        let token = try peek()
        switch token.kind {
        case .eof:
            throw ParseError.incomplete(hint: "command", line: token.line)
        case .newline:
            throw unexpected(token)
        case .op(let op):
            if op == .leftParen {
                if lexer.sourceHasPrefix("((", at: token.start) {
                    let text = try lex { try lexer.readArithmeticCommand(from: token.start) }
                    buffer.removeAll()
                    let redirections = try parseRedirections()
                    return .compound(.arithmetic(text), redirections: redirections, line: token.line)
                }
                try advance()
                let body = try parseList(terminators: [], topLevel: false)
                try expectOperator(.rightParen, hint: "(")
                let redirections = try parseRedirections()
                return .compound(.subshell(body), redirections: redirections, line: token.line)
            }
            if op.isRedirection {
                return .simple(try parseSimpleCommand())
            }
            throw unexpected(token)
        case .ioNumber:
            return .simple(try parseSimpleCommand())
        case .word(let text):
            if Parser.terminatorWords.contains(text) {
                throw unexpected(token)
            }
            switch text {
            case "{":
                try advance()
                let body = try parseList(terminators: ["}"], topLevel: false)
                try expectWord("}", hint: "{")
                let redirections = try parseRedirections()
                return .compound(.braceGroup(body), redirections: redirections, line: token.line)
            case "if": return try parseIf()
            case "for": return try parseFor()
            case "while": return try parseWhileUntil(isUntil: false)
            case "until": return try parseWhileUntil(isUntil: true)
            case "case": return try parseCase()
            case "[[": return try parseConditional()
            case "function":
                try advance()
                let nameToken = try peek()
                guard let name = nameToken.wordText, Parser.isValidName(name) else { throw unexpected(nameToken) }
                try advance()
                if try peek().isOperator(.leftParen) {
                    try advance()
                    try expectOperator(.rightParen, hint: "function")
                }
                try skipNewlines()
                let body = try parseCommand()
                return .function(FunctionDefinition(name: name, body: body, line: token.line))
            case "select":
                throw ParseError.syntax(message: "select is not supported", line: token.line)
            default:
                break
            }
            // Alias expansion applies to the first word of a simple command.
            if !isAssignmentWord(text), !activeAliases.contains(text), let value = aliasLookup(text) {
                activeAliases.insert(text)
                try advance()
                buffer.removeAll()
                lexer.insert(value + " ")
                return try parseCommandAfterAliases()
            }
            // Function definition: name ( )
            if Parser.isValidName(text), try peek(1).isOperator(.leftParen) {
                let third = try peek(2)
                if third.isOperator(.rightParen) {
                    try advance(); try advance(); try advance()
                    try skipNewlines()
                    let body = try parseCommand()
                    return .function(FunctionDefinition(name: text, body: body, line: token.line))
                }
            }
            return .simple(try parseSimpleCommand())
        }
    }

    static func isValidName(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        func isAlpha(_ c: UInt8) -> Bool {
            (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || c == UInt8(ascii: "_")
        }
        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        guard isAlpha(first) else { return false }
        return text.utf8.allSatisfy { isAlpha($0) || isDigit($0) }
    }

    /// `name=value` or `name+=value` with an unquoted `=`. Returns the name and the value text.
    static func splitAssignment(_ text: String) -> (name: String, value: String, append: Bool)? {
        let bytes = Array(text.utf8)
        var index = 0
        func isAlpha(_ c: UInt8) -> Bool {
            (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || c == UInt8(ascii: "_")
        }
        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        guard index < bytes.count, isAlpha(bytes[index]) else { return nil }
        while index < bytes.count, isAlpha(bytes[index]) || isDigit(bytes[index]) { index += 1 }
        guard index < bytes.count else { return nil }
        var append = false
        if bytes[index] == UInt8(ascii: "+") {
            guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "=") else { return nil }
            append = true
            index += 1
        }
        guard bytes[index] == UInt8(ascii: "=") else { return nil }
        let name = String(decoding: bytes[0..<(append ? index - 1 : index)], as: UTF8.self)
        let value = String(decoding: bytes[(index + 1)...], as: UTF8.self)
        return (name, value, append)
    }

    private func isAssignmentWord(_ text: String) -> Bool {
        Parser.splitAssignment(text) != nil
    }

    private func parseSimpleCommand() throws -> SimpleCommand {
        var command = SimpleCommand()
        command.line = try peek().line
        var sawCommandWord = false
        loop: while true {
            let token = try peek()
            switch token.kind {
            case .ioNumber(let fd):
                try advance()
                let opToken = try peek()
                guard case .op(let op) = opToken.kind, op.isRedirection else { throw unexpected(opToken) }
                try advance()
                command.redirections.append(try parseRedirectionTarget(op: op, fd: fd, line: token.line))
            case .op(let op) where op.isRedirection:
                try advance()
                command.redirections.append(try parseRedirectionTarget(op: op, fd: nil, line: token.line))
            case .word(let text):
                if !sawCommandWord, let assignment = Parser.splitAssignment(text) {
                    // Detect array syntax to give a clear message.
                    if assignment.value.isEmpty, try peek(1).isOperator(.leftParen) {
                        throw ParseError.syntax(message: "arrays are not supported", line: token.line)
                    }
                    try advance()
                    command.assignments.append(Assignment(name: assignment.name, value: Word(assignment.value, line: token.line), append: assignment.append))
                } else {
                    try advance()
                    sawCommandWord = true
                    command.words.append(Word(text, line: token.line))
                }
            default:
                break loop
            }
        }
        if command.words.isEmpty && command.assignments.isEmpty && command.redirections.isEmpty {
            throw unexpected(try peek())
        }
        return command
    }

    private func parseRedirections() throws -> [Redirection] {
        var redirections: [Redirection] = []
        while true {
            let token = try peek()
            switch token.kind {
            case .ioNumber(let fd):
                try advance()
                let opToken = try peek()
                guard case .op(let op) = opToken.kind, op.isRedirection else { throw unexpected(opToken) }
                try advance()
                redirections.append(try parseRedirectionTarget(op: op, fd: fd, line: token.line))
            case .op(let op) where op.isRedirection:
                try advance()
                redirections.append(try parseRedirectionTarget(op: op, fd: nil, line: token.line))
            default:
                return redirections
            }
        }
    }

    private func parseRedirectionTarget(op: Operator, fd: Int32?, line: Int) throws -> Redirection {
        let targetToken = try peek()
        guard let target = targetToken.wordText else {
            if targetToken.kind == .eof { throw ParseError.incomplete(hint: "redirect", line: line) }
            throw unexpected(targetToken)
        }
        try advance()
        let kind: RedirectionKind
        switch op {
        case .less: kind = .input
        case .great: kind = .output
        case .clobber: kind = .outputClobber
        case .doubleGreat: kind = .append
        case .lessGreat: kind = .readWrite
        case .lessAnd: kind = .duplicateInput
        case .greatAnd: kind = .duplicateOutput
        case .tripleLess: kind = .herestring
        case .ampersandGreat: kind = .bothOutput
        case .ampersandDoubleGreat: kind = .bothAppend
        case .doubleLess, .doubleLessDash:
            let (delimiter, quoted) = Parser.heredocDelimiter(target)
            let id = nextHeredocID
            nextHeredocID += 1
            pendingHeredocs.append(PendingHeredoc(id: id, delimiter: delimiter, stripTabs: op == .doubleLessDash))
            var redirection = Redirection(fd: fd, kind: .heredoc, target: Word(target, line: line), line: line)
            redirection.heredocBody = "\u{1}\(id)"
            redirection.heredocExpands = !quoted
            return redirection
        default:
            throw unexpected(targetToken)
        }
        return Redirection(fd: fd, kind: kind, target: Word(target, line: line), line: line)
    }

    /// Removes quoting from a heredoc delimiter and reports whether any part was quoted.
    static func heredocDelimiter(_ raw: String) -> (String, Bool) {
        var result = ""
        var quoted = false
        let characters = Array(raw)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "'" || c == "\"" {
                quoted = true
                index += 1
                while index < characters.count, characters[index] != c {
                    result.append(characters[index])
                    index += 1
                }
                index += 1
            } else if c == "\\" {
                quoted = true
                index += 1
                if index < characters.count {
                    result.append(characters[index])
                    index += 1
                }
            } else {
                result.append(c)
                index += 1
            }
        }
        return (result, quoted)
    }

    // MARK: Compound commands

    private func parseIf() throws -> Command {
        let start = try advance() // if
        var clauses: [IfClause] = []
        var elseBody: CommandList?
        let condition = try parseList(terminators: ["then"], topLevel: false)
        try expectWord("then", hint: "if")
        let body = try parseList(terminators: ["elif", "else", "fi"], topLevel: false)
        clauses.append(IfClause(condition: condition, body: body))
        while true {
            let token = try peek()
            if isUnquotedWord(token, "elif") {
                try advance()
                let condition = try parseList(terminators: ["then"], topLevel: false)
                try expectWord("then", hint: "if")
                let body = try parseList(terminators: ["elif", "else", "fi"], topLevel: false)
                clauses.append(IfClause(condition: condition, body: body))
            } else if isUnquotedWord(token, "else") {
                try advance()
                elseBody = try parseList(terminators: ["fi"], topLevel: false)
            } else if isUnquotedWord(token, "fi") {
                try advance()
                break
            } else if token.kind == .eof {
                throw ParseError.incomplete(hint: "if", line: token.line)
            } else {
                throw unexpected(token)
            }
        }
        let redirections = try parseRedirections()
        return .compound(.ifClause(clauses: clauses, elseBody: elseBody), redirections: redirections, line: start.line)
    }

    private func parseFor() throws -> Command {
        let start = try advance() // for
        let nameToken = try peek()
        if nameToken.isOperator(.leftParen), lexer.sourceHasPrefix("((", at: nameToken.start) {
            let text = try lex { try lexer.readArithmeticCommand(from: nameToken.start) }
            buffer.removeAll()
            let parts = Parser.splitArithmeticFor(text)
            guard parts.count == 3 else {
                throw ParseError.syntax(message: "syntax error: bad for loop header `((\(text)))'", line: start.line)
            }
            try skipLoopSeparator()
            let body = try parseDoGroup(hint: "for")
            let redirections = try parseRedirections()
            return .compound(.arithmeticFor(initializer: parts[0], condition: parts[1], step: parts[2], body: body), redirections: redirections, line: start.line)
        }
        guard let name = nameToken.wordText, Parser.isValidName(name) else {
            if nameToken.kind == .eof { throw ParseError.incomplete(hint: "for", line: start.line) }
            throw unexpected(nameToken)
        }
        try advance()
        try skipNewlines()
        var words: [Word]?
        if isUnquotedWord(try peek(), "in") {
            try advance()
            var collected: [Word] = []
            while let text = try peek().wordText, text != "do", text != "done" {
                collected.append(Word(text, line: try peek().line))
                try advance()
            }
            words = collected
        }
        try skipLoopSeparator()
        let body = try parseDoGroup(hint: "for")
        let redirections = try parseRedirections()
        return .compound(.forLoop(variable: name, words: words, body: body), redirections: redirections, line: start.line)
    }

    /// Accepts `;` and newlines between a loop header and `do`.
    private func skipLoopSeparator() throws {
        if try peek().isOperator(.semicolon) { try advance() }
        try skipNewlines()
    }

    private func parseDoGroup(hint: String) throws -> CommandList {
        try expectWord("do", hint: hint)
        let body = try parseList(terminators: ["done"], topLevel: false)
        try expectWord("done", hint: hint)
        return body
    }

    static func splitArithmeticFor(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for c in text {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if c == ";" && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseWhileUntil(isUntil: Bool) throws -> Command {
        let start = try advance()
        let hint = isUntil ? "until" : "while"
        let condition = try parseList(terminators: ["do"], topLevel: false)
        let body = try parseDoGroup(hint: hint)
        let redirections = try parseRedirections()
        if isUntil {
            return .compound(.untilLoop(condition: condition, body: body), redirections: redirections, line: start.line)
        }
        return .compound(.whileLoop(condition: condition, body: body), redirections: redirections, line: start.line)
    }

    private func parseCase() throws -> Command {
        let start = try advance() // case
        let subjectToken = try peek()
        guard let subject = subjectToken.wordText else {
            if subjectToken.kind == .eof { throw ParseError.incomplete(hint: "case", line: start.line) }
            throw unexpected(subjectToken)
        }
        try advance()
        try skipNewlines()
        try expectWord("in", hint: "case")
        try skipNewlines()
        var items: [CaseItem] = []
        while true {
            var token = try peek()
            if isUnquotedWord(token, "esac") {
                try advance()
                break
            }
            if token.kind == .eof { throw ParseError.incomplete(hint: "case", line: token.line) }
            if token.isOperator(.leftParen) {
                try advance()
                token = try peek()
            }
            var patterns: [Word] = []
            while true {
                let patternToken = try peek()
                guard let text = patternToken.wordText else {
                    if patternToken.kind == .eof { throw ParseError.incomplete(hint: "case", line: patternToken.line) }
                    throw unexpected(patternToken)
                }
                try advance()
                patterns.append(Word(text, line: patternToken.line))
                let next = try peek()
                if next.isOperator(.pipe) {
                    try advance()
                    continue
                }
                if next.isOperator(.rightParen) {
                    try advance()
                    break
                }
                if next.kind == .eof { throw ParseError.incomplete(hint: "case", line: next.line) }
                throw unexpected(next)
            }
            let body = try parseList(terminators: ["esac"], topLevel: false, allowEmpty: true)
            let terminatorToken = try peek()
            var terminator = CaseTerminator.stop
            if terminatorToken.isOperator(.doubleSemicolon) {
                try advance()
            } else if terminatorToken.isOperator(.semicolonAmpersand) {
                try advance()
                terminator = .fallThrough
            } else if terminatorToken.isOperator(.doubleSemicolonAmpersand) {
                try advance()
                terminator = .continueMatching
            } else if isUnquotedWord(terminatorToken, "esac") {
                // last item without ;;
            } else if terminatorToken.kind == .eof {
                throw ParseError.incomplete(hint: "case", line: terminatorToken.line)
            } else {
                throw unexpected(terminatorToken)
            }
            items.append(CaseItem(patterns: patterns, body: body, terminator: terminator))
            try skipNewlines()
        }
        let redirections = try parseRedirections()
        return .compound(.caseClause(subject: Word(subject, line: start.line), items: items), redirections: redirections, line: start.line)
    }

    // MARK: [[ ... ]]

    private static let conditionalBinaryOperators: Set<String> = [
        "==", "=", "!=", "=~", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef",
    ]
    private static let conditionalUnaryOperators: Set<String> = [
        "-a", "-b", "-c", "-d", "-e", "-f", "-g", "-h", "-k", "-p", "-r", "-s", "-t", "-u", "-w", "-x",
        "-G", "-L", "-N", "-O", "-S", "-z", "-n", "-o", "-v", "-R",
    ]

    private func parseConditional() throws -> Command {
        let start = try advance() // [[
        buffer.removeAll()
        lexer.conditionalMode = true
        defer { lexer.conditionalMode = false }
        try skipNewlines()
        let expression = try parseConditionalOr()
        try skipNewlines()
        try expectWord("]]", hint: "[[")
        lexer.conditionalMode = false
        let redirections = try parseRedirections()
        return .compound(.conditional(expression), redirections: redirections, line: start.line)
    }

    private func conditionalEnd(_ token: Token) -> Bool {
        isUnquotedWord(token, "]]") || token.kind == .eof
    }

    private func parseConditionalOr() throws -> ConditionalExpression {
        var lhs = try parseConditionalAnd()
        while true {
            try skipNewlines()
            if try peek().isOperator(.or) {
                try advance()
                try skipNewlines()
                let rhs = try parseConditionalAnd()
                lhs = .or(lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    private func parseConditionalAnd() throws -> ConditionalExpression {
        var lhs = try parseConditionalUnary()
        while true {
            try skipNewlines()
            if try peek().isOperator(.and) {
                try advance()
                try skipNewlines()
                let rhs = try parseConditionalUnary()
                lhs = .and(lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    private func parseConditionalUnary() throws -> ConditionalExpression {
        try skipNewlines()
        let token = try peek()
        if token.kind == .eof { throw ParseError.incomplete(hint: "[[", line: token.line) }
        if isUnquotedWord(token, "!") {
            try advance()
            return .not(try parseConditionalUnary())
        }
        if token.isOperator(.leftParen) {
            try advance()
            let inner = try parseConditionalOr()
            try skipNewlines()
            try expectOperator(.rightParen, hint: "[[")
            return inner
        }
        guard let text = token.wordText else { throw unexpected(token) }
        if Parser.conditionalUnaryOperators.contains(text) {
            let operandToken = try peek(1)
            if operandToken.kind == .eof { throw ParseError.incomplete(hint: "[[", line: operandToken.line) }
            if let operand = operandToken.wordText, !conditionalEnd(operandToken) {
                try advance(); try advance()
                return .unary(op: text, operand: Word(operand, line: operandToken.line))
            }
            // A lone operator word is just a non-empty string test.
            try advance()
            return .string(Word(text, line: token.line))
        }
        try advance()
        let lhs = Word(text, line: token.line)
        let opToken = try peek()
        if opToken.isOperator(.less) || opToken.isOperator(.great) {
            try advance()
            let rhsToken = try peek()
            guard let rhs = rhsToken.wordText, !conditionalEnd(rhsToken) else {
                if rhsToken.kind == .eof { throw ParseError.incomplete(hint: "[[", line: rhsToken.line) }
                throw unexpected(rhsToken)
            }
            try advance()
            return .binary(op: opToken.isOperator(.less) ? "<" : ">", lhs: lhs, rhs: Word(rhs, line: rhsToken.line))
        }
        if let op = opToken.wordText, Parser.conditionalBinaryOperators.contains(op) {
            try advance()
            if op == "=~" {
                buffer.removeAll()
                let patternToken = try lex { try lexer.readConditionalPattern() }
                guard let pattern = patternToken.wordText else {
                    throw ParseError.incomplete(hint: "[[", line: patternToken.line)
                }
                return .binary(op: op, lhs: lhs, rhs: Word(pattern, line: patternToken.line))
            }
            let rhsToken = try peek()
            guard let rhs = rhsToken.wordText, !conditionalEnd(rhsToken) else {
                if rhsToken.kind == .eof { throw ParseError.incomplete(hint: "[[", line: rhsToken.line) }
                throw unexpected(rhsToken)
            }
            try advance()
            return .binary(op: op, lhs: lhs, rhs: Word(rhs, line: rhsToken.line))
        }
        return .string(lhs)
    }

    // MARK: Heredoc bodies

    private func fillHeredocs(in list: inout CommandList) {
        guard !heredocBodies.isEmpty else { return }
        for index in list.items.indices {
            fill(&list.items[index].andOr)
        }
    }

    private func fill(_ andOr: inout AndOrList) {
        fill(&andOr.first)
        for index in andOr.rest.indices {
            fill(&andOr.rest[index].1)
        }
    }

    private func fill(_ pipeline: inout Pipeline) {
        for index in pipeline.stages.indices {
            fill(&pipeline.stages[index].command)
        }
    }

    private func fill(_ command: inout Command) {
        switch command {
        case .simple(var simple):
            fill(&simple.redirections)
            command = .simple(simple)
        case .compound(var compound, var redirections, let line):
            fill(&redirections)
            fill(&compound)
            command = .compound(compound, redirections: redirections, line: line)
        case .function(var definition):
            fill(&definition.body)
            command = .function(definition)
        }
    }

    private func fill(_ compound: inout CompoundCommand) {
        switch compound {
        case .braceGroup(var list):
            fill(&list)
            compound = .braceGroup(list)
        case .subshell(var list):
            fill(&list)
            compound = .subshell(list)
        case .ifClause(var clauses, var elseBody):
            for index in clauses.indices {
                fill(&clauses[index].condition)
                fill(&clauses[index].body)
            }
            if elseBody != nil { fill(&elseBody!) }
            compound = .ifClause(clauses: clauses, elseBody: elseBody)
        case .forLoop(let variable, let words, var body):
            fill(&body)
            compound = .forLoop(variable: variable, words: words, body: body)
        case .arithmeticFor(let a, let b, let c, var body):
            fill(&body)
            compound = .arithmeticFor(initializer: a, condition: b, step: c, body: body)
        case .whileLoop(var condition, var body):
            fill(&condition)
            fill(&body)
            compound = .whileLoop(condition: condition, body: body)
        case .untilLoop(var condition, var body):
            fill(&condition)
            fill(&body)
            compound = .untilLoop(condition: condition, body: body)
        case .caseClause(let subject, var items):
            for index in items.indices { fill(&items[index].body) }
            compound = .caseClause(subject: subject, items: items)
        case .conditional, .arithmetic:
            break
        }
    }

    private func fill(_ list: inout CommandList) {
        for index in list.items.indices {
            fill(&list.items[index].andOr)
        }
    }

    private func fill(_ redirections: inout [Redirection]) {
        for index in redirections.indices where redirections[index].kind == .heredoc {
            let body = redirections[index].heredocBody
            if body.hasPrefix("\u{1}"), let id = Int(body.dropFirst()), let text = heredocBodies[id] {
                redirections[index].heredocBody = text
            }
        }
    }
}
