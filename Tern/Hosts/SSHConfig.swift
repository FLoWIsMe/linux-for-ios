import Foundation

/// A `Host` block from `~/.ssh/config`.
struct SSHHost: Identifiable, Equatable {
    var name: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    /// Line range of the block in the config file, for deletion.
    var lineRange: Range<Int>?

    var id: String { name }

    /// `user@hostname:port` for display.
    var summary: String {
        var text = hostName ?? name
        if let user { text = user + "@" + text }
        if let port, port != 22 { text += ":\(port)" }
        return text
    }

    var isWildcard: Bool { name.contains("*") || name.contains("?") }
}

/// Minimal reader and writer for OpenSSH client configuration files. Keeps everything it does
/// not understand intact; only appends new blocks or removes whole `Host` blocks.
enum SSHConfig {
    static var configPath: String { SystemEnvironment.homeDirectory + "/.ssh/config" }

    static func load(path: String = configPath) -> [SSHHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var current: [SSHHost] = []
        var blockStart = 0
        let lines = text.components(separatedBy: "\n")

        func closeBlock(at end: Int) {
            for var host in current {
                host.lineRange = blockStart..<end
                hosts.append(host)
            }
            current = []
        }

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = splitKeyValue(line)
            guard let key = parts.key?.lowercased() else { continue }
            let value = parts.value
            switch key {
            case "host":
                closeBlock(at: index)
                blockStart = index
                current = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { SSHHost(name: String($0)) }
            case "match":
                closeBlock(at: index)
                blockStart = index
                current = []
            case "hostname":
                for i in current.indices { current[i].hostName = value }
            case "user":
                for i in current.indices { current[i].user = value }
            case "port":
                for i in current.indices { current[i].port = Int(value) }
            case "identityfile":
                for i in current.indices { current[i].identityFile = value }
            default:
                continue
            }
        }
        closeBlock(at: lines.count)
        return hosts.filter { !$0.isWildcard }
    }

    private static func splitKeyValue(_ line: String) -> (key: String?, value: String) {
        if let equals = line.firstIndex(of: "="), !line[..<equals].contains(" ") {
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (line, "") }
        let key = String(line[..<space])
        let value = String(line[space...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// Appends a host block. Returns false if a host with that name exists.
    @discardableResult
    static func add(_ host: SSHHost, path: String = configPath) -> Bool {
        let existing = load(path: path)
        guard !existing.contains(where: { $0.name == host.name }) else { return false }
        var block = "\nHost \(host.name)\n"
        if let hostName = host.hostName, !hostName.isEmpty { block += "    HostName \(hostName)\n" }
        if let user = host.user, !user.isEmpty { block += "    User \(user)\n" }
        if let port = host.port, port != 22 { block += "    Port \(port)\n" }
        if let identity = host.identityFile, !identity.isEmpty { block += "    IdentityFile \(identity)\n" }
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += block
        return write(text, to: path)
    }

    /// Removes the whole `Host` block that defines `host`.
    @discardableResult
    static func remove(_ host: SSHHost, path: String = configPath) -> Bool {
        guard let range = host.lineRange, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        guard range.upperBound <= lines.count else { return false }
        lines.removeSubrange(range)
        // Collapse the blank line we leave behind.
        var result = lines.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return write(result, to: path)
    }

    private static func write(_ text: String, to path: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}
