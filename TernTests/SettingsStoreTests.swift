import XCTest
@testable import Tern

final class SettingsStoreTests: XCTestCase {
    private func makeStore() -> SettingsStore {
        let suite = "tern-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    func testDefaults() {
        let store = makeStore()
        XCTAssertEqual(store.appearance, .system)
        XCTAssertEqual(store.palette(for: .dark).id, TerminalPalette.ternDark.id)
        XCTAssertEqual(store.palette(for: .light).id, TerminalPalette.ternLight.id)
        XCTAssertTrue(store.autosuggestions)
        XCTAssertTrue(store.keyboardBarEnabled)
        XCTAssertFalse(store.hasCompletedOnboarding)
    }

    func testTernCommandChangesThemeAndFont() {
        let store = makeStore()
        XCTAssertEqual(store.apply(command: ["theme", "dark"]), "Appearance set to Dark.")
        XCTAssertEqual(store.appearance, .dark)
        XCTAssertEqual(store.apply(command: ["theme", "dracula"]), "Dark palette set to Dracula.")
        XCTAssertEqual(store.palette(for: .dark).id, "dracula")
        XCTAssertEqual(store.palette(for: .light).id, TerminalPalette.ternLight.id, "a dark palette does not replace the light one")
        XCTAssertEqual(store.apply(command: ["font", "16"]), "Font size set to 16pt.")
        XCTAssertEqual(store.fontSize, 16)
        XCTAssertEqual(store.apply(command: ["font", "99"]), "Font size set to 24pt.", "clamped to the allowed range")
        XCTAssertEqual(store.apply(command: ["font", "menlo"]), "Font set to Menlo.")
        XCTAssertTrue(store.apply(command: ["theme", "nope"]).hasPrefix("Unknown theme"))
        XCTAssertTrue(store.apply(command: []).hasPrefix("usage:"))
    }

    func testPalettesHaveSixteenAnsiColorsAndReadableContrast() {
        for palette in TerminalPalette.all {
            XCTAssertEqual(palette.ansi.count, 16, palette.name)
            let bg = palette.background.luminance
            let fg = palette.foreground.luminance
            let ratio = (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05)
            XCTAssertGreaterThan(ratio, 4.5, "\(palette.name) foreground on background should meet WCAG AA")
            XCTAssertEqual(palette.isDark, bg < 0.5, palette.name)
        }
    }
}
