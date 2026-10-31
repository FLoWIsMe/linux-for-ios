import XCTest
@testable import TernCore

final class CompletionTests: XCTestCase {
    private var directory = ""
    private var snapshot: ShellSnapshot!
    private let engine = CompletionEngine()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = NSTemporaryDirectory() + "tern-completion-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory + "/.ssh", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: directory + "/docs", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: directory + "/data", withIntermediateDirectories: true)
        for name in ["notes.txt", "my file.txt", ".hidden", "run.sh", "Makefile"] {
            try "x".write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
        }
        try "#!/bin/sh\necho hi\n".write(toFile: directory + "/run.sh", atomically: true, encoding: .utf8)
        try "Host myserver\n  HostName 10.0.0.2\nHost *\n  User me\nHost pi backup\n".write(toFile: directory + "/.ssh/config", atomically: true, encoding: .utf8)
        try "github.com ssh-ed25519 AAAA\n|1|hashed= ssh-rsa BBBB\n[gitlab.example]:2222 ssh-rsa CCCC\n".write(toFile: directory + "/.ssh/known_hosts", atomically: true, encoding: .utf8)
        snapshot = ShellSnapshot(
            workingDirectory: directory,
            homeDirectory: directory,
            aliases: ["ll": "ls -l"],
            functionNames: ["deploy"],
            variableNames: ["HOME", "PATH", "HOSTNAME", "count"],
            environment: ["HOME": directory, "PATH": "/bin"],
            builtinNames: ["cd", "echo", "exit", "export"],
            externalCommandNames: ["ls", "git", "lg2", "cat", "grep", "ssh", "scp", "ping", "vim"],
            hostCommandNames: ["tern", "help"]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    private func texts(_ line: String) -> [String] {
        engine.complete(line: line, cursor: line.count, snapshot: snapshot).candidates.map(\.text)
    }

    func testContextDetection() {
        let first = CompletionEngine.context(line: "gr", cursor: 2, snapshot: snapshot)
        XCTAssertTrue(first.isCommandPosition)
        XCTAssertEqual(first.word, "gr")
        XCTAssertEqual(first.wordRange, 0..<2)

        let afterPipe = CompletionEngine.context(line: "ls | gr", cursor: 7, snapshot: snapshot)
        XCTAssertTrue(afterPipe.isCommandPosition)

        let argument = CompletionEngine.context(line: "git ch", cursor: 6, snapshot: snapshot)
        XCTAssertFalse(argument.isCommandPosition)
        XCTAssertEqual(argument.commandName, "git")
        XCTAssertEqual(argument.argumentIndex, 1)

        let afterPrefix = CompletionEngine.context(line: "sudo l", cursor: 6, snapshot: snapshot)
        XCTAssertTrue(afterPrefix.isCommandPosition)

        let afterAssignment = CompletionEngine.context(line: "FOO=1 ec", cursor: 8, snapshot: snapshot)
        XCTAssertTrue(afterAssignment.isCommandPosition)

        let emptyWord = CompletionEngine.context(line: "cd ", cursor: 3, snapshot: snapshot)
        XCTAssertEqual(emptyWord.word, "")
        XCTAssertEqual(emptyWord.wordRange, 3..<3)
        XCTAssertEqual(emptyWord.commandName, "cd")
    }

    func testCommandCompletionIncludesAliasesFunctionsAndHostCommands() {
        XCTAssertEqual(texts("l"), ["lg2", "ll", "ls"])
        XCTAssertEqual(texts("dep"), ["deploy"])
        XCTAssertEqual(texts("te"), ["tern"])
        XCTAssertEqual(texts("ex"), ["exit", "export"])
    }

    func testFileCompletion() {
        XCTAssertEqual(texts("cat no"), ["notes.txt"])
        XCTAssertEqual(texts("cat my"), ["my\\ file.txt"])
        XCTAssertEqual(texts("cat \"my"), ["\"my file.txt\""])
        XCTAssertEqual(texts("cat .h"), [".hidden"])
        XCTAssertFalse(texts("cat ").contains(".hidden"))
        XCTAssertTrue(texts("cat ").contains("docs/"))
        XCTAssertEqual(texts("cat d"), ["data/", "docs/"])
        XCTAssertEqual(texts("cat ~/no"), ["~/notes.txt"])
        XCTAssertEqual(texts("cat ~"), ["~/"])
        XCTAssertEqual(texts("cat ./ru"), ["./run.sh"])
        XCTAssertEqual(texts("cat make"), ["Makefile"], "case insensitive fallback when nothing matches exactly")
    }

    func testDirectoryOnlyCommands() {
        XCTAssertEqual(texts("cd "), ["data/", "docs/"])
        XCTAssertEqual(texts("pushd do"), ["docs/"])
        XCTAssertEqual(texts("rmdir n"), [])
    }

    func testExecutableCompletionInCommandPosition() {
        XCTAssertEqual(texts("./"), ["./data/", "./docs/", "./run.sh"])
    }

    func testVariableCompletion() {
        XCTAssertEqual(texts("echo $HO"), ["$HOME", "$HOSTNAME"])
        XCTAssertEqual(texts("echo ${co"), ["${count}"])
        XCTAssertEqual(engine.complete(line: "echo $HO", cursor: 8, snapshot: snapshot).candidates.first?.suffix, "")
    }

    func testHostCompletion() {
        XCTAssertEqual(texts("ssh my"), ["myserver"])
        XCTAssertEqual(texts("ssh root@g"), ["root@github.com", "root@gitlab.example"])
        XCTAssertEqual(texts("ping p"), ["pi"])
        XCTAssertEqual(texts("scp notes.txt b"), ["backup"])
        XCTAssertTrue(texts("ssh ").count >= 5)
        let hosts = CompletionEngine.knownHosts(homeDirectory: directory).sorted()
        XCTAssertEqual(hosts, ["backup", "github.com", "gitlab.example", "myserver", "pi"])
    }

    func testGitSubcommandsAndOptions() {
        XCTAssertEqual(texts("git ch"), ["checkout"])
        XCTAssertEqual(texts("lg2 pu"), ["pull", "push"])
        XCTAssertTrue(texts("git checkout ").contains("docs/"), "after the subcommand we are back to files")
        XCTAssertEqual(texts("ls -l"), ["-l"])
        XCTAssertTrue(texts("ls -").contains("-la") == false)
        XCTAssertTrue(texts("ls -").contains("-l"))
        XCTAssertEqual(texts("grep --col"), ["--color"])
        XCTAssertEqual(texts("unknowncmd -x"), [])
    }

    func testCustomProviderWins() {
        final class TernProvider: CompletionProvider {
            func completions(for context: CompletionContext) -> [CompletionCandidate]? {
                guard context.commandName == "tern" else { return nil }
                let subcommands = ["theme", "keyboard", "font", "help", "about"]
                if context.argumentIndex == 1 {
                    return subcommands.filter { $0.hasPrefix(context.word) }.map { CompletionCandidate(text: $0, kind: .subcommand) }
                }
                if context.argumentIndex == 2, context.previousWord == "theme" {
                    return ["light", "dark", "system"].filter { $0.hasPrefix(context.word) }.map { CompletionCandidate(text: $0, kind: .subcommand) }
                }
                return []
            }
        }
        let provider = TernProvider()
        let engine = CompletionEngine(providers: [provider])
        XCTAssertEqual(engine.complete(line: "tern th", cursor: 7, snapshot: snapshot).candidates.map(\.text), ["theme"])
        XCTAssertEqual(engine.complete(line: "tern theme d", cursor: 12, snapshot: snapshot).candidates.map(\.text), ["dark"])
        XCTAssertEqual(engine.complete(line: "cat no", cursor: 6, snapshot: snapshot).candidates.map(\.text), ["notes.txt"])
    }

    func testCommonPrefixAndListing() {
        XCTAssertEqual(CompletionEngine.commonPrefix(of: ["alpha", "alphabet", "alps"]), "alp")
        XCTAssertEqual(CompletionEngine.commonPrefix(of: []), "")
        XCTAssertEqual(CompletionEngine.commonPrefix(of: ["x"]), "x")
        let candidates = ["aa", "bb", "cc"].map { CompletionCandidate(text: $0, kind: .file) }
        XCTAssertEqual(CompletionEngine.formatListing(candidates, columns: 80), ["aa  bb  cc"])
        let many = (1...30).map { CompletionCandidate(text: String(format: "file%02d", $0), kind: .file) }
        let lines = CompletionEngine.formatListing(many, columns: 20, maxRows: 3)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.last, "... and 24 more")
        XCTAssertEqual(lines[0], "file01  file02")
    }

    func testTokenizer() {
        let tokens = LineTokenizer.tokenize("ls -la | grep 'a b' 2> /dev/null # done")
        let words = tokens.filter { $0.kind == .word }.map(\.text)
        XCTAssertEqual(words, ["ls", "-la", "grep", "'a b'", "/dev/null"])
        let operators = tokens.filter { $0.kind == .operatorToken }.map(\.text)
        XCTAssertEqual(operators, ["|", "2>"])
        XCTAssertEqual(tokens.last?.kind, .comment)
        XCTAssertTrue(LineTokenizer.tokenize("echo \"unterminated").last!.unterminated)
        XCTAssertEqual(LineTokenizer.unquote("'a b'\\ c\"d\""), "a b cd")
        XCTAssertEqual(LineTokenizer.escape("a b$c"), "a\\ b\\$c")
        XCTAssertTrue(LineTokenizer.isAssignment("FOO=bar"))
        XCTAssertFalse(LineTokenizer.isAssignment("=bar"))
        XCTAssertFalse(LineTokenizer.isAssignment("a-b=1"))
    }
}
