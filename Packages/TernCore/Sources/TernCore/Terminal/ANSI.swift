import Foundation

/// Escape sequence builders and display width helpers shared by the line editor, the prompt
/// renderer and the session.
public enum ANSI {
    public static let esc: String = "\u{1b}"
    public static let csi: String = "\u{1b}["
    public static let bell: String = "\u{07}"

    // MARK: Cursor movement

    public static func cursorUp(_ n: Int) -> String { n > 0 ? "\(csi)\(n)A" : "" }
    public static func cursorDown(_ n: Int) -> String { n > 0 ? "\(csi)\(n)B" : "" }
    public static func cursorForward(_ n: Int) -> String { n > 0 ? "\(csi)\(n)C" : "" }
    public static func cursorBack(_ n: Int) -> String { n > 0 ? "\(csi)\(n)D" : "" }
    /// Moves to an absolute 1-based column on the current row (CHA).
    public static func cursorColumn(_ column: Int) -> String { "\(csi)\(max(1, column))G" }
    public static let cursorToLineStart: String = "\r"
    public static let cursorHome: String = "\u{1b}[H"
    public static let saveCursor: String = "\u{1b}7"
    public static let restoreCursor: String = "\u{1b}8"
    public static let hideCursor: String = "\u{1b}[?25l"
    public static let showCursor: String = "\u{1b}[?25h"

    // MARK: Erasing

    public static let eraseToEndOfLine: String = "\u{1b}[K"
    public static let eraseLine: String = "\u{1b}[2K"
    public static let eraseToEndOfScreen: String = "\u{1b}[J"
    public static let eraseScreen: String = "\u{1b}[2J"
    public static let eraseScrollback: String = "\u{1b}[3J"
    /// Clears the visible screen, the scrollback and homes the cursor.
    public static let clearScreen: String = "\u{1b}[H\u{1b}[2J\u{1b}[3J"

    // MARK: Modes

    public static let bracketedPasteOn: String = "\u{1b}[?2004h"
    public static let bracketedPasteOff: String = "\u{1b}[?2004l"
    public static let alternateScreenOn: String = "\u{1b}[?1049h"
    public static let alternateScreenOff: String = "\u{1b}[?1049l"

    public enum CursorShape: Int, Sendable {
        case blinkingBlock = 1
        case steadyBlock = 2
        case blinkingUnderline = 3
        case steadyUnderline = 4
        case blinkingBar = 5
        case steadyBar = 6
    }

    /// DECSCUSR cursor shape selection.
    public static func cursorShape(_ shape: CursorShape) -> String { "\(csi)\(shape.rawValue) q" }

    // MARK: Styling (SGR)

    public static let reset: String = "\u{1b}[0m"
    public static let bold: String = "\u{1b}[1m"
    public static let dim: String = "\u{1b}[2m"
    public static let italic: String = "\u{1b}[3m"
    public static let underline: String = "\u{1b}[4m"

    /// Builds an SGR sequence from numeric parameters, for example `sgr(1, 31)` for bold red.
    public static func sgr(_ parameters: Int...) -> String { sgr(parameters) }

    public static func sgr(_ parameters: [Int]) -> String {
        guard !parameters.isEmpty else { return reset }
        return csi + parameters.map(String.init).joined(separator: ";") + "m"
    }

    /// Standard foreground colors (30...37) and their bright variants (90...97).
    public enum Color: Int, Sendable {
        case black = 30, red, green, yellow, blue, magenta, cyan, white
        case brightBlack = 90, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite

        public var foreground: String { ANSI.sgr(rawValue) }
        public var background: String { ANSI.sgr(rawValue + 10) }
    }

    public static func foreground(_ color: RGBColor) -> String { csi + color.foregroundSGR + "m" }

    // MARK: Display width

    /// Number of terminal cells `text` occupies. Escape sequences count as zero.
    public static func displayWidth(of text: String) -> Int {
        var total = 0
        for cluster in stripANSI(text) {
            total += width(ofCluster: cluster)
        }
        return total
    }

    /// Width of one grapheme cluster: 2 for emoji presentation and East Asian wide characters,
    /// 0 for control characters, otherwise 1. Combining marks attached to a base do not add width.
    public static func width(ofCluster cluster: Character) -> Int {
        var result = 0
        var sawBase = false
        for scalar in cluster.unicodeScalars {
            if scalar.properties.isEmojiPresentation, !isTextDefaultEmoji(scalar) {
                return 2
            }
            if scalar.value == 0xFE0F, sawBase {
                // Variation selector 16 requests emoji presentation for the preceding scalar.
                return 2
            }
            let w = width(of: scalar)
            if !sawBase {
                result = w
                sawBase = w > 0 || scalar.value >= 0x20
            } else if w == 2 {
                result = 2
            }
        }
        return result
    }

    /// Width of a single scalar following wcwidth conventions.
    public static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x20 || v == 0x7f || (0x80...0x9f).contains(v) { return 0 }
        if v == 0x200B || v == 0x200C || v == 0x200D || v == 0x2060 || v == 0xFEFF { return 0 }
        if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if isWide(v) { return 2 }
        return 1
    }

    /// Characters whose default presentation is text even though they have an emoji form (digits, #, *).
    private static func isTextDefaultEmoji(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x7f || v == 0xA9 || v == 0xAE
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0,
        0x23F3...0x23F3, 0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
        0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
        0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5,
        0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
        0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
        0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55,
        0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
        0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18AFF, 0x1B000...0x1B2FF,
        0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
        0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF,
        0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isWide(_ v: UInt32) -> Bool {
        // Binary search over sorted, non overlapping ranges.
        var low = 0
        var high = wideRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = wideRanges[mid]
            if range.contains(v) { return true }
            if v < range.lowerBound { high = mid - 1 } else { low = mid + 1 }
        }
        return false
    }

    /// Removes CSI, OSC and two character escape sequences.
    public static func stripANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar.value == 0x1b else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let next = scalars.next() else { break }
            switch next {
            case "[":
                // CSI: parameters and intermediates until a final byte in 0x40...0x7E.
                while let c = scalars.next() {
                    if (0x40...0x7e).contains(c.value) { break }
                }
            case "]":
                // OSC: until BEL or ESC \.
                var previous: Unicode.Scalar? = nil
                while let c = scalars.next() {
                    if c.value == 0x07 { break }
                    if previous?.value == 0x1b, c == "\\" { break }
                    previous = c
                }
            case "(", ")", "#", "%":
                _ = scalars.next()
            default:
                break
            }
        }
        return result
    }
}
