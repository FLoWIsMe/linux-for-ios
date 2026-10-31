import Foundation

/// Persistent, de-duplicated command history shared by the line editor and the `history` builtin.
/// Thread safe. The file stores one command per line; newlines and backslashes inside a command
/// are escaped so multi line commands round trip.
public final class CommandHistory {
    public let fileURL: URL?
    public let limit: Int

    private var storage: [String] = []
    private let lock = NSLock()

    public init(fileURL: URL?, limit: Int) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        load()
    }

    /// Oldest first.
    public var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    /// Adds a command. Empty lines, lines starting with a space and repeats of the last entry are ignored.
    public func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !line.hasPrefix(" ") else { return }
        lock.lock()
        if storage.last == line {
            lock.unlock()
            return
        }
        storage.append(line)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        persist([])
    }

    /// Most recent entry that starts with `prefix` and is longer than it, for autosuggestions.
    public func suggestion(forPrefix prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        for entry in storage.reversed() where entry.hasPrefix(prefix) && entry != prefix {
            return entry
        }
        return nil
    }

    /// Entries containing `query`, most recent first.
    public func search(_ query: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !query.isEmpty else { return storage.reversed() }
        return storage.reversed().filter { $0.contains(query) }
    }

    /// Writes the history to disk now. Appends already persist, so this is only needed after `load`
    /// semantics change or before the process exits.
    public func save() {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
    }

    // MARK: Persistence

    private func load() {
        guard let url = fileURL, let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        var loaded: [String] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = CommandHistory.unescape(String(line))
            if !entry.isEmpty { loaded.append(entry) }
        }
        if loaded.count > limit { loaded.removeFirst(loaded.count - limit) }
        lock.lock()
        storage = loaded
        lock.unlock()
    }

    private func persist(_ entries: [String]) {
        guard let url = fileURL else { return }
        let text = entries.map(CommandHistory.escape).joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func escape(_ entry: String) -> String {
        var result = ""
        for character in entry {
            switch character {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r\n": result += "\\n"
            default: result.append(character)
            }
        }
        return result
    }

    static func unescape(_ line: String) -> String {
        var result = ""
        var escaped = false
        for character in line {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            result.append(character)
        }
        if escaped { result.append("\\") }
        return result
    }
}
