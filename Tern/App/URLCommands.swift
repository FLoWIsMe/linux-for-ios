import Foundation

/// Handles `tern://` links.
///
/// `tern://run?cmd=<command>` puts the command into the line editor of the current tab without
/// running it, so a link can never execute anything behind the user's back. When the app was
/// launched with the `-ui-testing` argument (automated tests only) the command runs immediately.
/// `tern://newtab?dir=<path>` opens a tab in a directory inside the home folder.
enum URLCommands {
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") }

    /// `-ui-ssh-key <path>`: a private key the UI tests want installed as ~/.ssh/id_ed25519 so the
    /// interactive ssh test can authenticate. Only honored together with `-ui-testing`; the
    /// Simulator can read the Mac's file system, which is what makes this work.
    static var uiTestingSSHKeyPath: String? {
        guard isUITesting else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ui-ssh-key"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func handle(_ url: URL, model: AppModel) {
        guard url.scheme?.lowercased() == "tern" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch url.host?.lowercased() {
        case "run":
            guard let command = value("cmd"), !command.isEmpty, command.count < 4096 else { return }
            model.ensureSession()
            guard let session = model.selected else { return }
            if isUITesting {
                session.runCommand(command)
            } else {
                session.session.setEditorText(command)
            }
        case "newtab":
            let home = SystemEnvironment.homeDirectory
            var directory = home
            if let dir = value("dir") {
                let resolved = (dir.hasPrefix("/") ? dir : home + "/" + dir)
                let standardized = (resolved as NSString).standardizingPath
                if standardized.hasPrefix(home) { directory = standardized }
            }
            model.newSession(workingDirectory: directory)
        default:
            break
        }
    }
}
