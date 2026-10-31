import Foundation

/// One possible completion for the word under the cursor.
public struct CompletionCandidate: Equatable {
    public enum Kind: Equatable {
        case command, file, directory, variable, host, subcommand, option, custom
    }

    /// Replacement for the whole word, already escaped or quoted as needed.
    public var text: String
    /// What the listing shows (a directory shows a trailing slash).
    public var display: String
    /// Appended when this is the only candidate: a space after commands and files, nothing after directories.
    public var suffix: String
    public var kind: Kind

    public init(text: String, display: String? = nil, suffix: String = " ", kind: Kind) {
        self.text = text
        self.display = display ?? text
        self.suffix = suffix
        self.kind = kind
    }
}

/// Everything a provider needs to decide what to offer.
public struct CompletionContext {
    public var line: String
    /// Character offset of the cursor.
    public var cursor: Int
    /// Range of the word being completed (up to the cursor).
    public var wordRange: Range<Int>
    /// Raw text of the word up to the cursor, quotes and escapes included.
    public var word: String
    public var isCommandPosition: Bool
    /// Unquoted name of the command whose argument is being completed.
    public var commandName: String?
    /// 0 for the command itself, 1 for its first argument and so on.
    public var argumentIndex: Int
    public var previousWord: String?
    public var snapshot: ShellSnapshot

    public init(line: String, cursor: Int, wordRange: Range<Int>, word: String, isCommandPosition: Bool, commandName: String?, argumentIndex: Int, previousWord: String?, snapshot: ShellSnapshot) {
        self.line = line
        self.cursor = cursor
        self.wordRange = wordRange
        self.word = word
        self.isCommandPosition = isCommandPosition
        self.commandName = commandName
        self.argumentIndex = argumentIndex
        self.previousWord = previousWord
        self.snapshot = snapshot
    }
}

/// Lets the app add completions (for example the `tern` command's subcommands). Return nil when the
/// context is not yours so the built in rules run.
public protocol CompletionProvider: AnyObject {
    func completions(for context: CompletionContext) -> [CompletionCandidate]?
}

public struct CompletionResult: Equatable {
    public var candidates: [CompletionCandidate]
    public var wordRange: Range<Int>
    /// The raw word that was completed.
    public var word: String
    /// Longest common prefix of all candidate texts.
    public var commonPrefix: String

    public static let none = CompletionResult(candidates: [], wordRange: 0..<0, word: "", commonPrefix: "")
}

/// Computes completion candidates for a command line.
public final class CompletionEngine {
    public var providers: [CompletionProvider]

    public init(providers: [CompletionProvider] = []) {
        self.providers = providers
    }

    public static let gitSubcommands: [String] = [
        "add", "branch", "checkout", "clone", "commit", "config", "diff", "fetch", "init", "log", "merge",
        "pull", "push", "rebase", "remote", "reset", "show", "stash", "status", "tag",
    ]

    public static let hostCommands: Set<String> = ["ssh", "scp", "sftp", "ping", "ping6", "telnet", "nc", "ssh-copy-id", "rsync"]
    public static let directoryOnlyCommands: Set<String> = ["cd", "pushd", "rmdir", "chdir"]

    public static let optionTable: [String: [String]] = [
        "ls": ["-a", "-l", "-h", "-R", "-t", "-S", "-r", "-1", "-G", "-F", "-d", "-A", "--help"],
        "grep": ["-i", "-v", "-n", "-r", "-R", "-E", "-F", "-l", "-c", "-w", "-x", "-A", "-B", "-C", "-o", "-q", "--color", "--include", "--exclude"],
        "find": ["-name", "-iname", "-type", "-path", "-maxdepth", "-mindepth", "-newer", "-size", "-exec", "-delete", "-print", "-empty"],
        "tar": ["-c", "-x", "-t", "-v", "-f", "-z", "-j", "-J", "-C", "--exclude", "--strip-components"],
        "curl": ["-o", "-O", "-L", "-s", "-S", "-v", "-I", "-H", "-d", "-X", "-u", "-k", "--data", "--header", "--output", "--silent", "--location", "--fail", "--retry", "--json"],
        "ssh": ["-p", "-i", "-l", "-L", "-R", "-D", "-N", "-T", "-t", "-v", "-o", "-J", "-A", "-C", "-4", "-6"],
        "scp": ["-r", "-p", "-P", "-i", "-C", "-q", "-v", "-o"],
        "sftp": ["-P", "-i", "-r", "-b", "-o"],
        "rm": ["-r", "-R", "-f", "-i", "-v", "-d"],
        "cp": ["-r", "-R", "-p", "-a", "-f", "-i", "-v", "-n"],
        "mv": ["-f", "-i", "-n", "-v"],
        "mkdir": ["-p", "-v", "-m"],
        "git": ["--help", "--version"],
        "lg2": ["--help", "--version"],
        "vim": ["-R", "-n", "-u", "-c", "-p", "-o", "-O", "+"],
        "sed": ["-e", "-i", "-n", "-E", "-f"],
        "awk": ["-F", "-v", "-f"],
        "sort": ["-r", "-n", "-u", "-k", "-t", "-f", "-h"],
        "head": ["-n", "-c"],
        "tail": ["-n", "-c", "-f"],
        "wc": ["-l", "-w", "-c", "-m"],
        "du": ["-h", "-s", "-a", "-d"],
        "chmod": ["-R", "-v"],
        "python3": ["-m", "-c", "-i", "-u", "-V"],
    ]

    public func complete(line: String, cursor: Int, snapshot: ShellSnapshot) -> CompletionResult {
        let context = CompletionEngine.context(line: line, cursor: cursor, snapshot: snapshot)
        var candidates: [CompletionCandidate] = []
        var handled = false
        for provider in providers {
            if let result = provider.completions(for: context) {
                candidates = result
                handled = true
                break
            }
        }
        if !handled {
            candidates = builtInCandidates(for: context)
        }
        candidates = CompletionEngine.deduplicated(candidates)
        return CompletionResult(
            candidates: candidates,
            wordRange: context.wordRange,
            word: context.word,
            commonPrefix: CompletionEngine.commonPrefix(of: candidates.map(\.text))
        )
    }

    // MARK: Context

    public static func context(line: String, cursor: Int, snapshot: ShellSnapshot) -> CompletionContext {
        let characters = Array(line)
        let cursor = min(max(0, cursor), characters.count)
        let prefixLine = String(characters[0..<cursor])
        let tokens = LineTokenizer.tokenize(prefixLine)

        var wordRange = cursor..<cursor
        var word = ""
        var wordTokenIndex: Int? = nil
        if let last = tokens.last, last.kind == .word, last.range.upperBound == cursor {
            wordRange = last.range
            word = last.text
            wordTokenIndex = tokens.count - 1
        }

        // Find the start of the current simple command.
        var commandStart = 0
        let searchEnd = wordTokenIndex ?? tokens.count
        for index in 0..<searchEnd {
            let token = tokens[index]
            if token.kind == .operatorToken, !token.text.contains(">"), !token.text.contains("<") {
                commandStart = index + 1
            }
        }
        var words: [LineToken] = []
        for index in commandStart..<searchEnd where tokens[index].kind == .word {
            words.append(tokens[index])
        }
        // Skip leading assignments and command prefixes such as sudo or exec.
        var skipped = 0
        while skipped < words.count {
            let text = LineTokenizer.unquote(words[skipped].text)
            if LineTokenizer.isAssignment(words[skipped].text) || LineTokenizer.commandPrefixWords.contains(text) {
                skipped += 1
            } else {
                break
            }
        }
        let commandWords = Array(words[skipped...])
        let isCommandPosition = commandWords.isEmpty
        let commandName = commandWords.first.map { LineTokenizer.unquote($0.text) }
        let previousWord = words.last.map { LineTokenizer.unquote($0.text) }
        let argumentIndex = commandWords.count

        return CompletionContext(
            line: line,
            cursor: cursor,
            wordRange: wordRange,
            word: word,
            isCommandPosition: isCommandPosition,
            commandName: commandName,
            argumentIndex: argumentIndex,
            previousWord: previousWord,
            snapshot: snapshot
        )
    }

    // MARK: Built in rules

    func builtInCandidates(for context: CompletionContext) -> [CompletionCandidate] {
        let word = context.word
        let snapshot = context.snapshot

        if word.hasPrefix("$") {
            return variableCandidates(word: word, snapshot: snapshot)
        }

        if context.isCommandPosition {
            if word.contains("/") || word.hasPrefix("~") {
                return fileCandidates(word: word, snapshot: snapshot, directoriesOnly: false, executablesOnly: true)
            }
            return snapshot.allCommandNames
                .filter { $0.hasPrefix(word) }
                .sorted()
                .map { CompletionCandidate(text: $0, kind: .command) }
        }

        let command = context.commandName ?? ""

        if word.hasPrefix("-"), !word.hasPrefix("-/") {
            if let options = CompletionEngine.optionTable[command] {
                return options.filter { $0.hasPrefix(word) }.sorted().map { CompletionCandidate(text: $0, kind: .option) }
            }
            return []
        }

        if ["git", "lg2"].contains(command), context.argumentIndex == 1 {
            return CompletionEngine.gitSubcommands.filter { $0.hasPrefix(word) }.map { CompletionCandidate(text: $0, kind: .subcommand) }
        }

        if CompletionEngine.hostCommands.contains(command), !word.contains("/"), !word.contains(":") {
            let hosts = hostCandidates(word: word, homeDirectory: snapshot.homeDirectory)
            if !hosts.isEmpty || command == "ssh" || command == "ping" || command == "ping6" || command == "telnet" {
                return hosts
            }
        }

        let directoriesOnly = CompletionEngine.directoryOnlyCommands.contains(command)
        return fileCandidates(word: word, snapshot: snapshot, directoriesOnly: directoriesOnly, executablesOnly: false)
    }

    func variableCandidates(word: String, snapshot: ShellSnapshot) -> [CompletionCandidate] {
        var prefix = String(word.dropFirst())
        let braced = prefix.hasPrefix("{")
        if braced { prefix.removeFirst() }
        var names = Set(snapshot.variableNames)
        names.formUnion(snapshot.environment.keys)
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { name in
                let text = braced ? "${\(name)}" : "$\(name)"
                return CompletionCandidate(text: text, display: name, suffix: "", kind: .variable)
            }
    }

    func hostCandidates(word: String, homeDirectory: String) -> [CompletionCandidate] {
        var userPrefix = ""
        var hostPrefix = word
        if let at = word.lastIndex(of: "@") {
            userPrefix = String(word[...at])
            hostPrefix = String(word[word.index(after: at)...])
        }
        let hosts = CompletionEngine.knownHosts(homeDirectory: homeDirectory)
        return hosts
            .filter { $0.hasPrefix(hostPrefix) }
            .sorted()
            .map { CompletionCandidate(text: userPrefix + $0, display: $0, kind: .host) }
    }

    /// Host names from `~/.ssh/config` (Host entries without wildcards) and `~/.ssh/known_hosts` (plain entries).
    public static func knownHosts(homeDirectory: String) -> [String] {
        var hosts = Set<String>()
        let sshDirectory = homeDirectory + "/.ssh"
        if let config = try? String(contentsOfFile: sshDirectory + "/config", encoding: .utf8) {
            for rawLine in config.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.lowercased().hasPrefix("host "), !line.hasPrefix("#") else { continue }
                let names = line.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" })
                for name in names where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                    hosts.insert(String(name))
                }
            }
        }
        if let known = try? String(contentsOfFile: sshDirectory + "/known_hosts", encoding: .utf8) {
            for rawLine in known.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("|"), !line.hasPrefix("@") else { continue }
                guard let field = line.split(separator: " ").first else { continue }
                for entry in field.split(separator: ",") {
                    var host = String(entry)
                    if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                        host = String(host[host.index(after: host.startIndex)..<close])
                    }
                    if !host.isEmpty { hosts.insert(host) }
                }
            }
        }
        return Array(hosts)
    }

    func fileCandidates(word: String, snapshot: ShellSnapshot, directoriesOnly: Bool, executablesOnly: Bool) -> [CompletionCandidate] {
        var quote: Character? = nil
        var raw = word
        if let first = raw.first, first == "\"" || first == "'" {
            quote = first
            raw.removeFirst()
        }
        let unquoted = quote == nil ? LineTokenizer.unquote(raw) : raw

        // Split into the directory the user typed and the partial name.
        var typedDirectory = ""
        var partial = unquoted
        if let slash = unquoted.lastIndex(of: "/") {
            typedDirectory = String(unquoted[...slash])
            partial = String(unquoted[unquoted.index(after: slash)...])
        }

        var lookupDirectory = typedDirectory
        if lookupDirectory.isEmpty {
            lookupDirectory = snapshot.workingDirectory
        } else if lookupDirectory == "~" || lookupDirectory.hasPrefix("~/") {
            lookupDirectory = snapshot.homeDirectory + lookupDirectory.dropFirst(1)
        } else if !lookupDirectory.hasPrefix("/") {
            lookupDirectory = snapshot.workingDirectory + "/" + lookupDirectory
        }
        if unquoted == "~" {
            return [CompletionCandidate(text: "~/", display: "~/", suffix: "", kind: .directory)]
        }

        let url = URL(fileURLWithPath: lookupDirectory)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isExecutableKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        let showHidden = partial.hasPrefix(".")
        var candidates: [CompletionCandidate] = []
        var fallback: [CompletionCandidate] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if !showHidden, name.hasPrefix(".") { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                var resolvedIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: entry.resolvingSymlinksInPath().path, isDirectory: &resolvedIsDirectory) {
                    isDirectory = resolvedIsDirectory.boolValue
                }
            }
            if directoriesOnly, !isDirectory { continue }
            if executablesOnly, !isDirectory, values?.isExecutable != true, !CompletionEngine.looksLikeScript(entry) { continue }

            let display = isDirectory ? name + "/" : name
            let replacement: String
            if let quote {
                replacement = String(quote) + typedDirectory + name + (isDirectory ? "/" : String(quote))
            } else {
                replacement = LineTokenizer.escape(typedDirectory) + LineTokenizer.escape(name) + (isDirectory ? "/" : "")
            }
            let candidate = CompletionCandidate(text: replacement, display: display, suffix: isDirectory ? "" : " ", kind: isDirectory ? .directory : .file)
            if name.hasPrefix(partial) {
                candidates.append(candidate)
            } else if partial.isEmpty == false, name.lowercased().hasPrefix(partial.lowercased()) {
                fallback.append(candidate)
            }
        }
        let chosen = candidates.isEmpty ? fallback : candidates
        return chosen.sorted { $0.display.localizedStandardCompare($1.display) == .orderedAscending }
    }

    static func looksLikeScript(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 2)
        return data == Data([0x23, 0x21])
    }

    static func deduplicated(_ candidates: [CompletionCandidate]) -> [CompletionCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.text).inserted }
    }

    public static func commonPrefix(of strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for string in strings.dropFirst() {
            while !string.hasPrefix(prefix) {
                prefix.removeLast()
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    /// Formats candidates in columns the way bash lists them. Returns at most `maxRows` rows plus a summary line.
    public static func formatListing(_ candidates: [CompletionCandidate], columns: Int, maxRows: Int = 8) -> [String] {
        let names = candidates.map(\.display)
        guard !names.isEmpty else { return [] }
        let widest = names.map { ANSI.displayWidth(of: $0) }.max() ?? 1
        let cellWidth = widest + 2
        let perRow = max(1, columns / cellWidth)
        let totalRows = (names.count + perRow - 1) / perRow
        var lines: [String] = []
        func padded(_ name: String, last: Bool) -> String {
            last ? name : name + String(repeating: " ", count: max(1, cellWidth - ANSI.displayWidth(of: name)))
        }
        if totalRows <= maxRows {
            // Column major order like bash: fill down the first column, then the next.
            for row in 0..<totalRows {
                var line = ""
                var column = 0
                while column * totalRows + row < names.count {
                    let index = column * totalRows + row
                    let isLast = (column + 1) * totalRows + row >= names.count
                    line += padded(names[index], last: isLast)
                    column += 1
                }
                lines.append(line)
            }
            return lines
        }
        // Too many to show: row major order for the first rows, then a summary.
        let shownCount = min(names.count, maxRows * perRow)
        for row in 0..<maxRows {
            var line = ""
            for column in 0..<perRow {
                let index = row * perRow + column
                if index >= shownCount { break }
                let isLast = column == perRow - 1 || index == shownCount - 1
                line += padded(names[index], last: isLast)
            }
            lines.append(line)
        }
        lines.append("... and \(names.count - shownCount) more")
        return lines
    }
}
