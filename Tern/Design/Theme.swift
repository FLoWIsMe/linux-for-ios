import SwiftUI
import UIKit
import SwiftTerm
import TernCore

/// Light, dark, or follow the system.
enum Appearance: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// An 8-bit RGB color that can be stored, compared, and converted for SwiftUI, UIKit, SwiftTerm and the shell.
struct RGB: Codable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }

    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    var uiColor: UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var terminalColor: SwiftTerm.Color { SwiftTerm.Color(red8: UInt16(r), green8: UInt16(g), blue8: UInt16(b)) }
    var shellColor: RGBColor { RGBColor(red: r, green: g, blue: b) }
    var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Relative luminance per WCAG, 0 (black) to 1 (white).
    var luminance: Double {
        func channel(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

/// Everything the terminal needs to draw: 16 ANSI colors plus background, foreground, cursor and selection.
struct TerminalPalette: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    let selection: RGB
    /// Exactly 16 entries: black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
    let ansi: [RGB]

    var swiftTermColors: [SwiftTerm.Color] { ansi.map(\.terminalColor) }

    static let ternDark = TerminalPalette(
        id: "tern-dark", name: "Tern Dark", isDark: true,
        background: RGB(hex: 0x0B0F14), foreground: RGB(hex: 0xE6EDF3), cursor: RGB(hex: 0xFF6A2F), selection: RGB(hex: 0x2A3441),
        ansi: [0x1B2229, 0xFF6B6B, 0x5FD08A, 0xF2C94C, 0x6CA8FF, 0xC792EA, 0x4FD1D9, 0xD8DEE9,
               0x6B7785, 0xFF8A80, 0x7EE2A8, 0xFFD866, 0x8FBCFF, 0xD7B3F2, 0x7FE3E8, 0xFFFFFF].map(RGB.init(hex:)))

    static let ternLight = TerminalPalette(
        id: "tern-light", name: "Tern Light", isDark: false,
        background: RGB(hex: 0xFBFBF9), foreground: RGB(hex: 0x1F2328), cursor: RGB(hex: 0xE8521C), selection: RGB(hex: 0xDDE6F2),
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0xBF8700, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F].map(RGB.init(hex:)))

    static let pureBlack = TerminalPalette(
        id: "pure-black", name: "Pure Black", isDark: true,
        background: RGB(hex: 0x000000), foreground: RGB(hex: 0xE4E4E4), cursor: RGB(hex: 0xFF6A2F), selection: RGB(hex: 0x303030),
        ansi: [0x1A1A1A, 0xFF5F5F, 0x5FDB7A, 0xF5D061, 0x5FA8FF, 0xD28BFF, 0x4FD6E0, 0xC8C8C8,
               0x6A6A6A, 0xFF8A8A, 0x8CF2A0, 0xFFE28A, 0x8FC2FF, 0xE2B2FF, 0x8CEBF2, 0xFFFFFF].map(RGB.init(hex:)))

    static let solarizedDark = TerminalPalette(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        background: RGB(hex: 0x002B36), foreground: RGB(hex: 0x839496), cursor: RGB(hex: 0x93A1A1), selection: RGB(hex: 0x073642),
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x586E75, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3].map(RGB.init(hex:)))

    static let solarizedLight = TerminalPalette(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        background: RGB(hex: 0xFDF6E3), foreground: RGB(hex: 0x586E75), cursor: RGB(hex: 0x586E75), selection: RGB(hex: 0xEEE8D5),
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3].map(RGB.init(hex:)))

    static let dracula = TerminalPalette(
        id: "dracula", name: "Dracula", isDark: true,
        background: RGB(hex: 0x282A36), foreground: RGB(hex: 0xF8F8F2), cursor: RGB(hex: 0xF8F8F2), selection: RGB(hex: 0x44475A),
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF].map(RGB.init(hex:)))

    static let nord = TerminalPalette(
        id: "nord", name: "Nord", isDark: true,
        background: RGB(hex: 0x2E3440), foreground: RGB(hex: 0xD8DEE9), cursor: RGB(hex: 0xD8DEE9), selection: RGB(hex: 0x434C5E),
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4].map(RGB.init(hex:)))

    static let gruvboxDark = TerminalPalette(
        id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
        background: RGB(hex: 0x282828), foreground: RGB(hex: 0xEBDBB2), cursor: RGB(hex: 0xEBDBB2), selection: RGB(hex: 0x504945),
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2].map(RGB.init(hex:)))

    static let oneDark = TerminalPalette(
        id: "one-dark", name: "One Dark", isDark: true,
        background: RGB(hex: 0x282C34), foreground: RGB(hex: 0xABB2BF), cursor: RGB(hex: 0x528BFF), selection: RGB(hex: 0x3E4451),
        ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF].map(RGB.init(hex:)))

    static let catppuccinMocha = TerminalPalette(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
        background: RGB(hex: 0x1E1E2E), foreground: RGB(hex: 0xCDD6F4), cursor: RGB(hex: 0xF5E0DC), selection: RGB(hex: 0x45475A),
        ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
               0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8].map(RGB.init(hex:)))

    static let catppuccinLatte = TerminalPalette(
        id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
        background: RGB(hex: 0xEFF1F5), foreground: RGB(hex: 0x4C4F69), cursor: RGB(hex: 0xDC8A78), selection: RGB(hex: 0xCCD0DA),
        ansi: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
               0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC].map(RGB.init(hex:)))

    static let all: [TerminalPalette] = [
        .ternDark, .ternLight, .pureBlack, .solarizedDark, .solarizedLight, .dracula, .nord, .gruvboxDark, .oneDark,
        .catppuccinMocha, .catppuccinLatte,
    ]

    static func named(_ id: String) -> TerminalPalette? { all.first { $0.id == id } }
}

/// Colors for the app chrome (everything that is not the terminal grid). Each resolves for light and dark.
enum ChromeColor {
    static let background = Color.dynamic(light: RGB(hex: 0xFBFBF9), dark: RGB(hex: 0x0B0F14))
    static let surface = Color.dynamic(light: RGB(hex: 0xFFFFFF), dark: RGB(hex: 0x121820))
    static let surfaceElevated = Color.dynamic(light: RGB(hex: 0xF3F4F2), dark: RGB(hex: 0x19202A))
    static let textPrimary = Color.dynamic(light: RGB(hex: 0x1F2328), dark: RGB(hex: 0xE6EDF3))
    static let textSecondary = Color.dynamic(light: RGB(hex: 0x57606A), dark: RGB(hex: 0x9AA4B2))
    static let textTertiary = Color.dynamic(light: RGB(hex: 0x8C959F), dark: RGB(hex: 0x6B7785))
    static let hairline = Color.dynamic(light: RGB(hex: 0xE6E8E4), dark: RGB(hex: 0x202833))
    static let control = Color.dynamic(light: RGB(hex: 0xEDEEEB), dark: RGB(hex: 0x1C2430))
    static let controlPressed = Color.dynamic(light: RGB(hex: 0xDFE1DC), dark: RGB(hex: 0x27313F))
    static let accent = Color.dynamic(light: RGB(hex: 0xE8521C), dark: RGB(hex: 0xFF6A2F))
    static let onAccent = Color.white
    static let danger = Color.dynamic(light: RGB(hex: 0xCF222E), dark: RGB(hex: 0xFF6B6B))
    static let success = Color.dynamic(light: RGB(hex: 0x116329), dark: RGB(hex: 0x5FD08A))

    static func accentRGB(for scheme: ColorScheme) -> RGB {
        scheme == .dark ? RGB(hex: 0xFF6A2F) : RGB(hex: 0xE8521C)
    }
}

extension Color {
    /// A color that resolves differently in light and dark mode.
    static func dynamic(light: RGB, dark: RGB) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark.uiColor : light.uiColor
        })
    }
}

/// Type scale. Display text uses the system serif (New York) so headings read as considered rather than
/// default; everything else is the system sans and the terminal uses a monospaced face.
enum Typography {
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func body(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Layout constants shared by every screen.
enum Metrics {
    static let screenPadding: CGFloat = 24
    static let radiusControl: CGFloat = 12
    static let radiusCard: CGFloat = 16
    static let tapTarget: CGFloat = 44
    static let hairline: CGFloat = 1
    static let keyboardBarHeight: CGFloat = 44
}

/// Terminal fonts the user can pick from. Only faces that ship with iOS, so nothing has to be bundled.
enum TerminalFont: String, CaseIterable, Codable, Identifiable {
    case sfMono = "sf-mono"
    case menlo = "menlo"
    case courierNew = "courier-new"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfMono: return "SF Mono"
        case .menlo: return "Menlo"
        case .courierNew: return "Courier New"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .sfMono: return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo: return UIFont(name: "Menlo-Regular", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .courierNew: return UIFont(name: "CourierNewPSMT", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func boldFont(size: CGFloat) -> UIFont {
        switch self {
        case .sfMono: return UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        case .menlo: return UIFont(name: "Menlo-Bold", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        case .courierNew: return UIFont(name: "CourierNewPS-BoldMT", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
    }

    func italicFont(size: CGFloat) -> UIFont {
        let base = uiFont(size: size)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    func boldItalicFont(size: CGFloat) -> UIFont {
        let base = boldFont(size: size)
        if let descriptor = base.fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold]) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

/// Cursor shapes offered in Settings, mapped onto SwiftTerm's styles.
enum CursorShape: String, CaseIterable, Codable, Identifiable {
    case block, underline, bar
    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: return "Block"
        case .underline: return "Underline"
        case .bar: return "Bar"
        }
    }

    func swiftTermStyle(blinking: Bool) -> CursorStyle {
        switch (self, blinking) {
        case (.block, true): return .blinkBlock
        case (.block, false): return .steadyBlock
        case (.underline, true): return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        case (.bar, true): return .blinkBar
        case (.bar, false): return .steadyBar
        }
    }
}
