import Foundation

/// Evaluates `$(( ... ))` expressions with C like precedence on 64-bit integers.
struct ArithmeticEvaluator {
    var lookup: (String) -> String?
    var assign: (String, String) throws -> Void
    private var depth = 0

    init(lookup: @escaping (String) -> String?, assign: @escaping (String, String) throws -> Void) {
        self.lookup = lookup
        self.assign = assign
    }

    func evaluate(_ text: String) throws -> Int {
        var copy = self
        return try copy.evaluateInternal(text)
    }

    private mutating func evaluateInternal(_ text: String) throws -> Int {
        depth += 1
        defer { depth -= 1 }
        if depth > 64 { throw ShellRuntimeError.arithmetic("expression recursion level exceeded") }
        var parser = ExpressionParser(tokens: try ArithmeticLexer.tokenize(text), evaluator: self)
        if parser.tokens.isEmpty { return 0 }
        let value = try parser.parseComma()
        if parser.index < parser.tokens.count {
            throw ShellRuntimeError.arithmetic("syntax error in expression (error token is \"\(parser.tokens[parser.index].text)\")")
        }
        return value
    }

    /// Resolves a variable the way bash does: numbers parse directly, other strings are evaluated.
    fileprivate mutating func variableValue(_ name: String) throws -> Int {
        guard let raw = lookup(name), !raw.isEmpty else { return 0 }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let number = ArithmeticLexer.parseNumber(trimmed) { return number }
        return try evaluateInternal(trimmed)
    }

    fileprivate func store(_ name: String, _ value: Int) throws {
        try assign(name, String(value))
    }
}

private struct ArithToken: Equatable {
    enum Kind: Equatable { case number(Int), identifier(String), op(String) }
    var kind: Kind
    var text: String
}

private enum ArithmeticLexer {
    static let operators: [String] = [
        "<<=", ">>=", "**", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
        "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=",
        "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", "^", "|", "?", ":", "(", ")", ",",
    ]

    static func tokenize(_ text: String) throws -> [ArithToken] {
        let characters = Array(text)
        var tokens: [ArithToken] = []
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace { index += 1; continue }
            if c.isNumber {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "#" { end += 1 }
                let literal = String(characters[index..<end])
                guard let value = parseNumber(literal) else {
                    throw ShellRuntimeError.arithmetic("\(literal): value too great for base (error token is \"\(literal)\")")
                }
                tokens.append(ArithToken(kind: .number(value), text: literal))
                index = end
                continue
            }
            if c.isLetter || c == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let name = String(characters[index..<end])
                tokens.append(ArithToken(kind: .identifier(name), text: name))
                index = end
                continue
            }
            var matched = false
            for op in operators {
                let opChars = Array(op)
                if index + opChars.count <= characters.count, Array(characters[index..<(index + opChars.count)]) == opChars {
                    tokens.append(ArithToken(kind: .op(op), text: op))
                    index += opChars.count
                    matched = true
                    break
                }
            }
            if !matched {
                throw ShellRuntimeError.arithmetic("syntax error: invalid arithmetic operator (error token is \"\(String(characters[index...]))\")")
            }
        }
        return tokens
    }

    static func parseNumber(_ text: String) -> Int? {
        var negative = false
        var body = Substring(text)
        if body.hasPrefix("-") { negative = true; body = body.dropFirst() } else if body.hasPrefix("+") { body = body.dropFirst() }
        guard !body.isEmpty else { return nil }
        var result: Int?
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            result = Int(body.dropFirst(2), radix: 16)
        } else if let hash = body.firstIndex(of: "#") {
            guard let base = Int(body[..<hash]), base >= 2, base <= 64 else { return nil }
            result = parseWithBase(String(body[body.index(after: hash)...]), base: base)
        } else if body.hasPrefix("0"), body.count > 1 {
            result = Int(body.dropFirst(), radix: 8)
        } else {
            result = Int(body)
        }
        guard let value = result else { return nil }
        return negative ? -value : value
    }

    private static func parseWithBase(_ digits: String, base: Int) -> Int? {
        var value = 0
        for c in digits {
            var digit: Int
            if let d = c.wholeNumberValue, c.isASCII { digit = d }
            else if c >= "a" && c <= "z" { digit = Int(c.asciiValue! - Character("a").asciiValue!) + (base <= 36 ? 10 : 10) }
            else if c >= "A" && c <= "Z" { digit = Int(c.asciiValue! - Character("A").asciiValue!) + (base <= 36 ? 10 : 36) }
            else if c == "@" { digit = 62 }
            else if c == "_" { digit = 63 }
            else { return nil }
            guard digit < base else { return nil }
            value = value &* base &+ digit
        }
        return value
    }
}

private struct ExpressionParser {
    var tokens: [ArithToken]
    var index = 0
    var evaluator: ArithmeticEvaluator

    init(tokens: [ArithToken], evaluator: ArithmeticEvaluator) {
        self.tokens = tokens
        self.evaluator = evaluator
    }

    private var current: ArithToken? { index < tokens.count ? tokens[index] : nil }

    private func peekOp(_ candidates: [String]) -> String? {
        guard let token = current, case .op(let op) = token.kind, candidates.contains(op) else { return nil }
        return op
    }

    private mutating func expectOp(_ op: String) throws {
        guard peekOp([op]) != nil else {
            throw ShellRuntimeError.arithmetic("syntax error: expected `\(op)' (error token is \"\(current?.text ?? "")\")")
        }
        index += 1
    }

    mutating func parseComma() throws -> Int {
        var value = try parseAssignment()
        while peekOp([","]) != nil {
            index += 1
            value = try parseAssignment()
        }
        return value
    }

    private static let assignmentOperators = ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "^=", "|="]

    mutating func parseAssignment() throws -> Int {
        // Lookahead for `identifier assignop`.
        if let token = current, case .identifier(let name) = token.kind,
           index + 1 < tokens.count, case .op(let op) = tokens[index + 1].kind, ExpressionParser.assignmentOperators.contains(op) {
            index += 2
            let rhs = try parseAssignment()
            let result: Int
            if op == "=" {
                result = rhs
            } else {
                let lhs = try evaluator.variableValue(name)
                result = try ExpressionParser.applyBinary(String(op.dropLast()), lhs, rhs)
            }
            try evaluator.store(name, result)
            return result
        }
        return try parseTernary()
    }

    mutating func parseTernary() throws -> Int {
        let condition = try parseLogicalOr()
        if peekOp(["?"]) != nil {
            index += 1
            let whenTrue = try parseAssignment()
            try expectOp(":")
            let whenFalse = try parseAssignment()
            return condition != 0 ? whenTrue : whenFalse
        }
        return condition
    }

    mutating func parseLogicalOr() throws -> Int {
        var lhs = try parseLogicalAnd()
        while peekOp(["||"]) != nil {
            index += 1
            let rhs = try parseLogicalAnd()
            lhs = (lhs != 0 || rhs != 0) ? 1 : 0
        }
        return lhs
    }

    mutating func parseLogicalAnd() throws -> Int {
        var lhs = try parseBinary(level: 0)
        while peekOp(["&&"]) != nil {
            index += 1
            let rhs = try parseBinary(level: 0)
            lhs = (lhs != 0 && rhs != 0) ? 1 : 0
        }
        return lhs
    }

    private static let binaryLevels: [[String]] = [
        ["|"], ["^"], ["&"], ["==", "!="], ["<", "<=", ">", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"],
    ]

    mutating func parseBinary(level: Int) throws -> Int {
        if level >= ExpressionParser.binaryLevels.count { return try parsePower() }
        var lhs = try parseBinary(level: level + 1)
        while let op = peekOp(ExpressionParser.binaryLevels[level]) {
            index += 1
            let rhs = try parseBinary(level: level + 1)
            lhs = try ExpressionParser.applyBinary(op, lhs, rhs)
        }
        return lhs
    }

    mutating func parsePower() throws -> Int {
        let base = try parseUnary()
        if peekOp(["**"]) != nil {
            index += 1
            let exponent = try parsePower()
            if exponent < 0 { throw ShellRuntimeError.arithmetic("exponent less than 0") }
            var result = 1
            for _ in 0..<min(exponent, 128) { result = result &* base }
            return result
        }
        return base
    }

    mutating func parseUnary() throws -> Int {
        if let op = peekOp(["!", "~", "-", "+", "++", "--"]) {
            index += 1
            switch op {
            case "!": return try parseUnary() == 0 ? 1 : 0
            case "~": return ~(try parseUnary())
            case "-": return 0 &- (try parseUnary())
            case "+": return try parseUnary()
            case "++", "--":
                guard let token = current, case .identifier(let name) = token.kind else {
                    throw ShellRuntimeError.arithmetic("syntax error: operand expected (error token is \"\(op)\")")
                }
                index += 1
                let value = try evaluator.variableValue(name) &+ (op == "++" ? 1 : -1)
                try evaluator.store(name, value)
                return value
            default: break
            }
        }
        return try parsePostfix()
    }

    mutating func parsePostfix() throws -> Int {
        guard let token = current else {
            throw ShellRuntimeError.arithmetic("syntax error: operand expected (error token is \"\")")
        }
        switch token.kind {
        case .number(let value):
            index += 1
            return value
        case .identifier(let name):
            index += 1
            if let op = peekOp(["++", "--"]) {
                index += 1
                let value = try evaluator.variableValue(name)
                try evaluator.store(name, value &+ (op == "++" ? 1 : -1))
                return value
            }
            return try evaluator.variableValue(name)
        case .op(let op):
            if op == "(" {
                index += 1
                let value = try parseComma()
                try expectOp(")")
                return value
            }
            throw ShellRuntimeError.arithmetic("syntax error: operand expected (error token is \"\(token.text)\")")
        }
    }

    static func applyBinary(_ op: String, _ lhs: Int, _ rhs: Int) throws -> Int {
        switch op {
        case "+": return lhs &+ rhs
        case "-": return lhs &- rhs
        case "*": return lhs &* rhs
        case "/":
            if rhs == 0 { throw ShellRuntimeError.arithmetic("division by 0 (error token is \"\(rhs)\")") }
            if lhs == Int.min && rhs == -1 { return Int.min }
            return lhs / rhs
        case "%":
            if rhs == 0 { throw ShellRuntimeError.arithmetic("division by 0 (error token is \"\(rhs)\")") }
            if rhs == -1 { return 0 }
            return lhs % rhs
        case "<<": return rhs >= 0 && rhs < 64 ? lhs << rhs : 0
        case ">>": return rhs >= 0 && rhs < 64 ? lhs >> rhs : (lhs < 0 ? -1 : 0)
        case "<": return lhs < rhs ? 1 : 0
        case "<=": return lhs <= rhs ? 1 : 0
        case ">": return lhs > rhs ? 1 : 0
        case ">=": return lhs >= rhs ? 1 : 0
        case "==": return lhs == rhs ? 1 : 0
        case "!=": return lhs != rhs ? 1 : 0
        case "&": return lhs & rhs
        case "^": return lhs ^ rhs
        case "|": return lhs | rhs
        case "&&": return (lhs != 0 && rhs != 0) ? 1 : 0
        case "||": return (lhs != 0 || rhs != 0) ? 1 : 0
        default: throw ShellRuntimeError.arithmetic("unknown operator \(op)")
        }
    }
}
