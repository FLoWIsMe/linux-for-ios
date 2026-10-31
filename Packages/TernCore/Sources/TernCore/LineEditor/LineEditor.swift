import Foundation

/// Tunables for the interactive line editor.
public struct LineEditorConfiguration: Equatable, Sendable {
    public var autosuggestions: Bool
    public var syntaxHighlighting: Bool
    public var columns: Int
    /// Maximum rows used by a completion listing before it is summarised.
    public var listingRows: Int

    public init(autosuggestions: Bool = true, syntaxHighlighting: Bool = true, columns: Int = 80, listingRows: Int = 8) {
        self.autosuggestions = autosuggestions
        self.syntaxHighlighting = syntaxHighlighting
        self.columns = columns
        self.listingRows = listingRows
    }
}

/// What happened as a result of a key press.
public enum LineEditorEvent: Equatable {
    case none
    /// The user pressed Enter. The text has history references expanded and is ready to run.
    case submit(String)
    /// Ctrl-C: the line was discarded. A new line must be begun by the caller.
    case cancel
    /// Ctrl-D on an empty line.
    case eof
    /// Ctrl-L: the editor cleared the screen and redrew itself.
    case clearScreen
}

/// Output produced by feeding keys: bytes to write to the terminal and the event, if any.
public struct LineEditorOutput: Equatable {
    public var text: String
    public var event: LineEditorEvent
    /// Keys that were not processed because an event ended the line first (type ahead).
    public var unconsumed: [Key]

    public var bytes: [UInt8] { Array(text.utf8) }

    public init(text: String = "", event: LineEditorEvent = .none, unconsumed: [Key] = []) {
        self.text = text
        self.event = event
        self.unconsumed = unconsumed
    }
}

/// A readline and fish class line editor. It is a synchronous state machine: feed it keys, write the
/// returned bytes to the terminal, act on the returned event.
public final class LineEditor {
    public var configuration: LineEditorConfiguration
    public let history: CommandHistory
    public var completionEngine: CompletionEngine?
    /// Supplies the shell state used by completion and highlighting. Called on every redraw.
    public var snapshotProvider: () -> ShellSnapshot

    private var parser = KeyParser()
    private var renderer = LineRenderer()

    public private(set) var buffer: [Character] = []
    public private(set) var cursor: Int = 0
    public private(set) var prompt: RenderedPrompt = .empty
    public private(set) var isActive = false

    // History navigation.
    private var historyIndex: Int? = nil
    private var historyPrefix: [Character] = []
    private var savedBuffer: [Character] = []

    // Incremental reverse search.
    private struct SearchState {
        var query: String = ""
        var matchIndex: Int? = nil
        var failed = false
        var original: [Character]
        var originalCursor: Int
    }
    private var search: SearchState? = nil

    // Kill ring, yank and undo.
    private var killRing = KillRing()
    private var lastKeyWasKill = false
    private var lastKeyWasYank = false
    private var lastYankLength = 0
    private var undo = UndoStack()

    // Autosuggestion.
    private var suggestionDismissed = false
    private var currentSuggestion: String? = nil

    // Alt-. cycling.
    private var lastArgumentIndex: Int? = nil
    private var lastArgumentLength = 0
    private var lastKeyWasLastArgument = false

    public init(configuration: LineEditorConfiguration, history: CommandHistory, completionEngine: CompletionEngine? = nil, snapshotProvider: @escaping () -> ShellSnapshot) {
        self.configuration = configuration
        self.history = history
        self.completionEngine = completionEngine
        self.snapshotProvider = snapshotProvider
    }

    // MARK: Line lifecycle

    public var text: String { String(buffer) }

    /// Starts editing a new line. Returns the bytes that draw the prompt (and `initialText`).
    public func beginLine(prompt: RenderedPrompt, initialText: String = "") -> String {
        self.prompt = prompt
        buffer = Array(initialText)
        cursor = buffer.count
        historyIndex = nil
        historyPrefix = []
        savedBuffer = []
        search = nil
        lastKeyWasKill = false
        lastKeyWasYank = false
        lastKeyWasLastArgument = false
        lastArgumentIndex = nil
        suggestionDismissed = false
        currentSuggestion = nil
        undo.removeAll()
        renderer.reset()
        isActive = true
        return redraw()
    }

    /// Changes the prompt of the active line (used when the shell asks for a continuation line).
    public func setPrompt(_ prompt: RenderedPrompt) -> String {
        self.prompt = prompt
        return isActive ? redraw() : ""
    }

    /// Replaces the contents of the active line.
    public func setText(_ text: String) -> String {
        guard isActive else {
            buffer = Array(text)
            cursor = buffer.count
            return ""
        }
        recordUndo(typing: false)
        buffer = Array(text)
        cursor = buffer.count
        historyIndex = nil
        suggestionDismissed = false
        return redraw()
    }

    /// Inserts text at the cursor as if it had been typed, without interpreting it.
    public func insert(_ text: String) -> String {
        guard isActive else { return "" }
        recordUndo(typing: false)
        insertRaw(text)
        return redraw()
    }

    /// The terminal width changed.
    public func resize(columns: Int) -> String {
        configuration.columns = max(1, columns)
        return isActive ? redraw() : ""
    }

    /// Redraws the line (after the screen was cleared by someone else, for example).
    public func redrawAfterClear() -> String {
        renderer.reset()
        return isActive ? redraw() : ""
    }

    // MARK: Input

    /// Decodes bytes and processes them. Processing stops at the first event that ends the line; the
    /// remaining keys are returned as `unconsumed` so the caller can replay them on the next line.
    public func feed(bytes: [UInt8]) -> LineEditorOutput {
        let keys = parser.feed(bytes)
        return feed(keys: keys)
    }

    public func feed(keys: [Key]) -> LineEditorOutput {
        var output = LineEditorOutput()
        var index = 0
        while index < keys.count {
            let result = feed(key: keys[index])
            index += 1
            output.text += result.text
            if result.event != .none {
                output.event = result.event
                if case .clearScreen = result.event { continue }
                output.unconsumed = Array(keys[index...])
                break
            }
        }
        return output
    }

    public func feed(key: Key) -> LineEditorOutput {
        guard isActive else { return LineEditorOutput() }
        let wasKill = lastKeyWasKill
        let wasYank = lastKeyWasYank
        let wasLastArgument = lastKeyWasLastArgument
        lastKeyWasKill = false
        lastKeyWasYank = false
        lastKeyWasLastArgument = false

        if search != nil {
            return handleSearchKey(key)
        }

        switch key {
        case .character(let c):
            recordUndo(typing: true)
            insertCharacter(c)
            historyIndex = nil
            suggestionDismissed = false
        case .paste(let text):
            recordUndo(typing: false)
            insertRaw(LineEditor.sanitizePaste(text))
            historyIndex = nil
            suggestionDismissed = false
        case .enter:
            return submit()
        case .tab, .shiftTab:
            return complete()
        case .backspace, .control("h"):
            if cursor > 0 {
                recordUndo(typing: false)
                buffer.remove(at: cursor - 1)
                cursor -= 1
                historyIndex = nil
                suggestionDismissed = false
            }
        case .delete:
            if cursor < buffer.count {
                recordUndo(typing: false)
                buffer.remove(at: cursor)
                historyIndex = nil
            }
        case .control("d"):
            if buffer.isEmpty {
                let output = finishLine()
                isActive = false
                return LineEditorOutput(text: output, event: .eof)
            }
            if cursor < buffer.count {
                recordUndo(typing: false)
                buffer.remove(at: cursor)
            }
        case .left, .control("b"):
            if cursor > 0 { cursor -= 1 }
        case .right, .control("f"):
            if cursor < buffer.count {
                cursor += 1
            } else if let suggestion = currentSuggestion {
                acceptSuggestion(suggestion)
            }
        case .home, .control("a"):
            cursor = 0
        case .end, .control("e"):
            if cursor == buffer.count, let suggestion = currentSuggestion {
                acceptSuggestion(suggestion)
            } else {
                cursor = buffer.count
            }
        case .altLeft, .ctrlLeft, .alt("b"):
            cursor = wordStart(before: cursor)
        case .altRight, .ctrlRight, .alt("f"):
            if cursor == buffer.count, let suggestion = currentSuggestion {
                acceptSuggestionWord(suggestion)
            } else {
                cursor = wordEnd(after: cursor)
            }
        case .up, .control("p"):
            historyPrevious()
        case .down, .control("n"):
            historyNext()
        case .control("k"):
            killRange(cursor..<buffer.count, append: wasKill, prepend: false)
        case .control("u"):
            killRange(0..<cursor, append: wasKill, prepend: true)
        case .control("w"):
            let start = whitespaceWordStart(before: cursor)
            killRange(start..<cursor, append: wasKill, prepend: true)
        case .altBackspace:
            let start = wordStart(before: cursor)
            killRange(start..<cursor, append: wasKill, prepend: true)
        case .alt("d"):
            let end = wordEnd(after: cursor)
            killRange(cursor..<end, append: wasKill, prepend: false)
        case .control("y"):
            if let text = killRing.yank() {
                recordUndo(typing: false)
                insertRaw(text)
                lastYankLength = text.count
                lastKeyWasYank = true
            }
        case .alt("y"):
            if wasYank, let text = killRing.rotate() {
                buffer.removeSubrange((cursor - lastYankLength)..<cursor)
                cursor -= lastYankLength
                insertRaw(text)
                lastYankLength = text.count
                lastKeyWasYank = true
            }
        case .control("t"):
            transpose()
        case .control("_"), .control("/"):
            if let state = undo.pop() {
                buffer = state.buffer
                cursor = min(state.cursor, buffer.count)
            }
        case .control("l"):
            renderer.reset()
            return LineEditorOutput(text: ANSI.clearScreen + redraw(), event: .clearScreen)
        case .control("c"):
            let output = moveToEndOfLine() + "^C\r\n"
            renderer.reset()
            isActive = false
            return LineEditorOutput(text: output, event: .cancel)
        case .control("r"):
            search = SearchState(original: buffer, originalCursor: cursor)
        case .control("g"):
            break
        case .escape:
            if currentSuggestion != nil {
                suggestionDismissed = true
            }
        case .alt("."), .alt("_"):
            insertLastArgument(continuing: wasLastArgument)
        case .control, .alt, .shiftUp, .shiftDown, .shiftLeft, .shiftRight, .ctrlUp, .ctrlDown,
             .pageUp, .pageDown, .insert, .function, .unknown:
            break
        }
        return LineEditorOutput(text: redraw())
    }

    // MARK: Editing primitives

    private func insertCharacter(_ character: Character) {
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, cursor > 0,
           scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark || scalar.value == 0xFE0F || scalar.value == 0x200D {
            // Attach combining marks to the previous grapheme.
            let combined = String(buffer[cursor - 1]) + String(character)
            if let merged = combined.first, combined.count == 1 {
                buffer[cursor - 1] = merged
                return
            }
        }
        buffer.insert(character, at: cursor)
        cursor += 1
    }

    private func insertRaw(_ text: String) {
        let characters = Array(text)
        buffer.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
    }

    static func sanitizePaste(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\r\n" || character == "\r" { result.append("\n"); continue }
            if character.isControl() { continue }
            result.append(character)
        }
        return result
    }

    private func recordUndo(typing: Bool) {
        undo.record(EditorSnapshot(buffer: buffer, cursor: cursor), typing: typing)
    }

    private func killRange(_ range: Range<Int>, append: Bool, prepend: Bool) {
        guard !range.isEmpty else { lastKeyWasKill = true; return }
        recordUndo(typing: false)
        let text = String(buffer[range])
        killRing.kill(text, append: append, prepend: prepend)
        buffer.removeSubrange(range)
        cursor = range.lowerBound
        lastKeyWasKill = true
        historyIndex = nil
    }

    private func transpose() {
        guard buffer.count >= 2 else { return }
        recordUndo(typing: false)
        if cursor == buffer.count {
            buffer.swapAt(cursor - 1, cursor - 2)
        } else if cursor > 0 {
            buffer.swapAt(cursor - 1, cursor)
            cursor += 1
        }
    }

    private func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private func wordStart(before position: Int) -> Int {
        var index = position
        while index > 0, !isWordCharacter(buffer[index - 1]) { index -= 1 }
        while index > 0, isWordCharacter(buffer[index - 1]) { index -= 1 }
        return index
    }

    private func wordEnd(after position: Int) -> Int {
        var index = position
        while index < buffer.count, !isWordCharacter(buffer[index]) { index += 1 }
        while index < buffer.count, isWordCharacter(buffer[index]) { index += 1 }
        return index
    }

    private func whitespaceWordStart(before position: Int) -> Int {
        var index = position
        while index > 0, buffer[index - 1].isWhitespace { index -= 1 }
        while index > 0, !buffer[index - 1].isWhitespace { index -= 1 }
        return index
    }

    // MARK: Suggestions

    private func acceptSuggestion(_ suggestion: String) {
        recordUndo(typing: false)
        buffer = Array(suggestion)
        cursor = buffer.count
        historyIndex = nil
    }

    private func acceptSuggestionWord(_ suggestion: String) {
        let ghost = Array(suggestion.dropFirst(buffer.count))
        var take = 0
        while take < ghost.count, !ghost[take].isWhitespace { take += 1 }
        while take < ghost.count, ghost[take].isWhitespace { take += 1 }
        guard take > 0 else { return }
        recordUndo(typing: false)
        insertRaw(String(ghost[0..<take]))
    }

    private func computeSuggestion() -> String? {
        guard configuration.autosuggestions, !suggestionDismissed, search == nil, cursor == buffer.count, !buffer.isEmpty else { return nil }
        return history.suggestion(forPrefix: String(buffer))
    }

    // MARK: History

    private func historyPrevious() {
        let entries = history.entries
        guard !entries.isEmpty else { return }
        if historyIndex == nil {
            historyIndex = entries.count
            historyPrefix = buffer
            savedBuffer = buffer
        }
        var index = historyIndex! - 1
        while index >= 0 {
            let entry = Array(entries[index])
            if matchesPrefix(entry), entry != buffer {
                historyIndex = index
                buffer = entry
                cursor = buffer.count
                return
            }
            index -= 1
        }
    }

    private func historyNext() {
        guard let current = historyIndex else { return }
        let entries = history.entries
        var index = current + 1
        while index < entries.count {
            let entry = Array(entries[index])
            if matchesPrefix(entry), entry != buffer {
                historyIndex = index
                buffer = entry
                cursor = buffer.count
                return
            }
            index += 1
        }
        historyIndex = nil
        buffer = savedBuffer
        cursor = buffer.count
    }

    private func matchesPrefix(_ entry: [Character]) -> Bool {
        guard !historyPrefix.isEmpty else { return true }
        return entry.count >= historyPrefix.count && Array(entry[0..<historyPrefix.count]) == historyPrefix
    }

    private func insertLastArgument(continuing: Bool) {
        let entries = history.entries
        guard !entries.isEmpty else { return }
        var index: Int
        if continuing, let previous = lastArgumentIndex {
            if lastArgumentLength > 0, cursor >= lastArgumentLength {
                buffer.removeSubrange((cursor - lastArgumentLength)..<cursor)
                cursor -= lastArgumentLength
            }
            index = previous - 1
            if index < 0 { index = entries.count - 1 }
        } else {
            index = entries.count - 1
            recordUndo(typing: false)
        }
        let words = LineTokenizer.tokenize(entries[index]).filter { $0.kind == .word }
        let argument = words.last?.text ?? ""
        insertRaw(argument)
        lastArgumentIndex = index
        lastArgumentLength = argument.count
        lastKeyWasLastArgument = true
    }

    /// Expands `!!`, `!$`, `!^` and `!*` outside single quotes.
    public func expandHistoryReferences(_ line: String) -> String {
        guard line.contains("!"), let last = history.entries.last else { return line }
        let lastWords = LineTokenizer.tokenize(last).filter { $0.kind == .word }.map(\.text)
        var result = ""
        let characters = Array(line)
        var index = 0
        var inSingleQuote = false
        while index < characters.count {
            let c = characters[index]
            if c == "'" { inSingleQuote.toggle() }
            if c == "\\", index + 1 < characters.count, !inSingleQuote {
                result.append(c)
                result.append(characters[index + 1])
                index += 2
                continue
            }
            if c == "!", !inSingleQuote, index + 1 < characters.count {
                let next = characters[index + 1]
                switch next {
                case "!":
                    result += last
                    index += 2
                    continue
                case "$":
                    result += lastWords.last ?? ""
                    index += 2
                    continue
                case "^":
                    result += lastWords.count > 1 ? lastWords[1] : ""
                    index += 2
                    continue
                case "*":
                    result += lastWords.dropFirst().joined(separator: " ")
                    index += 2
                    continue
                default:
                    break
                }
            }
            result.append(c)
            index += 1
        }
        return result
    }

    // MARK: Reverse search

    private func handleSearchKey(_ key: Key) -> LineEditorOutput {
        guard var state = search else { return LineEditorOutput(text: redraw()) }
        switch key {
        case .character(let c):
            state.query.append(c)
            runSearch(&state, from: (state.matchIndex ?? history.entries.count - 1))
        case .backspace, .control("h"):
            if !state.query.isEmpty {
                state.query.removeLast()
                runSearch(&state, from: state.matchIndex ?? (history.entries.count - 1))
            }
        case .control("r"):
            if let match = state.matchIndex {
                runSearch(&state, from: match - 1)
            } else {
                runSearch(&state, from: history.entries.count - 1)
            }
        case .enter:
            exitSearch(state)
            return submit()
        case .control("c"):
            exitSearch(state, restoreOriginal: true)
            let output = moveToEndOfLine() + "^C\r\n"
            renderer.reset()
            isActive = false
            return LineEditorOutput(text: output, event: .cancel)
        case .control("g"), .escape:
            exitSearch(state)
            return LineEditorOutput(text: redraw())
        case .left, .right, .home, .end, .control("a"), .control("e"), .up, .down:
            exitSearch(state)
            return feed(key: key)
        case .paste(let text):
            state.query += text
            runSearch(&state, from: history.entries.count - 1)
        default:
            break
        }
        search = state
        return LineEditorOutput(text: redraw())
    }

    private func runSearch(_ state: inout SearchState, from start: Int) {
        let entries = history.entries
        guard !state.query.isEmpty else {
            state.matchIndex = nil
            state.failed = false
            return
        }
        var index = min(start, entries.count - 1)
        while index >= 0 {
            if entries[index].contains(state.query) {
                state.matchIndex = index
                state.failed = false
                return
            }
            index -= 1
        }
        state.failed = true
    }

    private func exitSearch(_ state: SearchState, restoreOriginal: Bool = false) {
        search = nil
        if restoreOriginal {
            buffer = state.original
            cursor = state.originalCursor
            return
        }
        if let match = state.matchIndex {
            buffer = Array(history.entries[match])
            cursor = buffer.count
        } else {
            buffer = state.original
            cursor = state.originalCursor
        }
        historyIndex = nil
    }

    // MARK: Completion

    private func complete() -> LineEditorOutput {
        guard let engine = completionEngine else { return LineEditorOutput(text: redraw()) }
        suggestionDismissed = true
        let result = engine.complete(line: text, cursor: cursor, snapshot: snapshotProvider())
        guard !result.candidates.isEmpty else {
            return LineEditorOutput(text: redraw())
        }
        if result.candidates.count == 1 {
            let candidate = result.candidates[0]
            replaceWord(result.wordRange, with: candidate.text + candidate.suffix)
            return LineEditorOutput(text: redraw())
        }
        if result.commonPrefix.count > result.word.count, result.commonPrefix.hasPrefix(result.word) {
            replaceWord(result.wordRange, with: result.commonPrefix)
            return LineEditorOutput(text: redraw())
        }
        // No progress possible: list the candidates under the line and redraw.
        let lines = CompletionEngine.formatListing(result.candidates, columns: configuration.columns, maxRows: configuration.listingRows)
        var output = renderer.moveToEnd(prompt: prompt, text: buffer, cursor: cursor, ghost: nil, columns: configuration.columns)
        output += "\r\n" + lines.joined(separator: "\r\n") + "\r\n"
        renderer.reset()
        output += redraw()
        return LineEditorOutput(text: output)
    }

    private func replaceWord(_ range: Range<Int>, with replacement: String) {
        recordUndo(typing: false)
        let lower = min(range.lowerBound, buffer.count)
        let upper = min(range.upperBound, buffer.count)
        buffer.replaceSubrange(lower..<upper, with: Array(replacement))
        cursor = lower + replacement.count
        historyIndex = nil
    }

    // MARK: Submit and rendering

    private func submit() -> LineEditorOutput {
        currentSuggestion = nil
        var output = finishLine()
        let line = text
        let expanded = expandHistoryReferences(line)
        if expanded != line {
            output += expanded + "\r\n"
        }
        isActive = false
        return LineEditorOutput(text: output, event: .submit(expanded))
    }

    /// Moves the cursor past the end of the drawn text and emits a newline, so whatever comes next
    /// starts on a fresh row.
    private func finishLine() -> String {
        let output = moveToEndOfLine() + "\r\n"
        renderer.reset()
        return output
    }

    /// Redraws the line without the ghost suggestion and leaves the cursor after its last character.
    private func moveToEndOfLine() -> String {
        renderer.render(prompt: currentPrompt(), segments: segments(for: buffer), cursor: buffer.count, ghost: nil, columns: configuration.columns)
    }

    private func segments(for shownText: [Character]) -> [StyledSegment] {
        var segments: [StyledSegment]
        if configuration.syntaxHighlighting, search == nil {
            let highlighter = Highlighter(snapshot: snapshotProvider())
            segments = Highlighter.segments(for: shownText, spans: highlighter.highlight(String(shownText)))
        } else {
            segments = [StyledSegment(String(shownText))]
        }
        if segments.isEmpty { segments = [StyledSegment("")] }
        return segments
    }

    private func currentPrompt() -> RenderedPrompt {
        if let state = search {
            let label = state.failed ? "(failed reverse-i-search)" : "(reverse-i-search)"
            return .plain("\(label)'\(state.query)': ")
        }
        return prompt
    }

    private func displayedText() -> [Character] {
        if let state = search, let match = state.matchIndex {
            return Array(history.entries[match])
        }
        if let state = search {
            return state.original
        }
        return buffer
    }

    private func redraw() -> String {
        let shownText = displayedText()
        let shownCursor = search == nil ? cursor : shownText.count
        let segments = segments(for: shownText)
        currentSuggestion = computeSuggestion()
        let ghost = currentSuggestion.map { String($0.dropFirst(buffer.count)) }
        return renderer.render(prompt: currentPrompt(), segments: segments, cursor: shownCursor, ghost: ghost, columns: configuration.columns)
    }
}
