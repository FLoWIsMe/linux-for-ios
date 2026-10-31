import Foundation

/// A coarse tokenizer for the command line being edited. It is deliberately forgiving: unterminated
/// quotes extend to the end of the line, and it never fails. Used by the highlighter and the
/// completion engine; the real parser lives in the interpreter.
public struct LineToken: Equatable {
    public enum Kind: Equatable {
        case word
        case operatorToken
        case comment
        case whitespace
    }

    public var kind: Kind
    /// Character offsets into the line.
    public var range: Range<Int>
    public var text: String
    /// For words: the opening quote character of the word, if the word starts with one.
    public var quote: Character?
    /// For words: true when the word is not terminated (open quote or trailing backslash).
    public var unterminated: Bool

    public init(kind: Kind, range: Range<Int>, text: String, quote: Character? = nil, unterminated: Bool = false) {
        self.kind = kind
        self.range = range
        self.text = text
        self.quote = quote
        self.unterminated = unterminated
    }
}

public enum LineTokenizer {
    static let operatorCharacters: Set<Character> = ["|", "&", ";", "<", ">", "(", ")"]

    public static func tokenize(_ line: String) -> [LineToken] {
        let characters = Array(line)
        var tokens: [LineToken] = []
        var index = 0
        let count = characters.count

        while index < count {
            let c = characters[index]
            if c == " " || c == "\t" || c == "\n" {
                let start = index
                while index < count, characters[index] == " " || characters[index] == "\t" || characters[index] == "\n" { index += 1 }
                tokens.append(LineToken(kind: .whitespace, range: start..<index, text: String(characters[start..<index])))
                continue
            }
            if c == "#" {
                let start = index
                while index < count, characters[index] != "\n" { index += 1 }
                tokens.append(LineToken(kind: .comment, range: start..<index, text: String(characters[start..<index])))
                continue
            }
            if operatorCharacters.contains(c) {
                let start = index
                index += 1
                // Two character operators.
                if index < count {
                    let pair = String([c, characters[index]])
                    if ["||", "&&", ";;", "<<", ">>", "<&", ">&", "<>", ">|", "|&"].contains(pair) {
                        index += 1
                        if pair == "<<", index < count, characters[index] == "<" { index += 1 }
                    }
                }
                tokens.append(LineToken(kind: .operatorToken, range: start..<index, text: String(characters[start..<index])))
                continue
            }
            // A word: runs until unquoted whitespace or an operator. Digits directly before a redirection
            // operator (2>) stay with the operator.
            let start = index
            var quote: Character? = nil
            var openQuote: Character? = nil
            var unterminated = false
            var escaped = false
            var depth = 0 // $( ... ) and ${ ... } nesting inside the word
            while index < count {
                let ch = characters[index]
                if escaped {
                    escaped = false
                    index += 1
                    continue
                }
                if let q = openQuote {
                    if ch == q {
                        openQuote = nil
                    } else if ch == "\\", q == "\"" {
                        escaped = true
                    }
                    index += 1
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    index += 1
                    continue
                }
                if ch == "'" || ch == "\"" || ch == "`" {
                    if index == start { quote = ch }
                    openQuote = ch
                    index += 1
                    continue
                }
                if ch == "$", index + 1 < count, characters[index + 1] == "(" || characters[index + 1] == "{" {
                    depth += 1
                    index += 2
                    continue
                }
                if depth > 0, ch == ")" || ch == "}" {
                    depth -= 1
                    index += 1
                    continue
                }
                if depth == 0, ch == " " || ch == "\t" || ch == "\n" || operatorCharacters.contains(ch) {
                    if operatorCharacters.contains(ch), ch == ">" || ch == "<", index > start,
                       characters[start..<index].allSatisfy({ $0.isNumber }) {
                        // "2>" style redirection: the digits belong to the operator.
                        break
                    }
                    break
                }
                index += 1
            }
            if openQuote != nil || escaped { unterminated = true }
            if index == start { index += 1 }
            var text = String(characters[start..<index])
            // Attach "2>" digits to the following operator token.
            if index < count, characters[index] == ">" || characters[index] == "<", text.allSatisfy({ $0.isNumber }), !text.isEmpty {
                var end = index + 1
                if end < count, characters[end] == ">" || characters[end] == "&" || characters[end] == "|" { end += 1 }
                text = String(characters[start..<end])
                tokens.append(LineToken(kind: .operatorToken, range: start..<end, text: text))
                index = end
                continue
            }
            tokens.append(LineToken(kind: .word, range: start..<index, text: text, quote: quote, unterminated: unterminated))
        }
        return tokens
    }

    /// Words that are followed by a command name rather than an argument.
    public static let commandPrefixWords: Set<String> = [
        "if", "then", "else", "elif", "do", "while", "until", "!", "time", "exec", "command", "builtin",
        "sudo", "nohup", "env", "xargs", "nice", "doas", "watch",
    ]

    /// Reserved words of the shell language (highlighted like commands but never looked up).
    public static let reservedWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
        "function", "select", "{", "}", "!", "time", "[[", "]]",
    ]

    /// True when a word is a `NAME=value` assignment.
    public static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[word.startIndex..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Removes shell quoting from a word the way the interpreter would, ignoring expansions.
    public static func unquote(_ word: String) -> String {
        var result = ""
        var openQuote: Character? = nil
        var escaped = false
        for ch in word {
            if escaped {
                result.append(ch)
                escaped = false
                continue
            }
            if let q = openQuote {
                if ch == q { openQuote = nil } else if ch == "\\", q == "\"" { escaped = true } else { result.append(ch) }
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "'" || ch == "\"" { openQuote = ch; continue }
            result.append(ch)
        }
        return result
    }

    /// Escapes characters that are special to the shell with backslashes.
    public static func escape(_ text: String) -> String {
        let special: Set<Character> = [" ", "\t", "\n", "\"", "'", "\\", "$", "`", "!", "#", "&", "|", ";", "(", ")", "<", ">", "*", "?", "[", "]", "{", "}"]
        var result = ""
        for (index, ch) in text.enumerated() {
            if special.contains(ch) {
                if ch == "#" {
                    if index == 0 { result.append("\\") }
                } else {
                    result.append("\\")
                }
            }
            result.append(ch)
        }
        return result
    }
}
