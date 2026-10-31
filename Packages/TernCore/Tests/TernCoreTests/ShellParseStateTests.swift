import XCTest
@testable import TernCore

final class ShellParseStateTests: XCTestCase {
    func testCompleteInputs() {
        for source in [
            "echo hi", "echo hi; ls | wc -l", "if true; then echo a; fi", "for x in a b; do echo $x; done",
            "while false; do :; done", "case x in a) ;; esac", "f() { echo; }", "{ echo a; echo b; }", "(cd /; ls)",
            "echo \"quoted $(echo nested)\"", "echo $((1 + 2))", "x=1 y=2 cmd", "cat <<EOF\nbody\nEOF\n", "cat <<EOF\nbody\nEOF",
            "echo one &&\necho two", "[[ -n x && -z '' ]]", "echo 'a\nb'", "", "   ", "# just a comment", "echo \\\\",
            "echo a |\n cat", "echo \\$HOME", "sleep 1 &", "echo a; echo b &", "echo \"$(echo \"nested quotes\")\"",
        ] {
            XCTAssertEqual(Shell.parseState(of: source), .complete, source)
        }
    }

    func testIncompleteInputs() {
        let cases: [(String, String)] = [
            ("echo 'open", "quote"), ("echo \"open", "dquote"), ("echo `open", "backtick"), ("echo $(open", "$("),
            ("echo ${open", "${"), ("echo $((1 +", "$(("), ("if true; then echo a", "if"), ("for x in a; do", "for"),
            ("while true; do", "while"), ("until false; do", "until"), ("case x in a)", "case"), ("{ echo a", "{"),
            ("(echo a", "("), ("echo a |", "command"), ("echo a &&", "command"), ("echo a ||", "command"),
            ("echo a \\", "backslash"), ("cat <<EOF\nbody", "heredoc"), ("cat <<EOF", "heredoc"), ("[[ -n x", "[["),
            ("f() {", "{"), ("if true\nthen\necho a\nelse", "if"), ("echo \"$(echo 'x", "quote"), ("echo \"${x:-", "${"),
            ("for ((i=0; i<3; i++)); do", "for"), ("case x in", "case"), ("echo $( echo \"", "dquote"),
        ]
        for (source, hint) in cases {
            XCTAssertEqual(Shell.parseState(of: source), .incomplete(hint: hint), source)
        }
    }

    func testErrorInputs() {
        for source in ["fi", "done", "echo a ;; b", "if then fi", "x=(1 2)", "echo a | | b", "esac", "} ", ")", "echo a &&& b", "for in x; do :; done"] {
            if case .error = Shell.parseState(of: source) {
                continue
            }
            XCTFail("expected a syntax error for: \(source), got \(Shell.parseState(of: source))")
        }
    }

    func testRobustnessAgainstGarbage() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abc $(){}[]<>|&;'\"`\\\n#!=*?~-0123 if then fi for do done case esac in while")
        for _ in 0..<300 {
            let length = Int.random(in: 1...40, using: &generator)
            let source = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            // Must not crash or hang; the result itself does not matter.
            _ = Shell.parseState(of: source)
        }
        for source in ["$", "${", "${}", "$((", "echo ${#}", "echo ${!}", "echo $((1/0))", "echo ${x:?}", "x=${y:+}", "echo {1..}", "echo {..3}", "echo {a..1}", "printf '%'", "printf '%z'", "[[ ]]", "[[ -n ]]", "[ ( ]", "echo \u{0}", "echo \u{1}\u{2}"] {
            let result = ShellTesting.run(source)
            XCTAssertLessThanOrEqual(result.status, 255, source)
        }
    }

    /// Random programs must never crash or hang the interpreter. External commands are disabled by
    /// giving the executor an empty PATH; each case is interrupted if it runs too long.
    func testRunningGarbageNeverCrashes() {
        let executor = ProcessCommandExecutor(path: "")
        let directory = ShellTesting.makeTemporaryDirectory()
        var generator = SystemRandomNumberGenerator()
        let pieces = ["echo", "x", "$x", "${x:-y}", "$((1+", "))", "(", ")", "{", "}", ";", "|", "&&", "||", "&", "<", ">", ">>", "2>&1",
                      "'", "\"", "`", "\\", "if", "then", "else", "fi", "for", "in", "do", "done", "while", "case", "esac", "!", "[[", "]]",
                      "[", "]", "-n", "=", "==", "=~", "*", "?", "~", "{a,b}", "{1..3}", "\n", " ", "$(", "$@", "\"$@\"", "set", "--", "-e",
                      "local", "return", "break", "continue", "exit", "read", "printf", "%s", "%d", "test", "cd", "..", "export", "unset", "eval",
                      "f()", "shift", "$1", "$#", "<<EOF", "EOF", "<<<", "alias", "a=b", "trap", "EXIT", "wait", "jobs", "kill", "%1", "0", "1", "-1"]
        for _ in 0..<150 {
            let length = Int.random(in: 1...14, using: &generator)
            let source = (0..<length).map { _ in pieces.randomElement(using: &generator)! }.joined(separator: " ")
            let host = TestHost()
            let shell = Shell(executor: executor, host: host, environment: ["PATH": ""], workingDirectory: directory, homeDirectory: directory)
            shell.isInteractive = false
            let done = expectation(description: source)
            Thread.detachNewThread {
                _ = shell.run(source)
                done.fulfill()
            }
            let waiter = XCTWaiter()
            if waiter.wait(for: [done], timeout: 1.0) != .completed {
                shell.interrupt()
                XCTAssertEqual(waiter.wait(for: [done], timeout: 2.0), .completed, "hung on: \(source)")
            }
            _ = host.finish()
        }
    }

    func testLineNumbersInDiagnostics() {
        let result = ShellTesting.run("echo one\necho two\nnonexistent_cmd_xyz\necho four")
        XCTAssertEqual(result.stdout, "one\ntwo\nfour\n")
        XCTAssertTrue(result.stderr.contains("tsh: line 3: nonexistent_cmd_xyz: command not found"), result.stderr)
        let single = ShellTesting.run("nonexistent_cmd_xyz")
        XCTAssertTrue(single.stderr.hasPrefix("tsh: nonexistent_cmd_xyz: command not found"), single.stderr)
    }
}
