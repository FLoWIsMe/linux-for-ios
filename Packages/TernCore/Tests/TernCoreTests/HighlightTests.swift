import XCTest
@testable import TernCore

final class HighlightTests: XCTestCase {
    private var snapshot: ShellSnapshot!
    private var existing: Set<String> = []

    override func setUp() {
        super.setUp()
        snapshot = ShellSnapshot(
            workingDirectory: "/tmp",
            homeDirectory: "/tmp",
            aliases: ["ll": "ls -l"],
            functionNames: ["deploy"],
            builtinNames: ["cd", "echo"],
            externalCommandNames: ["ls", "grep", "cat"],
            hostCommandNames: ["tern"]
        )
        existing = ["notes.txt", "/etc/hosts"]
    }

    private func highlighter() -> Highlighter {
        Highlighter(snapshot: snapshot) { [existing] path in existing.contains(path) }
    }

    private func style(_ spans: [HighlightSpan], at offset: Int) -> HighlightSpan.Style? {
        spans.first { $0.range.contains(offset) }?.style
    }

    func testCommandsOperatorsAndArguments() {
        let line = "ls -la | grep foo 'bar' $HOME # c"
        let spans = highlighter().highlight(line)
        XCTAssertEqual(style(spans, at: 0), .command)
        XCTAssertEqual(style(spans, at: 3), .option)
        XCTAssertEqual(style(spans, at: 7), .operatorToken)
        XCTAssertEqual(style(spans, at: 9), .command)
        XCTAssertEqual(style(spans, at: 14), .argument)
        XCTAssertEqual(style(spans, at: 18), .string)
        XCTAssertEqual(style(spans, at: 24), .variable)
        XCTAssertEqual(style(spans, at: 30), .comment)
    }

    func testUnknownCommandIsRed() {
        let spans = highlighter().highlight("nope arg")
        XCTAssertEqual(style(spans, at: 0), .invalidCommand)
        XCTAssertEqual(style(spans, at: 5), .argument)
    }

    func testAliasesFunctionsHostCommandsAndPathsAreValid() {
        XCTAssertEqual(style(highlighter().highlight("ll"), at: 0), .command)
        XCTAssertEqual(style(highlighter().highlight("deploy"), at: 0), .command)
        XCTAssertEqual(style(highlighter().highlight("tern theme"), at: 0), .command)
        XCTAssertEqual(style(highlighter().highlight("/etc/hosts"), at: 0), .command)
        XCTAssertEqual(style(highlighter().highlight("./missing"), at: 0), .invalidCommand)
    }

    func testAssignmentsReservedWordsAndCommandAfterOperators() {
        let spans = highlighter().highlight("FOO=1 ls && nope; if true; then echo x; fi")
        XCTAssertEqual(style(spans, at: 0), .assignment)
        XCTAssertEqual(style(spans, at: 6), .command)
        XCTAssertEqual(style(spans, at: 12), .invalidCommand)
        XCTAssertEqual(style(spans, at: 18), .reservedWord)
        XCTAssertEqual(style(spans, at: 21), .invalidCommand, "true is not in this snapshot's command list")
        XCTAssertEqual(style(spans, at: 27), .reservedWord)
        XCTAssertEqual(style(spans, at: 32), .command)
        XCTAssertEqual(style(spans, at: 40), .reservedWord)
    }

    func testPathsAreUnderlinedAndStringsWithVariables() {
        let spans = highlighter().highlight("cat notes.txt \"hello $USER\"")
        XCTAssertEqual(style(spans, at: 4), .path)
        XCTAssertEqual(style(spans, at: 15), .string)
        XCTAssertEqual(style(spans, at: 21), .variable)
    }

    func testRedirectionTargetIsNotACommand() {
        let spans = highlighter().highlight("echo hi > out.txt")
        XCTAssertEqual(style(spans, at: 8), .operatorToken)
        XCTAssertEqual(style(spans, at: 10), .argument)
    }

    func testSegmentsCoverWholeText() {
        let text = Array("ls -la")
        let spans = highlighter().highlight(String(text))
        let segments = Highlighter.segments(for: text, spans: spans)
        XCTAssertEqual(segments.map(\.text).joined(), "ls -la")
        XCTAssertEqual(segments.first?.sgr, ANSI.bold)
        XCTAssertEqual(segments.last?.sgr, ANSI.Color.cyan.foreground)
        XCTAssertEqual(Highlighter.segments(for: [], spans: []), [StyledSegment("")])
    }

    func testStyleColorsUseStandardPalette() {
        XCTAssertEqual(HighlightSpan.Style.invalidCommand.sgr, "\u{1b}[31m")
        XCTAssertEqual(HighlightSpan.Style.string.sgr, "\u{1b}[33m")
        XCTAssertEqual(HighlightSpan.Style.option.sgr, "\u{1b}[36m")
        XCTAssertEqual(HighlightSpan.Style.variable.sgr, "\u{1b}[35m")
        XCTAssertEqual(HighlightSpan.Style.comment.sgr, "\u{1b}[2m")
        XCTAssertEqual(HighlightSpan.Style.path.sgr, "\u{1b}[4m")
        XCTAssertEqual(HighlightSpan.Style.argument.sgr, "")
    }
}
