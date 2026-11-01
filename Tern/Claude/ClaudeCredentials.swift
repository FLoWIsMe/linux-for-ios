import Foundation
import Security

/// The Anthropic API key, kept in the Keychain so it survives reinstalls of nothing and is never
/// written to a file the Files app can read. `claude login` stores it, `claude logout` removes it.
enum ClaudeCredentials {
    private static let service = "com.daelyndoughty.tern.anthropic"
    private static let account = "api-key"

    /// The key to use: the ANTHROPIC_API_KEY environment variable wins (so a script or `.ternrc` can
    /// set it), otherwise the one stored in the Keychain.
    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return stored
    }

    /// True when the key came from the environment rather than the Keychain (so `logout` can explain
    /// that it cannot remove it).
    static var apiKeyIsFromEnvironment: Bool {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return true }
        return false
    }

    static var stored: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    @discardableResult
    static func store(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Model and endpoint settings for `claude`, kept as small files under ~/.config/claude so they are
/// easy to see and edit. Each can also be overridden by an environment variable.
enum ClaudeConfig {
    static let defaultModel = "claude-sonnet-5"
    static let defaultBaseURL = "https://api.anthropic.com"

    private static var configDirectory: String { SystemEnvironment.homeDirectory + "/.config/claude" }

    static var model: String {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"], !env.isEmpty { return env }
        return readFile("model") ?? defaultModel
    }

    static func setModel(_ model: String) {
        writeFile("model", model)
    }

    static var baseURL: String {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"], !env.isEmpty {
            return env.hasSuffix("/") ? String(env.dropLast()) : env
        }
        let stored = readFile("base-url") ?? defaultBaseURL
        return stored.hasSuffix("/") ? String(stored.dropLast()) : stored
    }

    private static func readFile(_ name: String) -> String? {
        let path = configDirectory + "/" + name
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeFile(_ name: String, _ value: String) {
        try? FileManager.default.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
        try? (value + "\n").write(toFile: configDirectory + "/" + name, atomically: true, encoding: .utf8)
    }
}
