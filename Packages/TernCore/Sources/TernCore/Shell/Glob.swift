import Foundation

/// A piece of an expanded word. Quoting decides whether characters are literal for globbing and
/// whether the text is subject to field splitting.
struct Fragment: Equatable {
    enum Kind: Equatable {
        /// Written unquoted in the source: globbed, not field split.
        case literal
        /// Quoted or escaped: never special.
        case quoted
        /// Produced by an unquoted expansion: globbed and field split.
        case expanded
    }

    var text: String
    var kind: Kind

    var isQuoted: Bool { kind == .quoted }
}

private enum PatternElement: Equatable {
    case literal(Character)
    case anyCharacter
    case anySequence
    case characterClass(negated: Bool, ranges: [ClosedRange<Character>], classes: [String])
}

/// A shell pattern (`*`, `?`, `[...]`) compiled from fragments so that quoted text stays literal.
struct GlobPattern {
    private var elements: [PatternElement] = []
    /// True when the pattern contains at least one unquoted wildcard.
    private(set) var hasWildcards = false
    /// True when the first element is a literal `.` (needed for hidden file rules).
    var startsWithDot: Bool {
        if case .literal(".") = elements.first { return true }
        return false
    }

    init(fragments: [Fragment]) {
        for fragment in fragments {
            if fragment.isQuoted {
                for character in fragment.text { elements.append(.literal(character)) }
                continue
            }
            let characters = Array(fragment.text)
            var index = 0
            while index < characters.count {
                let c = characters[index]
                switch c {
                case "*":
                    hasWildcards = true
                    // Collapse runs of stars.
                    if elements.last != .anySequence { elements.append(.anySequence) }
                    index += 1
                case "?":
                    hasWildcards = true
                    elements.append(.anyCharacter)
                    index += 1
                case "[":
                    if let (element, consumed) = GlobPattern.parseClass(characters, from: index) {
                        hasWildcards = true
                        elements.append(element)
                        index += consumed
                    } else {
                        elements.append(.literal("["))
                        index += 1
                    }
                case "\\":
                    // Escaped wildcard inside an unquoted expansion result stays literal.
                    if index + 1 < characters.count {
                        elements.append(.literal(characters[index + 1]))
                        index += 2
                    } else {
                        elements.append(.literal("\\"))
                        index += 1
                    }
                default:
                    elements.append(.literal(c))
                    index += 1
                }
            }
        }
    }

    /// Builds a pattern from a plain string where every character is literal except wildcards.
    init(unquoted text: String) {
        self.init(fragments: [Fragment(text: text, kind: .literal)])
    }

    private static func parseClass(_ characters: [Character], from start: Int) -> (PatternElement, Int)? {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }
        var ranges: [ClosedRange<Character>] = []
        var classes: [String] = []
        var first = true
        while index < characters.count {
            let c = characters[index]
            if c == "]" && !first {
                return (.characterClass(negated: negated, ranges: ranges, classes: classes), index - start + 1)
            }
            first = false
            if c == "[", index + 1 < characters.count, characters[index + 1] == ":" {
                // [:alpha:]
                var end = index + 2
                var name = ""
                while end + 1 < characters.count, !(characters[end] == ":" && characters[end + 1] == "]") {
                    name.append(characters[end])
                    end += 1
                }
                if end + 1 < characters.count {
                    classes.append(name)
                    index = end + 2
                    continue
                }
            }
            if c == "\\", index + 1 < characters.count {
                ranges.append(characters[index + 1]...characters[index + 1])
                index += 2
                continue
            }
            if index + 2 < characters.count, characters[index + 1] == "-", characters[index + 2] != "]" {
                let upper = characters[index + 2]
                if c <= upper { ranges.append(c...upper) }
                index += 3
                continue
            }
            ranges.append(c...c)
            index += 1
        }
        return nil
    }

    private static func matchesClass(_ name: String, _ c: Character) -> Bool {
        switch name {
        case "alpha": return c.isLetter
        case "digit": return c.isNumber && c.isASCII
        case "alnum": return c.isLetter || c.isNumber
        case "upper": return c.isUppercase
        case "lower": return c.isLowercase
        case "space": return c.isWhitespace
        case "blank": return c == " " || c == "\t"
        case "punct": return c.isPunctuation || c.isSymbol
        case "print": return !(c.unicodeScalars.first.map { $0.properties.generalCategory == .control } ?? false)
        case "graph": return !c.isWhitespace && !(c.unicodeScalars.first.map { $0.properties.generalCategory == .control } ?? false)
        case "cntrl": return c.unicodeScalars.first.map { $0.properties.generalCategory == .control } ?? false
        case "xdigit": return c.isHexDigit
        case "word": return c.isLetter || c.isNumber || c == "_"
        default: return false
        }
    }

    /// Full match of `text`. In `pathname` mode `*` and `?` never match `/` and wildcards do not match a
    /// leading `.` unless the pattern starts with a literal dot.
    func matches(_ text: String, pathname: Bool = false) -> Bool {
        let characters = Array(text)
        if pathname, let first = characters.first, first == ".", !startsWithDot {
            return false
        }
        return match(elements[...], characters[...], pathname: pathname)
    }

    private func match(_ pattern: ArraySlice<PatternElement>, _ text: ArraySlice<Character>, pathname: Bool) -> Bool {
        var pattern = pattern
        var text = text
        while let element = pattern.first {
            switch element {
            case .anySequence:
                let rest = pattern.dropFirst()
                if rest.isEmpty {
                    return !(pathname && text.contains("/"))
                }
                var index = text.startIndex
                while true {
                    if match(rest, text[index...], pathname: pathname) { return true }
                    if index >= text.endIndex { return false }
                    if pathname && text[index] == "/" { return false }
                    index += 1
                }
            case .anyCharacter:
                guard let c = text.first, !(pathname && c == "/") else { return false }
                pattern = pattern.dropFirst()
                text = text.dropFirst()
            case .literal(let expected):
                guard let c = text.first, c == expected else { return false }
                pattern = pattern.dropFirst()
                text = text.dropFirst()
            case .characterClass(let negated, let ranges, let classes):
                guard let c = text.first, !(pathname && c == "/") else { return false }
                var found = ranges.contains { $0.contains(c) }
                if !found { found = classes.contains { GlobPattern.matchesClass($0, c) } }
                if found == negated { return false }
                pattern = pattern.dropFirst()
                text = text.dropFirst()
            }
        }
        return text.isEmpty
    }

    /// Length of the shortest or longest prefix of `text` matched by the pattern, if any.
    func prefixMatchLength(in text: String, longest: Bool) -> Int? {
        let characters = Array(text)
        let lengths = longest ? Array((0...characters.count).reversed()) : Array(0...characters.count)
        for length in lengths where match(elements[...], characters[0..<length], pathname: false) {
            return length
        }
        return nil
    }

    /// Length of the shortest or longest suffix of `text` matched by the pattern, if any.
    func suffixMatchLength(in text: String, longest: Bool) -> Int? {
        let characters = Array(text)
        let lengths = longest ? Array((0...characters.count).reversed()) : Array(0...characters.count)
        for length in lengths where match(elements[...], characters[(characters.count - length)...], pathname: false) {
            return length
        }
        return nil
    }

    /// Range of the first match inside `text` (used by `${var/pattern/replacement}`), preferring the
    /// longest match at the earliest position.
    func firstMatchRange(in text: String) -> Range<Int>? {
        let characters = Array(text)
        for start in 0...characters.count {
            for end in (start...characters.count).reversed() where match(elements[...], characters[start..<end], pathname: false) {
                return start..<end
            }
        }
        return nil
    }
}

/// Pathname expansion against a working directory.
enum PathGlobber {
    /// Expands `fragments` as a path pattern. Returns nil when the word contains no wildcards or
    /// nothing matched (callers then use the literal word).
    static func expand(fragments: [Fragment], workingDirectory: String) -> [String]? {
        let hasWildcard = fragments.contains { fragment in
            !fragment.isQuoted && fragment.text.contains { $0 == "*" || $0 == "?" || $0 == "[" }
        }
        guard hasWildcard else { return nil }

        // Split the fragments into path components on unquoted or quoted slashes.
        var components: [[Fragment]] = [[]]
        for fragment in fragments {
            var current = ""
            for c in fragment.text {
                if c == "/" {
                    if !current.isEmpty { components[components.count - 1].append(Fragment(text: current, kind: fragment.kind)) }
                    current = ""
                    components.append([])
                } else {
                    current.append(c)
                }
            }
            if !current.isEmpty { components[components.count - 1].append(Fragment(text: current, kind: fragment.kind)) }
        }

        let absolute = fragments.first?.text.hasPrefix("/") ?? false
        var trailingSlash = false
        if components.count > 1, components.last?.isEmpty ?? false {
            components.removeLast()
            trailingSlash = true
        }
        if absolute { components.removeFirst() }

        var results: [String] = []
        let root = absolute ? "/" : workingDirectory
        walk(components: components[...], directory: root, displayPrefix: absolute ? "/" : "", results: &results, directoriesOnly: trailingSlash)
        if results.isEmpty { return nil }
        results.sort()
        if trailingSlash { results = results.map { $0 + "/" } }
        return results
    }

    private static func walk(components: ArraySlice<[Fragment]>, directory: String, displayPrefix: String, results: inout [String], directoriesOnly: Bool) {
        guard let component = components.first else {
            return
        }
        let rest = components.dropFirst()
        let fileManager = FileManager.default

        // Globstar: `**` matches zero or more directories.
        if component.count == 1, component[0].kind != .quoted, component[0].text == "**" {
            if rest.isEmpty {
                // `**` alone: everything below, recursively (files and directories).
                appendRecursive(directory: directory, displayPrefix: displayPrefix, results: &results, directoriesOnly: directoriesOnly)
            } else {
                walk(components: rest, directory: directory, displayPrefix: displayPrefix, results: &results, directoriesOnly: directoriesOnly)
            }
            for name in (try? fileManager.contentsOfDirectory(atPath: directory))?.sorted() ?? [] where !name.hasPrefix(".") {
                let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, !isSymlink(path) {
                    walk(components: components, directory: path, displayPrefix: displayPrefix + name + "/", results: &results, directoriesOnly: directoriesOnly)
                }
            }
            return
        }

        let pattern = GlobPattern(fragments: component)
        if !pattern.hasWildcards {
            let literal = component.map(\.text).joined()
            let path = directory.hasSuffix("/") ? directory + literal : directory + "/" + literal
            if rest.isEmpty {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                    if !directoriesOnly || isDirectory.boolValue { results.append(displayPrefix + literal) }
                }
            } else {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(components: rest, directory: path, displayPrefix: displayPrefix + literal + "/", results: &results, directoriesOnly: directoriesOnly)
                }
            }
            return
        }

        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted() where pattern.matches(name, pathname: true) {
            let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            if rest.isEmpty {
                if directoriesOnly {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                }
                results.append(displayPrefix + name)
            } else {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(components: rest, directory: path, displayPrefix: displayPrefix + name + "/", results: &results, directoriesOnly: directoriesOnly)
                }
            }
        }
    }

    private static func appendRecursive(directory: String, displayPrefix: String, results: inout [String], directoriesOnly: Bool) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            guard exists else { continue }
            if !directoriesOnly || isDirectory.boolValue { results.append(displayPrefix + name) }
            if isDirectory.boolValue, !isSymlink(path) {
                appendRecursive(directory: path, displayPrefix: displayPrefix + name + "/", results: &results, directoriesOnly: directoriesOnly)
            }
        }
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
