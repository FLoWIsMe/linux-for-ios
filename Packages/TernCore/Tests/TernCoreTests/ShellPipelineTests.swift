import XCTest
@testable import TernCore

final class ShellPipelineTests: XCTestCase {
    func testPipelinesWithExternalCommands() {
        assertShell("printf 'b\\na\\nc\\n' | sort | head -2", prints: "a\nb\n")
        assertShell("echo hello world | tr a-z A-Z", prints: "HELLO WORLD\n")
        assertShell("printf 'x\\ny\\nx\\n' | sort | uniq -c | sort -rn | head -1 | awk '{print $1, $2}'", prints: "2 x\n")
        assertShell("echo one | cat | cat | cat", prints: "one\n")
        assertShell("seq 1 1000 | wc -l | tr -d ' '", prints: "1000\n")
        assertShell("seq 1 100000 | tail -1", prints: "100000\n")
    }

    func testPipelinesMixBuiltinsAndCompounds() {
        assertShell("echo a | { read x; echo \"read $x\"; }", prints: "read a\n")
        assertShell("printf '3\\n1\\n2\\n' | while read n; do echo $((n * 10)); done | sort", prints: "10\n20\n30\n")
        assertShell("for i in 3 1 2; do echo $i; done | sort", prints: "1\n2\n3\n")
        assertShell("echo x | read v; echo \"[$v]\"", prints: "[]\n")
        assertShell("(echo a; echo b) | (read first; echo first=$first)", prints: "first=a\n")
        assertShell("if echo cond | grep -q cond; then echo matched; fi", prints: "matched\n")
        assertShell("printf 'a\\nb\\n' | cat | while read l; do echo \"<$l>\"; done", prints: "<a>\n<b>\n")
        assertShell("yes | head -3", prints: "y\ny\ny\n")
        assertShell("i=0; while :; do echo $i; i=$((i+1)); done | head -2", prints: "0\n1\n")
    }

    func testPipelineStatusAndPipefail() {
        assertShell("false | true; echo $?", prints: "0\n")
        assertShell("true | false; echo $?", prints: "1\n")
        assertShell("set -o pipefail; false | true; echo $?; (exit 3) | (exit 0); echo $?", prints: "1\n3\n")
        assertShell("! true | false; echo $?", prints: "0\n")
        assertShell("echo err 1>&2 | cat; ls /nonexistent-tsh 2>&1 | grep -c 'No such'", prints: "err\n1\n")
        assertShell("ls /nonexistent-tsh |& grep -c 'No such'", prints: "1\n")
    }

    func testRedirections() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        assertShell("echo one > f.txt; echo two >> f.txt; cat f.txt", prints: "one\ntwo\n", workingDirectory: directory)
        assertShell("echo over > f.txt; cat < f.txt", prints: "over\n", workingDirectory: directory)
        assertShell("echo to-err >&2; echo to-err2 1>&2", prints: "", workingDirectory: directory)
        let both = ShellTesting.run("echo out; echo err >&2", workingDirectory: directory)
        XCTAssertEqual(both.stdout, "out\n")
        XCTAssertEqual(both.stderr, "err\n")
        assertShell("{ echo o; echo e >&2; } > both.txt 2>&1; cat both.txt", prints: "o\ne\n", workingDirectory: directory)
        assertShell("{ echo o; echo e >&2; } &> amp.txt; cat amp.txt; echo more &>> amp.txt; wc -l < amp.txt | tr -d ' '", prints: "o\ne\n3\n", workingDirectory: directory)
        assertShell("echo hidden > /dev/null; echo shown", prints: "shown\n", workingDirectory: directory)
        assertShell("echo to-stderr-device > /dev/stderr; echo ok", prints: "ok\n", workingDirectory: directory)
        assertShell("cat <<< 'here string'", prints: "here string\n", workingDirectory: directory)
        assertShell("""
        name=World
        cat <<EOF
        Hello $name
          indented $((1 + 1))
        EOF
        cat <<'EOF'
        No $expansion here
        EOF
        cat <<-EOF
        \ttabs stripped
        EOF
        """, prints: "Hello World\n  indented 2\nNo $expansion here\ntabs stripped\n", workingDirectory: directory)
        assertShell("cat <<EOF | tr a-z A-Z\nlower\nEOF", prints: "LOWER\n", workingDirectory: directory)
        assertShell("exec 3> fd3.txt; echo via3 >&3; exec 3>&-; cat fd3.txt", prints: "via3\n", workingDirectory: directory)
        assertShell("echo a > out.txt 2> err.txt; cat out.txt; cat err.txt | wc -c | tr -d ' '", prints: "a\n0\n", workingDirectory: directory)
        assertShell("exec 5>&1; exec > redirected.txt; echo captured; exec 1>&5; echo back", prints: "back\n", workingDirectory: directory)
        assertShell("cat redirected.txt", prints: "captured\n", workingDirectory: directory)
        let missing = ShellTesting.run("cat < does-not-exist.txt; echo $?", workingDirectory: directory)
        XCTAssertEqual(missing.stdout, "1\n")
        XCTAssertTrue(missing.stderr.contains("does-not-exist.txt: No such file or directory"), missing.stderr)
        assertShell("echo x > sub/dir/file 2>/dev/null || echo failed", prints: "failed\n", workingDirectory: directory)
        assertShell("while read l; do echo \"$l!\"; done < f.txt", prints: "over!\n", workingDirectory: directory)
        assertShell("f() { cat; } ; echo piped-into-function | f; f < f.txt", prints: "piped-into-function\nover\n", workingDirectory: directory)
        assertShell("echo 'read write' > rw.txt; exec 4<> rw.txt; read -u 4 x 2>/dev/null; cat <&4; exec 4>&-", prints: "read write\n", workingDirectory: directory)
    }

    func testLargeHeredocDoesNotDeadlock() {
        let big = (1...20000).map { "line \($0)" }.joined(separator: "\n")
        assertShell("cat <<EOF | wc -l | tr -d ' '\n\(big)\nEOF", prints: "20000\n")
        let output = ShellTesting.run("x=$(seq 1 50000); echo \"${#x}\"")
        XCTAssertEqual(output.stdout, "288893\n")
    }

    func testTerminalInputGoesToExternalCommands() {
        let result = ShellTesting.run("cat | tr a-z A-Z", terminalInput: "typed text\n")
        XCTAssertEqual(result.stdout, "TYPED TEXT\n")
        XCTAssertEqual(result.host.openedTerminalInputs, 1)
        let withRedirect = ShellTesting.run("echo file | cat; cat < /dev/null", terminalInput: "never\n")
        XCTAssertEqual(withRedirect.stdout, "file\n")
        XCTAssertEqual(withRedirect.host.openedTerminalInputs, 0)
    }

    func testHostNotifications() {
        let result = ShellTesting.run("sleep 0; cd /; ls / > /dev/null")
        XCTAssertEqual(result.host.startedCommands, [["sleep", "0"], ["ls", "/"]])
        XCTAssertEqual(result.host.finishedCommands.map { $0.1 }, [0, 0])
        XCTAssertEqual(result.host.directoryChanges, ["/"])
    }

    func testCaptureAndSnapshot() {
        let host = TestHost()
        let shell = ShellTesting.makeShell(host: host)
        shell.run("alias ll='ls -l'; greet() { echo hi; }; export MARK=1; cd /")
        let snapshot = shell.snapshot()
        XCTAssertEqual(snapshot.workingDirectory, "/")
        XCTAssertEqual(snapshot.aliases["ll"], "ls -l")
        XCTAssertEqual(snapshot.functionNames, ["greet"])
        XCTAssertEqual(snapshot.environment["MARK"], "1")
        XCTAssertTrue(snapshot.externalCommandNames.contains("ls"))
        XCTAssertTrue(snapshot.allCommandNames.contains("greet"))
        XCTAssertTrue(snapshot.allCommandNames.contains("cd"))
        XCTAssertEqual(shell.value(of: "MARK"), "1")
        XCTAssertEqual(shell.capture("echo captured; echo twice").output, "captured\ntwice")
        XCTAssertEqual(shell.capture("exit 4").status, 4)
        XCTAssertEqual(shell.lastExitStatus, 4)
        shell.setValue("fresh", for: "NEWVAR")
        XCTAssertEqual(shell.capture("echo $NEWVAR").output, "fresh")
        XCTAssertEqual(shell.resolvePath("~/x/../y"), shell.homeDirectory + "/y")
        XCTAssertEqual(shell.resolvePath("$HOME/z"), shell.homeDirectory + "/z")
        XCTAssertEqual(shell.resolvePath("etc"), "/etc")
        XCTAssertFalse(shell.isRunning)
        _ = host.finish()
    }

    func testRunFile() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        try "echo \"$0 got $# args: $@\"\ntrap 'echo exit trap' EXIT\nexit 9\n".write(toFile: directory + "/script.sh", atomically: true, encoding: .utf8)
        let host = TestHost()
        let shell = ShellTesting.makeShell(host: host, workingDirectory: directory)
        let status = shell.runFile(atPath: "script.sh", arguments: ["a", "b"])
        XCTAssertEqual(status, 9)
        XCTAssertNil(host.exitStatus, "exit inside a script must not end the interactive shell")
        XCTAssertEqual(host.finish().stdout, "script.sh got 2 args: a b\nexit trap\n")
        XCTAssertEqual(shell.value(of: "0"), nil)
        let missing = ShellTesting.makeShell(host: TestHost())
        XCTAssertEqual(missing.runFile(atPath: "nope.sh"), 127)
    }

    func testDiagnosticsFormat() {
        let syntax = ShellTesting.run("echo ok\nif then\necho never")
        XCTAssertEqual(syntax.stdout, "ok\n")
        XCTAssertEqual(syntax.status, 2)
        XCTAssertTrue(syntax.stderr.contains("line 2"), syntax.stderr)
        XCTAssertTrue(syntax.stderr.contains("syntax error near unexpected token `then'"), syntax.stderr)
        let unterminated = ShellTesting.run("echo 'open")
        XCTAssertTrue(unterminated.stderr.contains("unexpected EOF while looking for matching `''"), unterminated.stderr)
        let array = ShellTesting.run("arr=(1 2 3)")
        XCTAssertTrue(array.stderr.contains("arrays are not supported"), array.stderr)
        XCTAssertEqual(array.status, 2)
    }
}
