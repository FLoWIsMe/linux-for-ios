import SwiftUI
import UIKit
import Observation
import TernCore

/// App wide state: the open sessions (tabs), which one is selected, and the shared keyboard bar model.
@Observable
@MainActor
final class AppModel {
    let settings: SettingsStore
    let keyboardBar = KeyboardBarModel()
    private(set) var sessions: [TerminalSessionController] = []
    var selectedID: UUID?
    private(set) var colorScheme: ColorScheme = .dark
    var presentedSheet: Sheet?
    var showsOnboarding: Bool
    var bellFlash = false

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private lazy var hostCommands = TernHostCommands(model: self)

    enum Sheet: String, Identifiable {
        case settings, hosts, keys, help
        var id: String { rawValue }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        self.showsOnboarding = !settings.hasCompletedOnboarding
        keyboardBar.hapticsEnabled = settings.hapticKeys
    }

    var selected: TerminalSessionController? {
        guard let selectedID else { return sessions.first }
        return sessions.first { $0.id == selectedID } ?? sessions.first
    }

    /// Creates the first tab if there is none yet. Called when the terminal screen appears.
    func ensureSession() {
        if sessions.isEmpty {
            // Automated tests can pass `-ui-command "<command>"` to run something in the first tab.
            let testCommand = URLCommands.isUITesting ? UserDefaults.standard.string(forKey: "ui-command") : nil
            newSession(initialCommand: testCommand)
        }
    }

    @discardableResult
    func newSession(workingDirectory: String? = nil, initialCommand: String? = nil) -> TerminalSessionController {
        let controller = TerminalSessionController(
            settings: settings,
            colorScheme: colorScheme,
            hostCommands: hostCommands,
            workingDirectory: workingDirectory ?? selected?.session.shell.workingDirectory,
            showWelcome: sessions.isEmpty
        )
        controller.onBell = { [weak self] in self?.ringBell() }
        controller.onExit = { [weak self] exited in self?.sessionExited(exited) }
        sessions.append(controller)
        selectedID = controller.id
        if let initialCommand {
            // Give the shell thread a moment to print its first prompt before typing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                controller.runCommand(initialCommand)
            }
        }
        return controller
    }

    func close(_ controller: TerminalSessionController) {
        guard let index = sessions.firstIndex(where: { $0.id == controller.id }) else { return }
        controller.terminate()
        sessions.remove(at: index)
        if selectedID == controller.id {
            let next = min(index, sessions.count - 1)
            selectedID = next >= 0 ? sessions[next].id : nil
        }
        if sessions.isEmpty {
            newSession()
        }
    }

    func select(_ controller: TerminalSessionController) {
        selectedID = controller.id
    }

    func selectTab(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    func selectNextTab(offset: Int) {
        guard let current = selected, let index = sessions.firstIndex(where: { $0.id == current.id }), sessions.count > 1 else { return }
        let next = (index + offset + sessions.count) % sessions.count
        selectedID = sessions[next].id
    }

    private func sessionExited(_ controller: TerminalSessionController) {
        close(controller)
    }

    // MARK: Appearance

    func update(colorScheme: ColorScheme) {
        guard colorScheme != self.colorScheme else { return }
        self.colorScheme = colorScheme
        for session in sessions { session.update(colorScheme: colorScheme) }
    }

    /// Re-applies palettes, fonts and cursor after a Settings change.
    func refreshAppearance() {
        keyboardBar.hapticsEnabled = settings.hapticKeys
        for session in sessions { session.refreshAppearance() }
    }

    func ringBell() {
        switch settings.bell {
        case .none: return
        case .haptic:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .visual:
            flash()
        case .both:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            flash()
        }
    }

    private func flash() {
        bellFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.bellFlash = false
        }
    }

    // MARK: Lifecycle

    /// Keeps commands (ssh, downloads) alive for the extra background time iOS grants when the app is sent to the background.
    func enteredBackground() {
        guard sessions.contains(where: { $0.isRunningCommand }), backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tern.command") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func enteredForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Text for `tern diagnostics`: what is embedded, how the terminal is configured, useful in bug reports.
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("Tern \(SystemEnvironment.appVersion) (\(SystemEnvironment.buildNumber))")
        lines.append("Appearance: \(settings.appearance.title), effective: \(colorScheme == .dark ? "dark" : "light")")
        lines.append("Palette: \(settings.palette(for: colorScheme).name)")
        if let selected {
            let view = selected.terminalView
            lines.append("Terminal: \(view.terminalDimensions.cols)x\(view.terminalDimensions.rows), font \(settings.font.title) \(Int(settings.fontSize))pt")
            lines.append("Renderer: \(view.isUsingMetalRenderer ? "Metal" : "Core Graphics")")
            lines.append("Native background: \(view.nativeBackgroundColor), layer: \(String(describing: view.layer.backgroundColor))")
            lines.append("Native foreground: \(view.nativeForegroundColor)")
            lines.append("Subviews: " + view.subviews.map { "\(type(of: $0))(bg: \(String(describing: $0.backgroundColor)), opaque: \($0.isOpaque))" }.joined(separator: ", "))
        }
        lines.append("Skipped frameworks: " + (SystemEnvironment.skippedFrameworks.isEmpty ? "none" : SystemEnvironment.skippedFrameworks.keys.sorted().joined(separator: ", ")))
        lines.append("Home: \(SystemEnvironment.homeDirectory)")
        return lines.joined(separator: "\n") + "\n"
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        showsOnboarding = false
    }
}
