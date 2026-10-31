import Foundation
import SwiftUI
import Observation
import TernCore

/// User preferences, persisted in UserDefaults. One instance lives in the environment.
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        darkPaletteID = defaults.string(forKey: Keys.darkPalette) ?? TerminalPalette.ternDark.id
        lightPaletteID = defaults.string(forKey: Keys.lightPalette) ?? TerminalPalette.ternLight.id
        font = TerminalFont(rawValue: defaults.string(forKey: Keys.font) ?? "") ?? .sfMono
        let storedSize = defaults.double(forKey: Keys.fontSize)
        fontSize = storedSize > 0 ? storedSize : (UIDevice.current.userInterfaceIdiom == .pad ? 14 : 13)
        cursorShape = CursorShape(rawValue: defaults.string(forKey: Keys.cursorShape) ?? "") ?? .block
        cursorBlinks = SettingsStore.bool(Keys.cursorBlinks, in: defaults, default: true)
        promptStyle = PromptStyle(rawValue: defaults.string(forKey: Keys.promptStyle) ?? "") ?? .tern
        autosuggestions = SettingsStore.bool(Keys.autosuggestions, in: defaults, default: true)
        syntaxHighlighting = SettingsStore.bool(Keys.syntaxHighlighting, in: defaults, default: true)
        keyboardBarEnabled = SettingsStore.bool(Keys.keyboardBar, in: defaults, default: true)
        hapticKeys = SettingsStore.bool(Keys.hapticKeys, in: defaults, default: true)
        bell = BellBehavior(rawValue: defaults.string(forKey: Keys.bell) ?? "") ?? .haptic
        keepAwakeWhileRunning = SettingsStore.bool(Keys.keepAwake, in: defaults, default: true)
        optionAsMeta = SettingsStore.bool(Keys.optionAsMeta, in: defaults, default: true)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingDone)
        welcomeTips = SettingsStore.bool(Keys.welcomeTips, in: defaults, default: true)
    }

    /// Reads a Bool that may have been set as a real Bool or, from a launch argument such as
    /// `-terminal.cursorBlinks NO`, as a string.
    private static func bool(_ key: String, in defaults: UserDefaults, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    var darkPaletteID: String { didSet { defaults.set(darkPaletteID, forKey: Keys.darkPalette) } }
    var lightPaletteID: String { didSet { defaults.set(lightPaletteID, forKey: Keys.lightPalette) } }
    var font: TerminalFont { didSet { defaults.set(font.rawValue, forKey: Keys.font) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    var cursorShape: CursorShape { didSet { defaults.set(cursorShape.rawValue, forKey: Keys.cursorShape) } }
    var cursorBlinks: Bool { didSet { defaults.set(cursorBlinks, forKey: Keys.cursorBlinks) } }
    var promptStyle: PromptStyle { didSet { defaults.set(promptStyle.rawValue, forKey: Keys.promptStyle) } }
    var autosuggestions: Bool { didSet { defaults.set(autosuggestions, forKey: Keys.autosuggestions) } }
    var syntaxHighlighting: Bool { didSet { defaults.set(syntaxHighlighting, forKey: Keys.syntaxHighlighting) } }
    var keyboardBarEnabled: Bool { didSet { defaults.set(keyboardBarEnabled, forKey: Keys.keyboardBar) } }
    var hapticKeys: Bool { didSet { defaults.set(hapticKeys, forKey: Keys.hapticKeys) } }
    var bell: BellBehavior { didSet { defaults.set(bell.rawValue, forKey: Keys.bell) } }
    var keepAwakeWhileRunning: Bool { didSet { defaults.set(keepAwakeWhileRunning, forKey: Keys.keepAwake) } }
    var optionAsMeta: Bool { didSet { defaults.set(optionAsMeta, forKey: Keys.optionAsMeta) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboardingDone) } }
    var welcomeTips: Bool { didSet { defaults.set(welcomeTips, forKey: Keys.welcomeTips) } }

    static let fontSizeRange: ClosedRange<Double> = 9...24

    /// The palette to draw the terminal with for the given effective color scheme.
    func palette(for scheme: ColorScheme) -> TerminalPalette {
        let id = scheme == .dark ? darkPaletteID : lightPaletteID
        return TerminalPalette.named(id) ?? (scheme == .dark ? .ternDark : .ternLight)
    }

    func setPalette(_ palette: TerminalPalette) {
        if palette.isDark {
            darkPaletteID = palette.id
        } else {
            lightPaletteID = palette.id
        }
    }

    /// Applies a `tern theme ...` or `tern font ...` command. Returns a message for the terminal.
    @discardableResult
    func apply(command: [String]) -> String {
        guard let verb = command.first else { return usage }
        switch verb {
        case "theme":
            guard command.count > 1 else {
                let dark = palette(for: .dark).name
                let light = palette(for: .light).name
                return "Appearance: \(appearance.title). Dark palette: \(dark). Light palette: \(light).\nPalettes: " + TerminalPalette.all.map(\.id).joined(separator: ", ")
            }
            let value = command[1].lowercased()
            if let appearance = Appearance(rawValue: value) {
                self.appearance = appearance
                return "Appearance set to \(appearance.title)."
            }
            if let palette = TerminalPalette.named(value) {
                setPalette(palette)
                return "\(palette.isDark ? "Dark" : "Light") palette set to \(palette.name)."
            }
            return "Unknown theme '\(command[1])'. Use system, light, dark, or a palette id: " + TerminalPalette.all.map(\.id).joined(separator: ", ")
        case "font":
            guard command.count > 1 else { return "Font: \(font.title) \(Int(fontSize))pt. Fonts: " + TerminalFont.allCases.map(\.rawValue).joined(separator: ", ") }
            if let size = Double(command[1]) {
                fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
                return "Font size set to \(Int(fontSize))pt."
            }
            if let face = TerminalFont(rawValue: command[1].lowercased()) {
                font = face
                return "Font set to \(face.title)."
            }
            return "Unknown font '\(command[1])'. Fonts: " + TerminalFont.allCases.map(\.rawValue).joined(separator: ", ")
        case "prompt":
            guard command.count > 1, let style = PromptStyle(rawValue: command[1].lowercased()) else {
                return "Prompt: \(promptStyle.rawValue). Styles: " + PromptStyle.allCases.map(\.rawValue).joined(separator: ", ")
            }
            promptStyle = style
            return "Prompt style set to \(style.rawValue). Takes effect in new tabs."
        case "keyboard":
            guard command.count > 1 else { return "Keyboard bar is \(keyboardBarEnabled ? "on" : "off")." }
            keyboardBarEnabled = ["on", "show", "true", "1"].contains(command[1].lowercased())
            return "Keyboard bar \(keyboardBarEnabled ? "shown" : "hidden")."
        default:
            return usage
        }
    }

    var usage: String {
        """
        usage: tern <command> [value]
          tern theme [system|light|dark|<palette>]   appearance and terminal palette
          tern font [<size>|sf-mono|menlo|courier-new]
          tern prompt [tern|classic|minimal]
          tern keyboard [on|off]
          tern about
        """
    }

    private enum Keys {
        static let appearance = "appearance"
        static let darkPalette = "palette.dark"
        static let lightPalette = "palette.light"
        static let font = "terminal.font"
        static let fontSize = "terminal.fontSize"
        static let cursorShape = "terminal.cursorShape"
        static let cursorBlinks = "terminal.cursorBlinks"
        static let promptStyle = "shell.promptStyle"
        static let autosuggestions = "shell.autosuggestions"
        static let syntaxHighlighting = "shell.syntaxHighlighting"
        static let keyboardBar = "keyboard.bar"
        static let hapticKeys = "keyboard.haptics"
        static let bell = "terminal.bell"
        static let keepAwake = "terminal.keepAwake"
        static let optionAsMeta = "keyboard.optionAsMeta"
        static let onboardingDone = "onboarding.completed"
        static let welcomeTips = "shell.welcomeTips"
    }
}

enum BellBehavior: String, CaseIterable, Codable, Identifiable {
    case haptic, visual, both, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .haptic: return "Haptic"
        case .visual: return "Flash"
        case .both: return "Haptic and flash"
        case .none: return "Off"
        }
    }
}
