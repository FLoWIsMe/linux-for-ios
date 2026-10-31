import Foundation

/// Bash style brace expansion on raw (still quoted) words: `a{b,c}d`, `{1..5}`, `{a..e}`, `{1..10..3}`.
/// Braces inside quotes, escaped braces and `${...}` are left alone.
enum BraceExpansion {
    static func expand(_ word: String) -> [String] {
        let characters = Array(word)
        guard let open = firstExpandableBrace(characters) else { return [word] }
        guard let close = matchingClose(characters, from: open) else { return [word] }

        let preamble = String(characters[0..<open])
        let body = Array(characters[(open + 1)..<close])
        let postamble = String(characters[(close + 1)...])

        var alternatives: [String]
        if let sequence = expandSequence(body) {
            alternatives = sequence
        } else {
            let parts = splitTopLevelCommas(body)
            guard parts.count > 1 else { return [word] }
            alternatives = parts.map { String($0) }
        }

        var results: [String] = []
        for alternative in alternatives {
            // The postamble may contain further braces; the alternative itself may be nested.
            for expandedAlternative in expand(alternative) {
                for tail in expand(postamble) {
                    results.append(preamble + expandedAlternative + tail)
                }
            }
        }
        return results
    }

    /// Index of the first `{` that is unquoted, not preceded by `$`, and not escaped.
    private static func firstExpandableBrace(_ characters: [Character]) -> Int? {
        var index = 0
        var inSingle = false
        var inDouble = false
        while index < characters.count {
            let c = characters[index]
            if inSingle {
                if c == "'" { inSingle = false }
                index += 1
                continue
            }
            if inDouble {
                if c == "\\" { index += 2; continue }
                if c == "\"" { inDouble = false }
                index += 1
                continue
            }
            switch c {
            case "\\": index += 2
            case "'": inSingle = true; index += 1
            case "\"": inDouble = true; index += 1
            case "$":
                // skip ${...} and $(...) entirely
                if index + 1 < characters.count, characters[index + 1] == "{" || characters[index + 1] == "(" {
                    if let end = skipDollarGroup(characters, from: index + 1) {
                        index = end
                        continue
                    }
                }
                index += 1
            case "{":
                return index
            default:
                index += 1
            }
        }
        return nil
    }

    private static func skipDollarGroup(_ characters: [Character], from start: Int) -> Int? {
        let open = characters[start]
        let close: Character = open == "{" ? "}" : ")"
        var depth = 0
        var index = start
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
            if c == "\\" { index += 2; continue }
            if c == "'" { inSingle = true; index += 1; continue }
            if c == "\"" { inDouble = true; index += 1; continue }
            if c == open { depth += 1 }
            if c == close {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private static func matchingClose(_ characters: [Character], from open: Int) -> Int? {
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

    private static func splitTopLevelCommas(_ body: [Character]) -> [[Character]] {
        var parts: [[Character]] = [[]]
        var depth = 0
        var index = 0
        var inSingle = false
        var inDouble = false
        while index < body.count {
            let c = body[index]
            if inSingle {
                parts[parts.count - 1].append(c)
                if c == "'" { inSingle = false }
                index += 1
                continue
            }
            if inDouble {
                parts[parts.count - 1].append(c)
                if c == "\\", index + 1 < body.count { parts[parts.count - 1].append(body[index + 1]); index += 2; continue }
                if c == "\"" { inDouble = false }
                index += 1
                continue
            }
            switch c {
            case "\\":
                parts[parts.count - 1].append(c)
                if index + 1 < body.count { parts[parts.count - 1].append(body[index + 1]) }
                index += 2
                continue
            case "'": inSingle = true
            case "\"": inDouble = true
            case "{": depth += 1
            case "}": depth -= 1
            case ",":
                if depth == 0 {
                    parts.append([])
                    index += 1
                    continue
                }
            default: break
            }
            parts[parts.count - 1].append(c)
            index += 1
        }
        return parts
    }

    /// `1..5`, `a..e`, `10..1`, `1..10..2`, `01..10` (zero padded).
    private static func expandSequence(_ body: [Character]) -> [String]? {
        let text = String(body)
        let parts = text.components(separatedBy: "..")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var step = 1
        if parts.count == 3 {
            guard let value = Int(parts[2]), value != 0 else { return nil }
            step = abs(value)
        }
        if let start = Int(parts[0]), let end = Int(parts[1]) {
            let padding = (parts[0].hasPrefix("0") && parts[0].count > 1) || (parts[1].hasPrefix("0") && parts[1].count > 1)
                ? max(parts[0].count, parts[1].count) : 0
            var values: [Int] = []
            if start <= end {
                var value = start
                while value <= end { values.append(value); value += step }
            } else {
                var value = start
                while value >= end { values.append(value); value -= step }
            }
            guard values.count <= 100_000 else { return nil }
            return values.map { value in
                var string = String(abs(value))
                while string.count < padding - (value < 0 ? 1 : 0) { string = "0" + string }
                return value < 0 ? "-" + string : string
            }
        }
        if parts[0].count == 1, parts[1].count == 1,
           let start = parts[0].unicodeScalars.first?.value, let end = parts[1].unicodeScalars.first?.value,
           parts[0].first!.isLetter, parts[1].first!.isLetter {
            var values: [String] = []
            if start <= end {
                var value = start
                while value <= end {
                    if let scalar = Unicode.Scalar(value) { values.append(String(Character(scalar))) }
                    value += UInt32(step)
                }
            } else {
                var value = Int(start)
                while value >= Int(end) {
                    if let scalar = Unicode.Scalar(UInt32(value)) { values.append(String(Character(scalar))) }
                    value -= step
                }
            }
            return values
        }
        return nil
    }
}
