import XCTest
@testable import TernCore

final class LineEditorTests: XCTestCase {
    private var history: CommandHistory!
    private var snapshot: ShellSnapshot!

    override func setUp() {
        super.setUp()
        history = CommandHistory(fileURL: nil, limit: 100)
        snapshot = ShellSnapshot(
            workingDirectory: NSTemporaryDirectory(),
            homeDirectory: NSTemporaryDirectory(),
            builtinNames: ["cd", "echo", "exit"],
            externalCommandNames: ["ls", "git", "cat", "grep"]
        )
    }

    private func makeEditor(highlighting: Bool = false, suggestions: Bool = true, columns: Int = 80, completion: CompletionEngine? = nil) -> LineEditor {
        let configuration = LineEditorConfiguration(autosuggestions: suggestions, syntaxHighlighting: highlighting, columns: columns)
        let editor = LineEditor(configuration: configuration, history: history, completionEngine: completion) { [snapshot] in snapshot! }
        _ = editor.beginLine(prompt: .plain("$ "))
        return editor
    }

    private func type(_ editor: LineEditor, _ text: String) -> LineEditorOutput {
        editor.feed(bytes: Array(text.utf8))
    }

    // MARK: Rendering

    func testInitialPromptRendering() {
        let editor = LineEditor(configuration: LineEditorConfiguration(syntaxHighlighting: false), history: history) { [snapshot] in snapshot! }
        let output = editor.beginLine(prompt: .plain("$ "))
        XCTAssertEqual(output, "\r\u{1b}[J$ \r\u{1b}[2C")
    }

    func testTypingRedrawsWholeLine() {
        let editor = makeEditor()
        let output = editor.feed(key: .character("a"))
        XCTAssertEqual(output.text, "\r\u{1b}[J$ a\r\u{1b}[3C")
        XCTAssertEqual(output.event, .none)
        XCTAssertEqual(editor.text, "a")
    }

    func testCursorMovementRendersCorrectColumn() {
        let editor = makeEditor()
        _ = type(editor, "abc")
        let output = editor.feed(key: .left)
        XCTAssertEqual(output.text, "\r\u{1b}[J$ abc\r\u{1b}[4C")
        XCTAssertEqual(editor.cursor, 2)
    }

    func testWrappingLayout() {
        let prompt = RenderedPrompt.plain("$ ")
        let layout = LineRenderer.layout(prompt: prompt, text: Array("abcdefghij"), cursor: 10, ghost: "", columns: 10)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.endRow, 1)
        XCTAssertEqual(layout.endColumn, 2)
        XCTAssertEqual(layout.cursorRow, 1)
        XCTAssertEqual(layout.cursorColumn, 2)
        XCTAssertFalse(layout.pendingWrap)

        let exact = LineRenderer.layout(prompt: prompt, text: Array("abcdefgh"), cursor: 8, ghost: "", columns: 10)
        XCTAssertTrue(exact.pendingWrap)
        XCTAssertEqual(exact.rows, 2)
        XCTAssertEqual(exact.cursorRow, 1)
        XCTAssertEqual(exact.cursorColumn, 0)

        let middle = LineRenderer.layout(prompt: prompt, text: Array("abcdefghij"), cursor: 3, ghost: "", columns: 10)
        XCTAssertEqual(middle.cursorRow, 0)
        XCTAssertEqual(middle.cursorColumn, 5)
    }

    func testWideCharacterWrapsAsAWhole() {
        let prompt = RenderedPrompt.plain("$ ")
        let layout = LineRenderer.layout(prompt: prompt, text: Array("abcdefg日"), cursor: 8, ghost: "", columns: 10)
        XCTAssertEqual(layout.endRow, 1)
        XCTAssertEqual(layout.endColumn, 2)
        XCTAssertEqual(layout.cursorRow, 1)
        XCTAssertEqual(layout.cursorColumn, 2)
    }

    func testPromptWithEscapeCodesUsesDeclaredWidth() {
        let prompt = RenderedPrompt(text: "\u{1b}[2m~\u{1b}[0m \u{1b}[1m>\u{1b}[0m ", width: 4)
        let layout = LineRenderer.layout(prompt: prompt, text: Array("abcdef"), cursor: 6, ghost: "", columns: 10)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.cursorRow, 1)
        XCTAssertEqual(layout.cursorColumn, 0)
        XCTAssertTrue(layout.pendingWrap)
    }

    func testMultiRowRedrawMovesBackToFirstRow() {
        let editor = makeEditor(columns: 10)
        _ = type(editor, "abcdefghij")
        let output = editor.feed(key: .character("k"))
        // Previous drawing used two rows with the cursor on the second one.
        XCTAssertTrue(output.text.hasPrefix("\r\u{1b}[1A\u{1b}[J$ abcdefghijk"), output.text)
        XCTAssertTrue(output.text.hasSuffix("\r\u{1b}[3C"))
    }

    func testEmbeddedNewlinesRenderAsCRLF() {
        let editor = makeEditor()
        _ = editor.feed(key: .paste("echo a\necho b"))
        XCTAssertEqual(editor.text, "echo a\necho b")
        let output = editor.feed(key: .character("!"))
        XCTAssertTrue(output.text.contains("echo a\r\necho b!"))
    }

    // MARK: Editing

    func testBasicEditingKeys() {
        let editor = makeEditor()
        _ = type(editor, "hello")
        _ = editor.feed(key: .backspace)
        XCTAssertEqual(editor.text, "hell")
        _ = editor.feed(key: .home)
        _ = editor.feed(key: .delete)
        XCTAssertEqual(editor.text, "ell")
        _ = editor.feed(key: .end)
        _ = type(editor, "o")
        XCTAssertEqual(editor.text, "ello")
        _ = editor.feed(key: .control("a"))
        _ = type(editor, "h")
        XCTAssertEqual(editor.text, "hello")
        _ = editor.feed(key: .control("e"))
        XCTAssertEqual(editor.cursor, 5)
        _ = editor.feed(key: .control("b"))
        XCTAssertEqual(editor.cursor, 4)
        _ = editor.feed(key: .control("f"))
        XCTAssertEqual(editor.cursor, 5)
    }

    func testWordMovement() {
        let editor = makeEditor()
        _ = type(editor, "foo bar baz")
        _ = editor.feed(key: .home)
        _ = editor.feed(key: .alt("f"))
        XCTAssertEqual(editor.cursor, 3)
        _ = editor.feed(key: .ctrlRight)
        XCTAssertEqual(editor.cursor, 7)
        _ = editor.feed(key: .alt("b"))
        XCTAssertEqual(editor.cursor, 4)
        _ = editor.feed(key: .altLeft)
        XCTAssertEqual(editor.cursor, 0)
    }

    func testKillRingAndYank() {
        let editor = makeEditor()
        _ = type(editor, "hello world")
        _ = editor.feed(key: .control("w"))
        XCTAssertEqual(editor.text, "hello ")
        _ = editor.feed(key: .control("y"))
        XCTAssertEqual(editor.text, "hello world")
        _ = editor.feed(key: .home)
        _ = editor.feed(key: .control("k"))
        XCTAssertEqual(editor.text, "")
        _ = editor.feed(key: .control("y"))
        XCTAssertEqual(editor.text, "hello world")
        _ = editor.feed(key: .control("u"))
        XCTAssertEqual(editor.text, "")
        _ = editor.feed(key: .control("y"))
        XCTAssertEqual(editor.text, "hello world")
        _ = editor.feed(key: .alt("y"))
        XCTAssertEqual(editor.text, "hello world")
    }

    func testConsecutiveKillsAccumulate() {
        let editor = makeEditor()
        _ = type(editor, "one two three")
        _ = editor.feed(key: .control("w"))
        _ = editor.feed(key: .control("w"))
        XCTAssertEqual(editor.text, "one ")
        _ = editor.feed(key: .control("y"))
        XCTAssertEqual(editor.text, "one two three")
    }

    func testAltBackspaceAndAltD() {
        let editor = makeEditor()
        _ = type(editor, "git commit -m")
        _ = editor.feed(key: .altBackspace)
        XCTAssertEqual(editor.text, "git commit -")
        _ = editor.feed(key: .home)
        _ = editor.feed(key: .alt("d"))
        XCTAssertEqual(editor.text, " commit -")
    }

    func testTranspose() {
        let editor = makeEditor()
        _ = type(editor, "ab")
        _ = editor.feed(key: .control("t"))
        XCTAssertEqual(editor.text, "ba")
        _ = type(editor, "cd")
        _ = editor.feed(key: .left)
        _ = editor.feed(key: .left)
        _ = editor.feed(key: .control("t"))
        XCTAssertEqual(editor.text, "bacd".replacingOccurrences(of: "ac", with: "ca"))
    }

    func testUndoCoalescesTyping() {
        let editor = makeEditor()
        _ = type(editor, "abc")
        _ = editor.feed(key: .control("_"))
        XCTAssertEqual(editor.text, "")
        _ = type(editor, "ab")
        _ = editor.feed(key: .backspace)
        XCTAssertEqual(editor.text, "a")
        _ = editor.feed(key: .control("_"))
        XCTAssertEqual(editor.text, "ab")
        _ = editor.feed(key: .control("_"))
        XCTAssertEqual(editor.text, "")
    }

    func testCombiningMarkAttachesToPreviousCharacter() {
        let editor = makeEditor()
        _ = editor.feed(key: .character("e"))
        _ = editor.feed(key: .character("\u{301}"))
        XCTAssertEqual(editor.buffer.count, 1)
        XCTAssertEqual(editor.text, "e\u{301}")
        XCTAssertEqual(editor.cursor, 1)
    }

    func testPasteSanitizesControlCharacters() {
        let editor = makeEditor()
        _ = editor.feed(key: .paste("a\u{07}b\tc\r\nd"))
        XCTAssertEqual(editor.text, "ab\tc\nd")
    }

    // MARK: Submit, cancel, EOF

    func testSubmitReturnsLineAndNewline() {
        let editor = makeEditor()
        let output = type(editor, "echo hi\r")
        XCTAssertEqual(output.event, .submit("echo hi"))
        XCTAssertTrue(output.text.hasSuffix("echo hi\r\n"), output.text)
        XCTAssertFalse(editor.isActive)
    }

    func testTypeAheadAfterSubmitIsReturnedUnconsumed() {
        let editor = makeEditor()
        let output = type(editor, "ls\rpwd")
        XCTAssertEqual(output.event, .submit("ls"))
        XCTAssertEqual(output.unconsumed, [.character("p"), .character("w"), .character("d")])
    }

    func testCancelPrintsControlC() {
        let editor = makeEditor()
        _ = type(editor, "abc")
        let output = editor.feed(key: .control("c"))
        XCTAssertEqual(output.event, .cancel)
        XCTAssertTrue(output.text.hasSuffix("^C\r\n"))
        XCTAssertFalse(editor.isActive)
    }

    func testControlDOnEmptyLineIsEOFOtherwiseDeletes() {
        let editor = makeEditor()
        _ = type(editor, "ab")
        _ = editor.feed(key: .home)
        _ = editor.feed(key: .control("d"))
        XCTAssertEqual(editor.text, "b")
        _ = editor.feed(key: .control("d"))
        XCTAssertEqual(editor.text, "")
        let output = editor.feed(key: .control("d"))
        XCTAssertEqual(output.event, .eof)
    }

    func testClearScreen() {
        let editor = makeEditor()
        _ = type(editor, "ls")
        let output = editor.feed(key: .control("l"))
        XCTAssertEqual(output.event, .clearScreen)
        XCTAssertTrue(output.text.hasPrefix(ANSI.clearScreen))
        XCTAssertTrue(output.text.contains("$ ls"))
        XCTAssertTrue(editor.isActive)
    }

    func testHistoryExpansionOnSubmit() {
        history.append("ls -la /tmp")
        let editor = makeEditor()
        let output = type(editor, "!!\r")
        XCTAssertEqual(output.event, .submit("ls -la /tmp"))
        XCTAssertTrue(output.text.hasSuffix("ls -la /tmp\r\n"))

        let second = makeEditor()
        let out2 = type(second, "echo !$\r")
        XCTAssertEqual(out2.event, .submit("echo /tmp"))

        let third = makeEditor()
        XCTAssertEqual(type(third, "echo '!!'\r").event, .submit("echo '!!'"))
    }

    // MARK: History navigation

    func testHistoryUpDown() {
        history.append("ls")
        history.append("cd /tmp")
        history.append("ls -la")
        let editor = makeEditor()
        _ = editor.feed(key: .up)
        XCTAssertEqual(editor.text, "ls -la")
        _ = editor.feed(key: .up)
        XCTAssertEqual(editor.text, "cd /tmp")
        _ = editor.feed(key: .down)
        XCTAssertEqual(editor.text, "ls -la")
        _ = editor.feed(key: .down)
        XCTAssertEqual(editor.text, "")
    }

    func testHistoryPrefixSearch() {
        history.append("ls")
        history.append("cd /tmp")
        history.append("ls -la")
        let editor = makeEditor(suggestions: false)
        _ = type(editor, "ls")
        _ = editor.feed(key: .up)
        XCTAssertEqual(editor.text, "ls -la")
        _ = editor.feed(key: .control("p"))
        XCTAssertEqual(editor.text, "ls")
        _ = editor.feed(key: .up)
        XCTAssertEqual(editor.text, "ls")
        _ = editor.feed(key: .down)
        XCTAssertEqual(editor.text, "ls -la")
        _ = editor.feed(key: .control("n"))
        XCTAssertEqual(editor.text, "ls")
    }

    func testReverseSearch() {
        history.append("ls")
        history.append("cd /tmp")
        history.append("cd /var")
        history.append("echo done")
        let editor = makeEditor()
        _ = editor.feed(key: .control("r"))
        let output = type(editor, "cd")
        XCTAssertTrue(output.text.contains("(reverse-i-search)'cd': cd /var"), output.text)
        let again = editor.feed(key: .control("r"))
        XCTAssertTrue(again.text.contains("(reverse-i-search)'cd': cd /tmp"), again.text)
        let failing = type(editor, "x")
        XCTAssertTrue(failing.text.contains("(failed reverse-i-search)'cdx': cd /tmp"), failing.text)
        _ = editor.feed(key: .backspace)
        let submit = editor.feed(key: .enter)
        XCTAssertEqual(submit.event, .submit("cd /tmp"))
    }

    func testReverseSearchEscapeKeepsMatch() {
        history.append("git status")
        let editor = makeEditor()
        _ = editor.feed(key: .control("r"))
        _ = type(editor, "stat")
        _ = editor.feed(key: .escape)
        XCTAssertEqual(editor.text, "git status")
        XCTAssertTrue(editor.isActive)
        let output = editor.feed(key: .character("!"))
        XCTAssertTrue(output.text.contains("$ git status!"))
    }

    // MARK: Autosuggestions

    func testAutosuggestionGhostAndAccept() {
        history.append("git status")
        let editor = makeEditor()
        let output = type(editor, "git s")
        XCTAssertTrue(output.text.contains("\u{1b}[2;90mtatus\u{1b}[0m"), output.text)
        XCTAssertTrue(output.text.hasSuffix("\r\u{1b}[7C"), output.text)
        _ = editor.feed(key: .right)
        XCTAssertEqual(editor.text, "git status")
    }

    func testAutosuggestionAcceptWordAndDismiss() {
        history.append("git commit -m fix")
        let editor = makeEditor()
        _ = type(editor, "git c")
        _ = editor.feed(key: .alt("f"))
        XCTAssertEqual(editor.text, "git commit ")
        _ = editor.feed(key: .escape)
        let output = editor.feed(key: .control("e"))
        XCTAssertFalse(output.text.contains("\u{1b}[2;90m"))
        XCTAssertEqual(editor.text, "git commit ")
    }

    func testAltDotInsertsLastArgument() {
        history.append("cp a b")
        history.append("mv x y")
        let editor = makeEditor()
        _ = type(editor, "ls ")
        _ = editor.feed(key: .alt("."))
        XCTAssertEqual(editor.text, "ls y")
        _ = editor.feed(key: .alt("."))
        XCTAssertEqual(editor.text, "ls b")
    }

    // MARK: Completion

    func testTabCompletionOfCommandsAndFiles() throws {
        let directory = try makeTemporaryDirectory(files: ["alpha.txt", "alphabet.md"], directories: ["beta"])
        snapshot = ShellSnapshot(workingDirectory: directory, homeDirectory: directory, builtinNames: ["cd", "echo", "exit"], externalCommandNames: ["ls", "git", "cat", "grep"])
        let editor = makeEditor(completion: CompletionEngine())

        _ = type(editor, "ex")
        _ = editor.feed(key: .tab)
        XCTAssertEqual(editor.text, "exit ")

        _ = editor.feed(key: .control("u"))
        _ = type(editor, "cat al")
        _ = editor.feed(key: .tab)
        XCTAssertEqual(editor.text, "cat alpha")
        let listing = editor.feed(key: .tab)
        XCTAssertTrue(listing.text.contains("alpha.txt"), listing.text)
        XCTAssertTrue(listing.text.contains("alphabet.md"), listing.text)
        XCTAssertTrue(listing.text.hasSuffix("\r\u{1b}[J$ cat alpha\r\u{1b}[11C"), listing.text)

        _ = editor.feed(key: .control("u"))
        _ = type(editor, "cat be")
        _ = editor.feed(key: .tab)
        XCTAssertEqual(editor.text, "cat beta/")
    }

    // MARK: Helpers

    private func makeTemporaryDirectory(files: [String], directories: [String]) throws -> String {
        let base = NSTemporaryDirectory() + "tern-editor-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        for file in files {
            try "x".write(toFile: base + "/" + file, atomically: true, encoding: .utf8)
        }
        for directory in directories {
            try FileManager.default.createDirectory(atPath: base + "/" + directory, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
        return base
    }
}
