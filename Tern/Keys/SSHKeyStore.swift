import Foundation
import CryptoKit

/// A key pair in `~/.ssh`: the private file plus its `.pub` sibling.
struct SSHKey: Identifiable, Equatable {
    var name: String
    var type: String
    var comment: String
    var publicKey: String
    var fingerprint: String
    var hasPrivateKey: Bool

    var id: String { name }
    var privatePath: String { SystemEnvironment.homeDirectory + "/.ssh/" + name }
    var publicPath: String { privatePath + ".pub" }

    var typeTitle: String {
        switch type {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return "ECDSA"
        default: return type
        }
    }
}

enum SSHKeyStore {
    static var directory: String { SystemEnvironment.homeDirectory + "/.ssh" }

    static func load() -> [SSHKey] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var keys: [SSHKey] = []
        for entry in entries where entry.hasSuffix(".pub") {
            let name = String(entry.dropLast(4))
            guard let text = try? String(contentsOfFile: directory + "/" + entry, encoding: .utf8) else { continue }
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            let blob = Data(base64Encoded: parts[1]) ?? Data()
            let digest = SHA256.hash(data: blob)
            let fingerprint = "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
            keys.append(SSHKey(
                name: name,
                type: parts[0],
                comment: parts.count > 2 ? parts[2] : "",
                publicKey: text.trimmingCharacters(in: .whitespacesAndNewlines),
                fingerprint: fingerprint,
                hasPrivateKey: fm.fileExists(atPath: directory + "/" + name)
            ))
        }
        return keys.sorted { $0.name < $1.name }
    }

    static func delete(_ key: SSHKey) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: key.privatePath)
        try? fm.removeItem(atPath: key.publicPath)
    }

    /// Writes a pasted private key with the right permissions. The public half is derived by the
    /// caller with `ssh-keygen -y`.
    static func importPrivateKey(_ text: String, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory + "/" + name
        var contents = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contents.hasSuffix("\n") { contents += "\n" }
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// The command that creates a key pair; it runs in the terminal so the user sees what happened.
    static func generateCommand(name: String, type: KeyType, comment: String, passphrase: String) -> String {
        var command = "ssh-keygen -t \(type.rawValue)"
        if type == .rsa { command += " -b 4096" }
        command += " -f ~/.ssh/\(shellQuote(name))"
        command += " -N \(shellQuote(passphrase))"
        if !comment.isEmpty { command += " -C \(shellQuote(comment))" }
        return command
    }

    static func shellQuote(_ text: String) -> String {
        if text.isEmpty { return "''" }
        if text.range(of: "^[A-Za-z0-9._/@:=+-]+$", options: .regularExpression) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum KeyType: String, CaseIterable, Identifiable {
        case ed25519, rsa, ecdsa
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ed25519: return "Ed25519 (recommended)"
            case .rsa: return "RSA 4096"
            case .ecdsa: return "ECDSA"
            }
        }
        var defaultFileName: String {
            switch self {
            case .ed25519: return "id_ed25519"
            case .rsa: return "id_rsa"
            case .ecdsa: return "id_ecdsa"
            }
        }
    }
}
