import Foundation

/// A decoded key press.
public enum Key: Equatable, Sendable {
    /// A printable character (one grapheme or scalar), including space.
    case character(Character)
    case enter
    case tab
    case shiftTab
    case backspace
    case delete
    case up, down, left, right
    case shiftUp, shiftDown, shiftLeft, shiftRight
    case ctrlLeft, ctrlRight, ctrlUp, ctrlDown
    case altLeft, altRight
    case home, end
    case pageUp, pageDown
    case insert
    /// Ctrl plus a letter or symbol. The associated character is lowercase (`"a"` for Ctrl-A, `"_"` for Ctrl-_,
    /// `" "` for Ctrl-Space).
    case control(Character)
    /// Alt (Option as Meta) plus a character.
    case alt(Character)
    case altBackspace
    /// A bare Escape key press.
    case escape
    /// Function keys F1...F12.
    case function(Int)
    /// Text delivered inside bracketed paste markers.
    case paste(String)
    /// An escape sequence the parser recognised as such but does not map to anything.
    case unknown(String)
}

/// Turns the byte stream coming from the terminal emulator into `Key` values.
///
/// The parser keeps state between calls: multi byte UTF-8 sequences and escape sequences that are
/// split across chunks are completed by the next chunk. A bare `ESC` at the end of a chunk is
/// reported as `.escape` immediately, because terminal emulators always deliver a complete
/// sequence in one write and a lone ESC is how the Esc key itself arrives.
public struct KeyParser {
    private var pendingEscape: [UInt8] = []
    private var pendingUTF8: [UInt8] = []
    private var pasteBuffer: [UInt8]? = nil

    public init() {}

    /// Decodes a chunk of bytes. Keys are returned in order.
    public mutating func feed(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var index = 0
        let count = bytes.count

        while index < count {
            if pasteBuffer != nil {
                // Inside a bracketed paste: consume until ESC [ 2 0 1 ~.
                let byte = bytes[index]
                index += 1
                pasteBuffer!.append(byte)
                if let paste = pasteBuffer, paste.count >= 6,
                   paste.suffix(6).elementsEqual([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]) {
                    let content = Array(paste.dropLast(6))
                    pasteBuffer = nil
                    keys.append(.paste(String(decoding: content, as: UTF8.self)))
                }
                continue
            }

            if !pendingEscape.isEmpty {
                // Continue an escape sequence started in a previous chunk.
                pendingEscape.append(bytes[index])
                index += 1
                if let key = decodeEscape(pendingEscape, isComplete: true) {
                    pendingEscape.removeAll()
                    if case .paste("") = key { pasteBuffer = [] } else { keys.append(key) }
                } else if !escapeMayContinue(pendingEscape) {
                    let bad = pendingEscape
                    pendingEscape.removeAll()
                    keys.append(.unknown(String(decoding: bad, as: UTF8.self)))
                }
                continue
            }

            let byte = bytes[index]

            if byte == 0x1b {
                // Find the extent of the escape sequence inside this chunk.
                var end = index + 1
                if end >= count {
                    keys.append(.escape)
                    index = end
                    continue
                }
                let second = bytes[end]
                if second == 0x5b || second == 0x4f {
                    // CSI (ESC [) or SS3 (ESC O): read until a final byte 0x40...0x7E.
                    end += 1
                    while end < count, !(0x40...0x7e).contains(bytes[end]) {
                        end += 1
                    }
                    if end >= count {
                        // Incomplete, wait for more bytes.
                        pendingEscape = Array(bytes[index..<count])
                        index = count
                        continue
                    }
                    end += 1
                    let sequence = Array(bytes[index..<end])
                    if let key = decodeEscape(sequence, isComplete: true) {
                        if case .paste("") = key { pasteBuffer = [] } else { keys.append(key) }
                    } else {
                        keys.append(.unknown(String(decoding: sequence, as: UTF8.self)))
                    }
                    index = end
                    continue
                }
                if second == 0x1b {
                    keys.append(.escape)
                    index += 1
                    continue
                }
                if second == 0x7f || second == 0x08 {
                    keys.append(.altBackspace)
                    index += 2
                    continue
                }
                // Alt + character: ESC followed by a (possibly multi byte) printable character.
                var scalarEnd = end + 1
                while scalarEnd < count, (bytes[scalarEnd] & 0xC0) == 0x80 { scalarEnd += 1 }
                let text = String(decoding: bytes[end..<scalarEnd], as: UTF8.self)
                if let first = text.first, !text.isEmpty {
                    if second < 0x20 {
                        keys.append(.escape)
                        index += 1
                    } else {
                        keys.append(.alt(first))
                        index = scalarEnd
                    }
                } else {
                    keys.append(.escape)
                    index += 1
                }
                continue
            }

            // Plain bytes.
            index += 1
            if let key = decodeControl(byte) {
                flushUTF8(into: &keys)
                keys.append(key)
                continue
            }

            if byte < 0x80 {
                flushUTF8(into: &keys)
                keys.append(.character(Character(Unicode.Scalar(byte))))
                continue
            }

            pendingUTF8.append(byte)
            if let expected = utf8Length(leadByte: pendingUTF8[0]) {
                if pendingUTF8.count == expected {
                    let text = String(decoding: pendingUTF8, as: UTF8.self)
                    pendingUTF8.removeAll()
                    for character in text { keys.append(.character(character)) }
                } else if pendingUTF8.count > expected {
                    pendingUTF8.removeAll()
                }
            } else {
                // Stray continuation byte.
                pendingUTF8.removeAll()
            }
        }
        return keys
    }

    private mutating func flushUTF8(into keys: inout [Key]) {
        guard !pendingUTF8.isEmpty else { return }
        pendingUTF8.removeAll()
    }

    private func utf8Length(leadByte: UInt8) -> Int? {
        if leadByte & 0xE0 == 0xC0 { return 2 }
        if leadByte & 0xF0 == 0xE0 { return 3 }
        if leadByte & 0xF8 == 0xF0 { return 4 }
        return nil
    }

    private func decodeControl(_ byte: UInt8) -> Key? {
        switch byte {
        case 0x0d, 0x0a: return .enter
        case 0x09: return .tab
        case 0x7f, 0x08: return .backspace
        case 0x00: return .control(" ")
        case 0x01...0x1a:
            let letter = Character(Unicode.Scalar(UInt8(0x60 + byte)))
            return .control(letter)
        case 0x1c: return .control("\\")
        case 0x1d: return .control("]")
        case 0x1e: return .control("^")
        case 0x1f: return .control("_")
        default: return nil
        }
    }

    private func escapeMayContinue(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 2 else { return true }
        let last = sequence[sequence.count - 1]
        return !(0x40...0x7e).contains(last)
    }

    /// Decodes a complete CSI or SS3 sequence. Returns `.paste("")` as a marker for the start of a bracketed paste.
    private func decodeEscape(_ sequence: [UInt8], isComplete: Bool) -> Key? {
        guard sequence.count >= 3, sequence[0] == 0x1b else { return nil }
        let introducer = sequence[1]
        let final = sequence[sequence.count - 1]
        guard (0x40...0x7e).contains(final) else { return nil }
        let parameterBytes = sequence[2..<(sequence.count - 1)]
        let parameterString = String(decoding: parameterBytes, as: UTF8.self)
        let parameters = parameterString.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        let modifier = parameters.count > 1 ? (parameters[1] ?? 1) : 1

        if introducer == 0x4f {
            // SS3 sequences: ESC O A etc.
            switch final {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            case 0x48: return .home
            case 0x46: return .end
            case 0x50: return .function(1)
            case 0x51: return .function(2)
            case 0x52: return .function(3)
            case 0x53: return .function(4)
            default: return nil
            }
        }

        switch final {
        case 0x41: return arrow(.up, modifier: modifier)
        case 0x42: return arrow(.down, modifier: modifier)
        case 0x43: return arrow(.right, modifier: modifier)
        case 0x44: return arrow(.left, modifier: modifier)
        case 0x48: return .home
        case 0x46: return .end
        case 0x5a: return .shiftTab
        case 0x7e:
            let number = parameters.first ?? nil
            switch number {
            case 1, 7: return .home
            case 4, 8: return .end
            case 2: return .insert
            case 3: return .delete
            case 5: return .pageUp
            case 6: return .pageDown
            case 200: return .paste("")
            case 201: return .unknown("\u{1b}[201~")
            case 11: return .function(1)
            case 12: return .function(2)
            case 13: return .function(3)
            case 14: return .function(4)
            case 15: return .function(5)
            case 17: return .function(6)
            case 18: return .function(7)
            case 19: return .function(8)
            case 20: return .function(9)
            case 21: return .function(10)
            case 23: return .function(11)
            case 24: return .function(12)
            default: return nil
            }
        default:
            return nil
        }
    }

    private func arrow(_ base: Key, modifier: Int) -> Key {
        // xterm modifier codes: 2 shift, 3 alt, 5 ctrl, 6 ctrl+shift, 7 ctrl+alt, 4 shift+alt.
        switch (base, modifier) {
        case (.up, 2): return .shiftUp
        case (.down, 2): return .shiftDown
        case (.left, 2): return .shiftLeft
        case (.right, 2): return .shiftRight
        case (.left, 3), (.left, 4): return .altLeft
        case (.right, 3), (.right, 4): return .altRight
        case (.left, 5), (.left, 6), (.left, 7): return .ctrlLeft
        case (.right, 5), (.right, 6), (.right, 7): return .ctrlRight
        case (.up, 5): return .ctrlUp
        case (.down, 5): return .ctrlDown
        default: return base
        }
    }
}
