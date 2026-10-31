import Foundation

/// A prompt ready to be written to the terminal: the text may contain escape sequences, `width`
/// is the number of cells it occupies so the renderer never has to measure it.
public struct RenderedPrompt: Equatable, Sendable {
    public var text: String
    public var width: Int

    public init(text: String, width: Int) {
        self.text = text
        self.width = width
    }

    /// A prompt without escape sequences.
    public static func plain(_ text: String) -> RenderedPrompt {
        RenderedPrompt(text: text, width: ANSI.displayWidth(of: text))
    }

    public static let empty = RenderedPrompt(text: "", width: 0)
}

/// Builds prompts for the three `PromptStyle`s.
public struct PromptRenderer: Sendable {
    public var style: PromptStyle
    public var accent: RGBColor?
    public var userName: String
    public var hostName: String

    public init(style: PromptStyle, accent: RGBColor? = nil, userName: String = "mobile", hostName: String = "tern") {
        self.style = style
        self.accent = accent
        self.userName = userName
        self.hostName = hostName
    }

    /// The prompt symbol used by the `tern` style.
    public static let symbol = "\u{276F}"

    public func render(workingDirectory: String, homeDirectory: String, lastExitStatus: Int32, gitBranch: String?) -> RenderedPrompt {
        let directory = PromptRenderer.abbreviate(path: workingDirectory, home: homeDirectory)
        switch style {
        case .minimal:
            return .plain("$ ")
        case .classic:
            return .plain("\(userName)@\(hostName):\(directory)$ ")
        case .tern:
            var text = ANSI.dim + directory + ANSI.reset
            var width = ANSI.displayWidth(of: directory)
            if let branch = gitBranch, !branch.isEmpty {
                text += " " + ANSI.sgr(2, 36) + branch + ANSI.reset
                width += 1 + ANSI.displayWidth(of: branch)
            }
            let symbolColor: String
            if lastExitStatus != 0 {
                symbolColor = ANSI.Color.red.foreground
            } else if let accent {
                symbolColor = ANSI.foreground(accent)
            } else {
                symbolColor = ANSI.Color.yellow.foreground
            }
            text += " " + ANSI.bold + symbolColor + PromptRenderer.symbol + ANSI.reset + " "
            width += 3
            return RenderedPrompt(text: text, width: width)
        }
    }

    /// The continuation prompt shown while a command is incomplete.
    public func continuation() -> RenderedPrompt {
        switch style {
        case .minimal, .classic:
            return .plain("> ")
        case .tern:
            return RenderedPrompt(text: ANSI.dim + "\u{2026} " + ANSI.reset, width: 2)
        }
    }

    /// Replaces the home directory prefix with `~` and the empty path with `/`.
    public static func abbreviate(path: String, home: String) -> String {
        let normalizedHome = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if path == normalizedHome { return "~" }
        if !normalizedHome.isEmpty, path.hasPrefix(normalizedHome + "/") {
            return "~" + path.dropFirst(normalizedHome.count)
        }
        return path.isEmpty ? "/" : path
    }
}

/// Finds the current git branch by reading `.git/HEAD`, without running git.
public enum GitBranchDetector {
    /// Walks up from `directory` looking for a `.git` directory (or a `.git` file pointing at one,
    /// as used by worktrees and submodules). Returns the branch name, or a seven character
    /// abbreviated commit when HEAD is detached, or nil outside a repository.
    public static func branch(forDirectory directory: String) -> String? {
        var current = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        var depth = 0
        while depth < 64 {
            let gitURL = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                let headURL: URL
                if isDirectory.boolValue {
                    headURL = gitURL.appendingPathComponent("HEAD")
                } else if let contents = try? String(contentsOf: gitURL, encoding: .utf8),
                          let line = contents.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : current.appendingPathComponent(target)
                    headURL = gitDir.appendingPathComponent("HEAD")
                } else {
                    return nil
                }
                return parseHead(at: headURL)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    static func parseHead(at url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
            return ref
        }
        if line.count >= 7 { return String(line.prefix(7)) }
        return nil
    }
}
