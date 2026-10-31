import UIKit
import SwiftUI
import Observation
import SwiftTerm
import TernCore

/// One tab: a SwiftTerm view, a shell session, and the executor that runs commands with ios_system.
///
/// The controller owns the `TerminalView` for the life of the tab so switching tabs never loses
/// scrollback. Bytes from the session arrive on a background thread and go straight into
/// `TerminalView.feed`, which is thread safe; everything else happens on the main thread.
@Observable
@MainActor
final class TerminalSessionController: NSObject, Identifiable {
    let id = UUID()
    let terminalView: TerminalView
    let session: ShellSession
    let executor: IOSSystemExecutor

    private(set) var title: String = "~"
    private(set) var mode: SessionInputMode = .prompt
    private(set) var runningCommand: String?
    private(set) var hasExited = false
    private(set) var exitStatus: Int32 = 0
    private(set) var colorScheme: ColorScheme

    @ObservationIgnored var onBell: (() -> Void)?
    @ObservationIgnored var onExit: ((TerminalSessionController) -> Void)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(settings: SettingsStore, colorScheme: ColorScheme, hostCommands: HostCommandProvider, workingDirectory: String? = nil,
         showWelcome: Bool) {
        self.settings = settings
        self.colorScheme = colorScheme

        var options = TerminalOptions.default
        options.convertEol = true
        options.termName = "xterm-256color"
        options.scrollback = 10_000
        options.cursorStyle = settings.cursorShape.swiftTermStyle(blinking: settings.cursorBlinks)
        let font = settings.font.uiFont(size: settings.fontSize)
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), font: font, options: options)

        let sessionName = "tern-" + id.uuidString
        executor = IOSSystemExecutor(sessionName: sessionName)

        let palette = settings.palette(for: colorScheme)
        let home = SystemEnvironment.homeDirectory
        let configuration = ShellSessionConfiguration(
            homeDirectory: home,
            workingDirectory: workingDirectory ?? home,
            environment: SystemEnvironment.shellEnvironment(),
            historyFileURL: URL(fileURLWithPath: home + "/.tern_history"),
            startupScriptURL: URL(fileURLWithPath: home + "/.ternrc"),
            promptStyle: settings.promptStyle,
            autosuggestions: settings.autosuggestions,
            syntaxHighlighting: settings.syntaxHighlighting,
            welcomeMessage: showWelcome ? TerminalSessionController.welcomeMessage(settings: settings) : nil,
            terminalSize: TerminalSize(columns: 80, rows: 24),
            accentColor: palette.cursor.shellColor,
            userName: "mobile",
            hostName: "tern"
        )
        session = ShellSession(configuration: configuration, executor: executor, output: TerminalOutputBridge(view: terminalView))
        super.init()

        executor.session = session
        session.delegate = self
        session.hostCommands = hostCommands
        terminalView.terminalDelegate = self
        terminalView.optionAsMetaKey = settings.optionAsMeta
        terminalView.allowMouseReporting = true
        terminalView.bellStyle = .sound
        terminalView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        terminalView.autocorrectionType = .no
        terminalView.autocapitalizationType = .none
        terminalView.smartQuotesType = .no
        terminalView.smartDashesType = .no
        terminalView.smartInsertDeleteType = .no
        terminalView.spellCheckingType = .no
        applyPalette(palette)
        applyFont()
        title = "~"
        session.start()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static func welcomeMessage(settings: SettingsStore) -> String? {
        guard settings.welcomeTips else { return nil }
        return "Tern \(SystemEnvironment.appVersion). Type \u{1b}[1mhelp\u{1b}[0m for a tour, \u{1b}[1mtern\u{1b}[0m to change themes."
    }

    // MARK: Appearance

    func update(colorScheme: ColorScheme) {
        guard colorScheme != self.colorScheme else { return }
        self.colorScheme = colorScheme
        terminalView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        applyPalette(settings.palette(for: colorScheme))
    }

    func refreshAppearance() {
        applyPalette(settings.palette(for: colorScheme))
        applyFont()
        terminalView.setCursorStyle(settings.cursorShape.swiftTermStyle(blinking: settings.cursorBlinks))
        terminalView.optionAsMetaKey = settings.optionAsMeta
    }

    private func applyPalette(_ palette: TerminalPalette) {
        terminalView.installColors(palette.swiftTermColors)
        terminalView.nativeBackgroundColor = palette.background.uiColor
        terminalView.nativeForegroundColor = palette.foreground.uiColor
        terminalView.caretColor = palette.cursor.uiColor
        terminalView.selectedTextBackgroundColor = palette.selection.uiColor
        terminalView.backgroundColor = palette.background.uiColor
        terminalView.updateColorScheme(palette.isDark ? .dark : .light)
    }

    private func applyFont() {
        let size = CGFloat(settings.fontSize)
        terminalView.setFonts(
            normal: settings.font.uiFont(size: size),
            bold: settings.font.boldFont(size: size),
            italic: settings.font.italicFont(size: size),
            boldItalic: settings.font.boldItalicFont(size: size)
        )
    }

    // MARK: Input helpers used by the keyboard bar and menus

    func send(_ bytes: [UInt8]) {
        session.handleInput(bytes)
    }

    func send(text: String) {
        session.handleInput(Array(text.utf8))
    }

    func paste(_ text: String) {
        session.paste(text)
    }

    func interrupt() { session.interrupt() }
    func sendEndOfFile() { session.sendEndOfFile() }
    func clearScreen() { session.clearScreen() }

    func runCommand(_ line: String) {
        session.submit(line)
    }

    func focus() {
        _ = terminalView.becomeFirstResponder()
    }

    func terminate() {
        session.terminate()
    }

    var isRunningCommand: Bool { runningCommand != nil }
}

// MARK: - TerminalViewDelegate

extension TerminalSessionController: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let size = TerminalSize(columns: newCols, rows: newRows)
        executor.setWindowSize(size)
        session.resize(size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.handleInput(Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            return
        }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {
        onBell?()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        UIPasteboard.general.string?.data(using: .utf8)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - ShellSessionDelegate

extension TerminalSessionController: ShellSessionDelegate {
    nonisolated func session(_ session: ShellSession, didChangeMode mode: SessionInputMode) {
        Task { @MainActor in
            self.mode = mode
        }
    }

    nonisolated func session(_ session: ShellSession, didChangeDirectory path: String) {
        let name = TerminalSessionController.displayName(forDirectory: path)
        Task { @MainActor in
            if self.runningCommand == nil { self.title = name }
        }
    }

    nonisolated func session(_ session: ShellSession, didChangeTitle title: String) {
        Task { @MainActor in
            self.title = title
        }
    }

    nonisolated func session(_ session: ShellSession, didStartCommand argv: [String]) {
        let name = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        Task { @MainActor in
            self.runningCommand = name
            self.title = name
            if self.settings.keepAwakeWhileRunning {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    nonisolated func session(_ session: ShellSession, didFinishCommand argv: [String], status: Int32) {
        Task { @MainActor in
            self.runningCommand = nil
            self.title = TerminalSessionController.displayName(forDirectory: session.shell.workingDirectory)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    nonisolated func sessionDidRequestBell(_ session: ShellSession) {
        Task { @MainActor in
            self.onBell?()
        }
    }

    nonisolated func sessionDidExit(_ session: ShellSession, status: Int32) {
        Task { @MainActor in
            self.hasExited = true
            self.exitStatus = status
            UIApplication.shared.isIdleTimerDisabled = false
            self.onExit?(self)
        }
    }

    nonisolated static func displayName(forDirectory path: String) -> String {
        let home = SystemEnvironment.homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + (path as NSString).lastPathComponent
        }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// Forwards session output to the terminal view. Kept separate so the controller does not have to
/// be reachable from the drain thread.
final class TerminalOutputBridge: TerminalOutputSink {
    private let view: TerminalView
    init(view: TerminalView) { self.view = view }

    func terminalWrite(_ bytes: [UInt8]) {
        view.feed(byteArray: bytes[...])
    }
}
