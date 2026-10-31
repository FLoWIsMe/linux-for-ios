import XCTest
@testable import TernCore

final class HistoryTests: XCTestCase {
    func testAppendRulesAndLimit() {
        let history = CommandHistory(fileURL: nil, limit: 3)
        history.append("one")
        history.append("one")
        history.append("")
        history.append("   ")
        history.append(" secret")
        history.append("two")
        XCTAssertEqual(history.entries, ["one", "two"])
        history.append("three")
        history.append("four")
        XCTAssertEqual(history.entries, ["two", "three", "four"])
        XCTAssertEqual(history.count, 3)
        history.clear()
        XCTAssertEqual(history.entries, [])
    }

    func testSuggestionAndSearch() {
        let history = CommandHistory(fileURL: nil, limit: 10)
        history.append("git status")
        history.append("git stash")
        history.append("ls")
        XCTAssertEqual(history.suggestion(forPrefix: "git s"), "git stash")
        XCTAssertNil(history.suggestion(forPrefix: "ls"))
        XCTAssertNil(history.suggestion(forPrefix: ""))
        XCTAssertNil(history.suggestion(forPrefix: "zzz"))
        XCTAssertEqual(history.search("git"), ["git stash", "git status"])
        XCTAssertEqual(history.search(""), ["ls", "git stash", "git status"])
    }

    func testPersistenceRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tern-history-\(UUID().uuidString)/history")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let history = CommandHistory(fileURL: url, limit: 100)
        history.append("echo one")
        history.append("for f in *; do\n  echo \"$f\"\ndone")
        history.append("printf 'a\\nb'")

        let reloaded = CommandHistory(fileURL: url, limit: 100)
        XCTAssertEqual(reloaded.entries, ["echo one", "for f in *; do\n  echo \"$f\"\ndone", "printf 'a\\nb'"])

        let limited = CommandHistory(fileURL: url, limit: 2)
        XCTAssertEqual(limited.entries.count, 2)
        XCTAssertEqual(limited.entries.first, "for f in *; do\n  echo \"$f\"\ndone")
    }

    func testEscapeRoundTrip() {
        for sample in ["plain", "with\nnewline", "back\\slash", "both\\\nhere", "trailing\\"] {
            XCTAssertEqual(CommandHistory.unescape(CommandHistory.escape(sample)), sample)
        }
    }
}
