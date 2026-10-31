import Foundation

/// Syntax coloring for the line being edited, in the spirit of fish.
public struct HighlightSpan: Equatable {
    public enum Style: Equatable {
        case command
        case invalidCommand
        case reservedWord
        case string
        case option
        case variable
        case assignment
        case operatorToken
        case comment
        case path
        case argument

        /// Standard SGR sequence for the style, using the 16 color palette so themes apply.
        public var sgr: String {
            switch self {
            case .command: return ANSI.bold
            case .invalidCommand: return ANSI.Color.red.foreground
            case .reservedWord: return ANSI.sgr(1, 34)
            case .string: return ANSI.Color.yellow.foreground
            case .option: return ANSI.Color.cyan.foreground
            case .variable: return ANSI.Color.magenta.foreground
            case .assignment: return ANSI.Color.magenta.foreground
            case .operatorToken: return ANSI.bold
            case .comment: return ANSI.dim
            case .path: return ANSI.underline
            case .argument: return ""
            }
        }
    }

    /// Character offsets into the line.
    public var range: Range<Int>
    public var style: Style

    public init(range: Range<Int>, style: Style) {
        self.range = range
        self.style = style
    }
}

/// Produces highlight spans for a line. The caller supplies the shell state and a file existence
/// check so the highlighter stays pure and testable.
public struct Highlighter {
    public var snapshot: ShellSnapshot
    /// Returns true when the (already unquoted) path exists relative to the working directory.
    public var pathExists: (String) -> Bool

    public init(snapshot: ShellSnapshot, pathExists: ((String) -> Bool)? = nil) {
        self.snapshot = snapshot
        if let pathExists {
            self.pathExists = pathExists
        } else {
            let base = snapshot.workingDirectory
            let home = snapshot.homeDirectory
            self.pathExists = { path in
                Highlighter.defaultPathExists(path, workingDirectory: base, homeDirectory: home)
            }
        }
    }

    static func defaultPathExists(_ path: String, workingDirectory: String, homeDirectory: String) -> Bool {
        guard !path.isEmpty else { return false }
        var resolved = path
        if resolved == "~" { resolved = homeDirectory }
        else if resolved.hasPrefix("~/") { resolved = homeDirectory + resolved.dropFirst(1) }
        if !resolved.hasPrefix("/") { resolved = workingDirectory + "/" + resolved }
        return FileManager.default.fileExists(atPath: resolved)
    }

    public func highlight(_ line: String) -> [HighlightSpan] {
        let tokens = LineTokenizer.tokenize(line)
        var spans: [HighlightSpan] = []
        var expectCommand = true
        let knownCommands = Set(snapshot.allCommandNames)

        for token in tokens {
            switch token.kind {
            case .whitespace:
                continue
            case .comment:
                spans.append(HighlightSpan(range: token.range, style: .comment))
            case .operatorToken:
                spans.append(HighlightSpan(range: token.range, style: .operatorToken))
                // After a control operator the next word is a command again; after a redirection it is a file.
                let redirect = token.text.contains(">") || token.text.contains("<")
                expectCommand = !redirect
            case .word:
                let word = token.text
                if expectCommand {
                    if LineTokenizer.isAssignment(word) {
                        spans.append(contentsOf: assignmentSpans(token))
                        continue
                    }
                    if LineTokenizer.reservedWords.contains(word) {
                        spans.append(HighlightSpan(range: token.range, style: .reservedWord))
                        expectCommand = LineTokenizer.commandPrefixWords.contains(word) || word == "{" || word == "("
                        if ["then", "else", "do", "elif", "if", "while", "until", "!", "time", "{"].contains(word) { expectCommand = true }
                        continue
                    }
                    let name = LineTokenizer.unquote(word)
                    let exists = knownCommands.contains(name) || (name.contains("/") && pathExists(name))
                    spans.append(HighlightSpan(range: token.range, style: exists ? .command : .invalidCommand))
                    expectCommand = LineTokenizer.commandPrefixWords.contains(name)
                } else {
                    spans.append(contentsOf: argumentSpans(token))
                }
            }
        }
        return spans
    }

    private func assignmentSpans(_ token: LineToken) -> [HighlightSpan] {
        guard let equals = token.text.firstIndex(of: "=") else { return [HighlightSpan(range: token.range, style: .assignment)] }
        let nameLength = token.text.distance(from: token.text.startIndex, to: equals) + 1
        var spans = [HighlightSpan(range: token.range.lowerBound..<(token.range.lowerBound + nameLength), style: .assignment)]
        let valueToken = LineToken(kind: .word, range: (token.range.lowerBound + nameLength)..<token.range.upperBound, text: String(token.text[token.text.index(after: equals)...]), quote: nil, unterminated: token.unterminated)
        if !valueToken.text.isEmpty { spans.append(contentsOf: argumentSpans(valueToken)) }
        return spans
    }

    private func argumentSpans(_ token: LineToken) -> [HighlightSpan] {
        let word = token.text
        if word.hasPrefix("-"), word.count > 1, token.quote == nil {
            return [HighlightSpan(range: token.range, style: .option)]
        }
        if token.quote == "'" {
            return [HighlightSpan(range: token.range, style: .string)]
        }
        // Split the word into literal, quoted and variable pieces.
        var spans: [HighlightSpan] = []
        let characters = Array(word)
        var index = 0
        var literalStart = 0
        var literal = ""
        func flushLiteral(upTo end: Int) {
            if end > literalStart {
                let style: HighlightSpan.Style = pathExists(LineTokenizer.unquote(literal)) ? .path : .argument
                spans.append(HighlightSpan(range: (token.range.lowerBound + literalStart)..<(token.range.lowerBound + end), style: style))
            }
            literal = ""
        }
        while index < characters.count {
            let ch = characters[index]
            if ch == "\\", index + 1 < characters.count {
                literal.append(contentsOf: characters[index...index + 1])
                index += 2
                continue
            }
            if ch == "'" || ch == "\"" {
                flushLiteral(upTo: index)
                let start = index
                index += 1
                while index < characters.count, characters[index] != ch {
                    if ch == "\"", characters[index] == "\\" { index += 1 }
                    index += 1
                }
                if index < characters.count { index += 1 }
                let quoted = String(characters[start..<min(index, characters.count)])
                if ch == "\"", quoted.contains("$") {
                    spans.append(contentsOf: splitVariables(in: quoted, offset: token.range.lowerBound + start, baseStyle: .string))
                } else {
                    spans.append(HighlightSpan(range: (token.range.lowerBound + start)..<(token.range.lowerBound + min(index, characters.count)), style: .string))
                }
                literalStart = index
                continue
            }
            if ch == "$" {
                flushLiteral(upTo: index)
                let start = index
                index += 1
                if index < characters.count, characters[index] == "{" {
                    while index < characters.count, characters[index] != "}" { index += 1 }
                    if index < characters.count { index += 1 }
                } else if index < characters.count, characters[index] == "(" {
                    var depth = 0
                    while index < characters.count {
                        if characters[index] == "(" { depth += 1 }
                        if characters[index] == ")" { depth -= 1; if depth == 0 { index += 1; break } }
                        index += 1
                    }
                } else if index < characters.count, "?$!#@*-0123456789".contains(characters[index]) {
                    index += 1
                } else {
                    while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                        index += 1
                    }
                }
                spans.append(HighlightSpan(range: (token.range.lowerBound + start)..<(token.range.lowerBound + index), style: .variable))
                literalStart = index
                continue
            }
            literal.append(ch)
            index += 1
        }
        flushLiteral(upTo: characters.count)
        return spans
    }

    private func splitVariables(in quoted: String, offset: Int, baseStyle: HighlightSpan.Style) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let characters = Array(quoted)
        var index = 0
        var segmentStart = 0
        while index < characters.count {
            if characters[index] == "\\" { index += 2; continue }
            if characters[index] == "$" {
                if index > segmentStart {
                    spans.append(HighlightSpan(range: (offset + segmentStart)..<(offset + index), style: baseStyle))
                }
                let start = index
                index += 1
                if index < characters.count, characters[index] == "{" {
                    while index < characters.count, characters[index] != "}" { index += 1 }
                    if index < characters.count { index += 1 }
                } else {
                    while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" { index += 1 }
                    if index == start + 1, index < characters.count, "?$!#@*-".contains(characters[index]) { index += 1 }
                }
                spans.append(HighlightSpan(range: (offset + start)..<(offset + index), style: .variable))
                segmentStart = index
                continue
            }
            index += 1
        }
        if characters.count > segmentStart {
            spans.append(HighlightSpan(range: (offset + segmentStart)..<(offset + characters.count), style: baseStyle))
        }
        return spans
    }

    /// Turns spans into styled segments covering the whole text, for the renderer.
    public static func segments(for text: [Character], spans: [HighlightSpan]) -> [StyledSegment] {
        guard !spans.isEmpty else { return [StyledSegment(String(text))] }
        var segments: [StyledSegment] = []
        var position = 0
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let lower = max(position, min(span.range.lowerBound, text.count))
            let upper = min(span.range.upperBound, text.count)
            if lower > position {
                segments.append(StyledSegment(String(text[position..<lower])))
            }
            if upper > lower {
                segments.append(StyledSegment(String(text[lower..<upper]), sgr: span.style.sgr))
                position = upper
            }
        }
        if position < text.count {
            segments.append(StyledSegment(String(text[position..<text.count])))
        }
        return segments
    }
}
