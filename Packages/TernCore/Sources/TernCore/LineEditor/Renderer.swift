import Foundation

/// A run of text drawn with one style. `sgr` is a complete escape sequence (or empty for plain text).
public struct StyledSegment: Equatable {
    public var text: String
    public var sgr: String

    public init(_ text: String, sgr: String = "") {
        self.text = text
        self.sgr = sgr
    }
}

/// Where things land on the screen for one rendering of prompt plus text.
public struct LineLayout: Equatable {
    /// Rows the prompt and text occupy, including the row the cursor ends on after a forced wrap.
    public var rows: Int
    /// 0-based row and column where the cursor must be placed.
    public var cursorRow: Int
    public var cursorColumn: Int
    /// Position right after the last drawn cell.
    public var endRow: Int
    public var endColumn: Int
    /// True when the last cell is exactly at the right edge, so the renderer emits a line break to
    /// leave the terminal in a well defined state.
    public var pendingWrap: Bool
}

/// Draws the prompt and the edit buffer, handling wrapping across rows, wide characters, tabs and
/// embedded newlines. It remembers where the previous drawing left the cursor so each redraw can
/// move back to the first row and repaint from there.
public struct LineRenderer: Equatable {
    public private(set) var previousRows: Int = 0
    public private(set) var previousCursorRow: Int = 0

    public init() {}

    /// Forgets the previous drawing. Call after the line was finished with a newline or the screen was cleared.
    public mutating func reset() {
        previousRows = 0
        previousCursorRow = 0
    }

    /// Computes the layout without producing output.
    public static func layout(prompt: RenderedPrompt, text: [Character], cursor: Int, ghost: String, columns: Int) -> LineLayout {
        let columns = max(1, columns)
        var row = 0
        var col = min(prompt.width, columns)
        if prompt.width > columns {
            row = prompt.width / columns
            col = prompt.width % columns
        }
        var cursorRow = row
        var cursorColumn = col
        func place(_ character: Character) {
            if character == "\n" {
                row += 1
                col = 0
                return
            }
            if character == "\t" {
                if col >= columns { return }
                let next = min(columns, (col / 8 + 1) * 8)
                col = next
                return
            }
            let width = ANSI.width(ofCluster: character)
            if width == 0 { return }
            if col + width > columns {
                row += 1
                col = 0
            }
            col += width
        }
        for (index, character) in text.enumerated() {
            if index == cursor {
                (cursorRow, cursorColumn) = cursorPosition(row: row, col: col, columns: columns)
            }
            place(character)
        }
        if cursor >= text.count {
            (cursorRow, cursorColumn) = cursorPosition(row: row, col: col, columns: columns)
        }
        for character in ghost { place(character) }
        var endRow = row
        var endColumn = col
        let pendingWrap = col >= columns
        if pendingWrap {
            endRow += 1
            endColumn = 0
        }
        return LineLayout(rows: endRow + 1, cursorRow: cursorRow, cursorColumn: cursorColumn, endRow: endRow, endColumn: endColumn, pendingWrap: pendingWrap)
    }

    private static func cursorPosition(row: Int, col: Int, columns: Int) -> (Int, Int) {
        col >= columns ? (row + 1, 0) : (row, col)
    }

    /// Repaints the whole line. Returns the bytes to write.
    public mutating func render(prompt: RenderedPrompt, segments: [StyledSegment], cursor: Int, ghost: String?, columns: Int) -> String {
        let columns = max(1, columns)
        let text: [Character] = segments.flatMap { Array($0.text) }
        let ghostText = ghost ?? ""
        let layout = LineRenderer.layout(prompt: prompt, text: text, cursor: cursor, ghost: ghostText, columns: columns)

        var output = ""
        if previousRows > 0 {
            output += ANSI.cursorToLineStart + ANSI.cursorUp(previousCursorRow)
        } else {
            output += ANSI.cursorToLineStart
        }
        output += ANSI.eraseToEndOfScreen
        output += prompt.text

        var col = prompt.width % columns
        if prompt.width > 0 && prompt.width % columns == 0 { col = columns }
        for segment in segments {
            if !segment.sgr.isEmpty { output += segment.sgr }
            output += LineRenderer.drawable(segment.text, startingAt: &col, columns: columns)
            if !segment.sgr.isEmpty { output += ANSI.reset }
        }
        if !ghostText.isEmpty {
            output += ANSI.sgr(2, 90) + LineRenderer.drawable(ghostText, startingAt: &col, columns: columns) + ANSI.reset
        }
        if layout.pendingWrap {
            output += "\r\n"
        }
        // Move from the end position to the cursor position.
        output += ANSI.cursorUp(layout.endRow - layout.cursorRow)
        output += ANSI.cursorToLineStart + ANSI.cursorForward(layout.cursorColumn)

        previousRows = layout.rows
        previousCursorRow = layout.cursorRow
        return output
    }

    /// Moves the cursor below the last row of the current drawing and resets tracking. Used when the
    /// line is submitted or when static output (completion listings) must be printed under it.
    public mutating func moveToEnd(prompt: RenderedPrompt, text: [Character], cursor: Int, ghost: String?, columns: Int) -> String {
        guard previousRows > 0 else { return "" }
        let layout = LineRenderer.layout(prompt: prompt, text: text, cursor: cursor, ghost: ghost ?? "", columns: columns)
        var output = ANSI.cursorDown(layout.endRow - layout.cursorRow)
        output += ANSI.cursorToLineStart + ANSI.cursorForward(layout.endColumn)
        return output
    }

    /// Converts text for the terminal: newlines become CR LF and tabs become spaces up to the next
    /// tab stop, tracking the column so wide characters wrap the same way the layout predicts.
    static func drawable(_ text: String, startingAt col: inout Int, columns: Int) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            if character == "\n" {
                output += "\r\n"
                col = 0
                continue
            }
            if character == "\t" {
                if col >= columns { continue }
                let next = min(columns, (col / 8 + 1) * 8)
                output += String(repeating: " ", count: next - col)
                col = next
                continue
            }
            if character.isControl() {
                continue
            }
            let width = ANSI.width(ofCluster: character)
            if width == 0 {
                output.append(character)
                continue
            }
            if col + width > columns {
                if width == 2 && col < columns {
                    // The terminal cannot split a wide glyph; pad the row so the layout stays in sync.
                    output += String(repeating: " ", count: columns - col)
                }
                col = 0
            }
            output.append(character)
            col += width
        }
        return output
    }
}

extension Character {
    /// C0 and C1 control characters other than tab and newline.
    func isControl() -> Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        let v = scalar.value
        if v == 0x09 || v == 0x0a { return false }
        return v < 0x20 || v == 0x7f || (0x80...0x9f).contains(v)
    }
}
