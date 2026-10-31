import XCTest
@testable import TernCore

final class LineEditorKeyParserTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> [Key] {
        var parser = KeyParser()
        return parser.feed(bytes)
    }

    func testPrintableCharacters() {
        XCTAssertEqual(parse(Array("abc".utf8)), [.character("a"), .character("b"), .character("c")])
        XCTAssertEqual(parse(Array("é".utf8)), [.character("é")])
        XCTAssertEqual(parse(Array("日".utf8)), [.character("日")])
        XCTAssertEqual(parse([0x20]), [.character(" ")])
    }

    func testControlCharacters() {
        XCTAssertEqual(parse([0x0d]), [.enter])
        XCTAssertEqual(parse([0x0a]), [.enter])
        XCTAssertEqual(parse([0x09]), [.tab])
        XCTAssertEqual(parse([0x7f]), [.backspace])
        XCTAssertEqual(parse([0x08]), [.backspace])
        XCTAssertEqual(parse([0x01]), [.control("a")])
        XCTAssertEqual(parse([0x1a]), [.control("z")])
        XCTAssertEqual(parse([0x1f]), [.control("_")])
        XCTAssertEqual(parse([0x00]), [.control(" ")])
        XCTAssertEqual(parse([0x03, 0x04]), [.control("c"), .control("d")])
    }

    func testEscapeSequences() {
        XCTAssertEqual(parse(Array("\u{1b}[A".utf8)), [.up])
        XCTAssertEqual(parse(Array("\u{1b}[B".utf8)), [.down])
        XCTAssertEqual(parse(Array("\u{1b}[C".utf8)), [.right])
        XCTAssertEqual(parse(Array("\u{1b}[D".utf8)), [.left])
        XCTAssertEqual(parse(Array("\u{1b}OA".utf8)), [.up])
        XCTAssertEqual(parse(Array("\u{1b}OH".utf8)), [.home])
        XCTAssertEqual(parse(Array("\u{1b}[H".utf8)), [.home])
        XCTAssertEqual(parse(Array("\u{1b}[F".utf8)), [.end])
        XCTAssertEqual(parse(Array("\u{1b}[1~".utf8)), [.home])
        XCTAssertEqual(parse(Array("\u{1b}[4~".utf8)), [.end])
        XCTAssertEqual(parse(Array("\u{1b}[3~".utf8)), [.delete])
        XCTAssertEqual(parse(Array("\u{1b}[5~".utf8)), [.pageUp])
        XCTAssertEqual(parse(Array("\u{1b}[6~".utf8)), [.pageDown])
        XCTAssertEqual(parse(Array("\u{1b}[Z".utf8)), [.shiftTab])
        XCTAssertEqual(parse(Array("\u{1b}[1;5C".utf8)), [.ctrlRight])
        XCTAssertEqual(parse(Array("\u{1b}[1;5D".utf8)), [.ctrlLeft])
        XCTAssertEqual(parse(Array("\u{1b}[1;3D".utf8)), [.altLeft])
        XCTAssertEqual(parse(Array("\u{1b}[1;3C".utf8)), [.altRight])
        XCTAssertEqual(parse(Array("\u{1b}[1;2A".utf8)), [.shiftUp])
        XCTAssertEqual(parse(Array("\u{1b}OP".utf8)), [.function(1)])
        XCTAssertEqual(parse(Array("\u{1b}[15~".utf8)), [.function(5)])
    }

    func testAltAndEscape() {
        XCTAssertEqual(parse(Array("\u{1b}b".utf8)), [.alt("b")])
        XCTAssertEqual(parse(Array("\u{1b}.".utf8)), [.alt(".")])
        XCTAssertEqual(parse([0x1b, 0x7f]), [.altBackspace])
        XCTAssertEqual(parse([0x1b]), [.escape])
        XCTAssertEqual(parse([0x1b, 0x1b]), [.escape, .escape])
        XCTAssertEqual(parse([0x1b, 0x03]), [.escape, .control("c")])
    }

    func testUnknownSequenceIsReportedNotDropped() {
        let keys = parse(Array("\u{1b}[?25h".utf8))
        XCTAssertEqual(keys.count, 1)
        if case .unknown(let text) = keys[0] {
            XCTAssertEqual(text, "\u{1b}[?25h")
        } else {
            XCTFail("expected unknown, got \(keys)")
        }
    }

    func testSplitEscapeSequenceAcrossChunks() {
        var parser = KeyParser()
        XCTAssertEqual(parser.feed([0x1b, 0x5b]), [])
        XCTAssertEqual(parser.feed([0x41]), [.up])
        XCTAssertEqual(parser.feed([0x1b, 0x5b, 0x31]), [])
        XCTAssertEqual(parser.feed([0x3b, 0x35]), [])
        XCTAssertEqual(parser.feed([0x43, 0x61]), [.ctrlRight, .character("a")])
    }

    func testSplitUTF8AcrossChunks() {
        var parser = KeyParser()
        XCTAssertEqual(parser.feed([0xc3]), [])
        XCTAssertEqual(parser.feed([0xa9, 0x62]), [.character("é"), .character("b")])
        let euro = Array("€".utf8)
        XCTAssertEqual(parser.feed([euro[0]]), [])
        XCTAssertEqual(parser.feed([euro[1]]), [])
        XCTAssertEqual(parser.feed([euro[2]]), [.character("€")])
    }

    func testBracketedPaste() {
        let bytes = Array("\u{1b}[200~hello world\u{1b}[201~x".utf8)
        XCTAssertEqual(parse(bytes), [.paste("hello world"), .character("x")])

        var parser = KeyParser()
        XCTAssertEqual(parser.feed(Array("\u{1b}[200~ab".utf8)), [])
        XCTAssertEqual(parser.feed(Array("cd\u{1b}[20".utf8)), [])
        XCTAssertEqual(parser.feed(Array("1~".utf8)), [.paste("abcd")])
    }

    func testMixedInput() {
        let keys = parse(Array("ls\u{1b}[D\u{7f}\r".utf8))
        XCTAssertEqual(keys, [.character("l"), .character("s"), .left, .backspace, .enter])
    }
}
