import XCTest
@testable import TernCore

final class ANSITests: XCTestCase {
    func testDisplayWidthOfPlainText() {
        XCTAssertEqual(ANSI.displayWidth(of: "abc"), 3)
        XCTAssertEqual(ANSI.displayWidth(of: ""), 0)
        XCTAssertEqual(ANSI.displayWidth(of: "a b"), 3)
    }

    func testWideAndCombiningCharacters() {
        XCTAssertEqual(ANSI.displayWidth(of: "日本"), 4)
        XCTAssertEqual(ANSI.displayWidth(of: "e\u{301}"), 1)
        XCTAssertEqual(ANSI.displayWidth(of: "\u{1F600}"), 2)
        XCTAssertEqual(ANSI.displayWidth(of: "\u{276F}"), 1)
        XCTAssertEqual(ANSI.displayWidth(of: "\u{2026}"), 1)
        XCTAssertEqual(ANSI.width(of: "\u{200D}"), 0)
        XCTAssertEqual(ANSI.width(of: "\u{07}"), 0)
        XCTAssertEqual(ANSI.width(of: "A"), 1)
    }

    func testEscapeSequencesHaveNoWidth() {
        XCTAssertEqual(ANSI.displayWidth(of: "\u{1b}[31mred\u{1b}[0m"), 3)
        XCTAssertEqual(ANSI.displayWidth(of: "\u{1b}]0;title\u{07}x"), 1)
        XCTAssertEqual(ANSI.displayWidth(of: ANSI.sgr(38, 2, 255, 90, 31) + "ab"), 2)
    }

    func testStripANSI() {
        XCTAssertEqual(ANSI.stripANSI("\u{1b}[1;32mok\u{1b}[0m done"), "ok done")
        XCTAssertEqual(ANSI.stripANSI("plain"), "plain")
        XCTAssertEqual(ANSI.stripANSI("\u{1b}7a\u{1b}8"), "a")
    }

    func testBuilders() {
        XCTAssertEqual(ANSI.cursorUp(0), "")
        XCTAssertEqual(ANSI.cursorUp(3), "\u{1b}[3A")
        XCTAssertEqual(ANSI.cursorForward(2), "\u{1b}[2C")
        XCTAssertEqual(ANSI.sgr(1, 31), "\u{1b}[1;31m")
        XCTAssertEqual(ANSI.sgr([]), ANSI.reset)
        XCTAssertEqual(ANSI.Color.red.foreground, "\u{1b}[31m")
        XCTAssertEqual(ANSI.Color.brightBlack.background, "\u{1b}[100m")
        XCTAssertEqual(ANSI.cursorShape(.steadyBar), "\u{1b}[6 q")
        XCTAssertEqual(ANSI.foreground(RGBColor(red: 1, green: 2, blue: 3)), "\u{1b}[38;2;1;2;3m")
    }
}
