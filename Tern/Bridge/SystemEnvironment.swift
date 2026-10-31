import Foundation
import ios_system

/// One time setup of ios_system and the process environment, plus knowledge about which parts of
/// the toolchain made it into this build.
enum SystemEnvironment {
    /// `~` for everything the user does. Visible in the Files app.
    static let homeDirectory: String = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url.path
    }()

    static let libraryDirectory: String = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].path
    }()

    static let resourcePath: String = Bundle.main.resourcePath ?? Bundle.main.bundlePath

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    private static var bootstrapped = false

    /// Frameworks that the build phase could not embed (missing Simulator slices), by framework name,
    /// with the reason. Empty on device builds.
    static private(set) var skippedFrameworks: [String: String] = [:]

    /// Prepares directories, ios_system and environment variables. Safe to call more than once.
    static func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let fm = FileManager.default
        let home = homeDirectory
        for sub in [".ssh", "bin", ".config"] {
            try? fm.createDirectory(atPath: home + "/" + sub, withIntermediateDirectories: true,
                                    attributes: sub == ".ssh" ? [.posixPermissions: 0o700] : nil)
        }
        try? fm.createDirectory(atPath: libraryDirectory + "/bin", withIntermediateDirectories: true)

        loadToolchainReport()

        sideLoading = false
        joinMainThread = false
        initializeEnvironment()

        setenv("HOME", home, 1)
        setenv("SSH_HOME", home, 1)
        setenv("CURL_HOME", home, 1)
        setenv("USER", "mobile", 1)
        setenv("LOGNAME", "mobile", 1)
        setenv("SHELL", "/bin/tsh", 1)
        setenv("TERM", "xterm-256color", 1)
        setenv("COLORTERM", "truecolor", 1)
        setenv("TERM_PROGRAM", "Tern", 1)
        setenv("TERM_PROGRAM_VERSION", appVersion, 1)
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("LC_CTYPE", "UTF-8", 1)
        setenv("EDITOR", "vim", 1)
        setenv("VISUAL", "vim", 1)
        setenv("PAGER", "less", 1)
        setenv("LESS", "-R", 1)
        setenv("CLICOLOR", "1", 1)
        setenv("TZ", TimeZone.current.identifier, 1)
        setenv("TMPDIR", NSTemporaryDirectory(), 1)
        setenv("TERMINFO", resourcePath + "/terminfo", 1)
        setenv("VIMRUNTIME", resourcePath + "/vim", 1)
        setenv("VIM", resourcePath + "/vimconfig", 1)
        let caBundle = resourcePath + "/cacert.pem"
        setenv("SSL_CERT_FILE", caBundle, 1)
        setenv("CURL_CA_BUNDLE", caBundle, 1)
        setenv("GIT_SSL_CAINFO", caBundle, 1)
        setenv("REQUESTS_CA_BUNDLE", caBundle, 1)
        setenv("TERN_HOME", home, 1)
        setenv("APPDIR", resourcePath, 1)

        // Put the user's own script directories first.
        let existing = getenv("PATH").map { String(cString: $0) } ?? ""
        var components = [home + "/bin", libraryDirectory + "/bin"]
        for part in existing.split(separator: ":").map(String.init) where !components.contains(part) {
            components.append(part)
        }
        setenv("PATH", components.joined(separator: ":"), 1)

        fm.changeCurrentDirectoryPath(home)
        installDefaultDotfiles()
    }

    /// The initial exported environment handed to each new shell.
    static func shellEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }
        // Values set with setenv after launch are not reflected in ProcessInfo, read them back.
        for key in ["HOME", "PATH", "SHELL", "TERM", "COLORTERM", "LANG", "LC_CTYPE", "EDITOR", "VISUAL", "PAGER", "LESS",
                    "USER", "LOGNAME", "TZ", "TMPDIR", "TERMINFO", "VIMRUNTIME", "VIM", "SSL_CERT_FILE", "CURL_CA_BUNDLE",
                    "GIT_SSL_CAINFO", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "CLICOLOR", "SSH_HOME", "CURL_HOME", "TERN_HOME",
                    "APPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"] {
            if let value = getenv(key) {
                env[key] = String(cString: value)
            }
        }
        return env
    }

    /// Name of the framework that provides `command`, if it is one of the embedded toolchain commands.
    static func framework(providing command: String) -> String? {
        guard let dictionary = commandDictionary, let entry = dictionary[command], let library = entry.first else {
            return nil
        }
        if library == "SELF" || library == "MAIN" { return nil }
        return library.components(separatedBy: ".framework").first
    }

    /// Why `command` cannot run in this build, or nil when it can.
    static func unavailableReason(for command: String) -> String? {
        guard let framework = framework(providing: command), let reason = skippedFrameworks[framework] else {
            return nil
        }
        return reason
    }

    private static var commandDictionary: [String: [String]]? = {
        guard let url = Bundle.main.url(forResource: "commandDictionary", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String]] else {
            return nil
        }
        return plist
    }()

    private static func loadToolchainReport() {
        guard let url = Bundle.main.url(forResource: "toolchain", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skipped = json["skipped"] as? [String: String] else {
            return
        }
        skippedFrameworks = skipped
    }

    /// Creates a starter `.ternrc` and `.vimrc` so new users have something to discover and edit.
    private static func installDefaultDotfiles() {
        let fm = FileManager.default
        let ternrc = homeDirectory + "/.ternrc"
        if !fm.fileExists(atPath: ternrc) {
            let contents = """
            # Tern runs this file when a new terminal opens. Edit it with: vim ~/.ternrc
            alias git='lg2'
            alias ll='ls -lah'
            alias la='ls -A'
            alias ..='cd ..'

            """
            try? contents.write(toFile: ternrc, atomically: true, encoding: .utf8)
        }
        let vimrc = homeDirectory + "/.vimrc"
        if !fm.fileExists(atPath: vimrc) {
            let contents = """
            \" Your Vim settings. Tern ships sensible defaults in $VIM/vimrc; this file wins.
            set number
            set mouse=a

            """
            try? contents.write(toFile: vimrc, atomically: true, encoding: .utf8)
        }
    }
}
