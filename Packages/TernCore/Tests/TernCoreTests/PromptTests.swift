import XCTest
@testable import TernCore

final class PromptTests: XCTestCase {
    func testMinimalAndClassic() {
        let minimal = PromptRenderer(style: .minimal).render(workingDirectory: "/x", homeDirectory: "/h", lastExitStatus: 0, gitBranch: nil)
        XCTAssertEqual(minimal, .plain("$ "))
        let classic = PromptRenderer(style: .classic, userName: "mobile", hostName: "tern")
            .render(workingDirectory: "/h/projects", homeDirectory: "/h", lastExitStatus: 1, gitBranch: "main")
        XCTAssertEqual(classic.text, "mobile@tern:~/projects$ ")
        XCTAssertEqual(classic.width, 24)
    }

    func testTernPromptWidthAndColors() {
        let renderer = PromptRenderer(style: .tern, accent: RGBColor(red: 255, green: 90, blue: 31))
        let prompt = renderer.render(workingDirectory: "/h/x", homeDirectory: "/h", lastExitStatus: 0, gitBranch: nil)
        XCTAssertEqual(ANSI.stripANSI(prompt.text), "~/x \u{276F} ")
        XCTAssertEqual(prompt.width, 6)
        XCTAssertTrue(prompt.text.contains("\u{1b}[38;2;255;90;31m"))
        XCTAssertEqual(ANSI.displayWidth(of: prompt.text), prompt.width)

        let withBranch = renderer.render(workingDirectory: "/h/x", homeDirectory: "/h", lastExitStatus: 0, gitBranch: "main")
        XCTAssertEqual(ANSI.stripANSI(withBranch.text), "~/x main \u{276F} ")
        XCTAssertEqual(withBranch.width, 11)

        let failed = renderer.render(workingDirectory: "/h", homeDirectory: "/h", lastExitStatus: 2, gitBranch: nil)
        XCTAssertTrue(failed.text.contains(ANSI.Color.red.foreground))
        XCTAssertFalse(failed.text.contains("\u{1b}[38;2;255;90;31m"))
        XCTAssertEqual(ANSI.stripANSI(failed.text), "~ \u{276F} ")

        let noAccent = PromptRenderer(style: .tern).render(workingDirectory: "/", homeDirectory: "/h", lastExitStatus: 0, gitBranch: nil)
        XCTAssertTrue(noAccent.text.contains(ANSI.Color.yellow.foreground))
        XCTAssertEqual(ANSI.stripANSI(noAccent.text), "/ \u{276F} ")
    }

    func testContinuationPrompts() {
        XCTAssertEqual(PromptRenderer(style: .tern).continuation().width, 2)
        XCTAssertEqual(ANSI.stripANSI(PromptRenderer(style: .tern).continuation().text), "\u{2026} ")
        XCTAssertEqual(PromptRenderer(style: .classic).continuation(), .plain("> "))
    }

    func testAbbreviate() {
        XCTAssertEqual(PromptRenderer.abbreviate(path: "/h", home: "/h"), "~")
        XCTAssertEqual(PromptRenderer.abbreviate(path: "/h/a/b", home: "/h/"), "~/a/b")
        XCTAssertEqual(PromptRenderer.abbreviate(path: "/hx", home: "/h"), "/hx")
        XCTAssertEqual(PromptRenderer.abbreviate(path: "", home: "/h"), "/")
    }

    func testGitBranchDetection() throws {
        let base = NSTemporaryDirectory() + "tern-prompt-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: base + "/repo/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/repo/src/deep", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }

        try "ref: refs/heads/main\n".write(toFile: base + "/repo/.git/HEAD", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBranchDetector.branch(forDirectory: base + "/repo"), "main")
        XCTAssertEqual(GitBranchDetector.branch(forDirectory: base + "/repo/src/deep"), "main")
        XCTAssertNil(GitBranchDetector.branch(forDirectory: base))

        try "0123456789abcdef0123456789abcdef01234567\n".write(toFile: base + "/repo/.git/HEAD", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBranchDetector.branch(forDirectory: base + "/repo"), "0123456")

        // Worktree style: .git is a file pointing at the real git directory.
        try fm.createDirectory(atPath: base + "/gitdir", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/wt", withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(toFile: base + "/gitdir/HEAD", atomically: true, encoding: .utf8)
        try "gitdir: \(base)/gitdir\n".write(toFile: base + "/wt/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBranchDetector.branch(forDirectory: base + "/wt"), "feature/x")
    }
}
