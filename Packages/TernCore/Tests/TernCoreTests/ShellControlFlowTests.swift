import XCTest
@testable import TernCore

final class ShellControlFlowTests: XCTestCase {
    func testIfElifElse() {
        assertShell("if true; then echo yes; fi", prints: "yes\n")
        assertShell("if false; then echo a; elif true; then echo b; else echo c; fi", prints: "b\n")
        assertShell("if false; then echo a; elif false; then echo b; else echo c; fi", prints: "c\n")
        assertShell("if false; then echo a; fi; echo $?", prints: "0\n")
        assertShell("if [ 3 -gt 2 ] && [ -n x ]; then echo both; fi", prints: "both\n")
        assertShell("""
        if [ -z "$EMPTY" ]
        then
            echo empty
        fi
        """, prints: "empty\n")
    }

    func testForLoops() {
        assertShell("for i in 1 2 3; do echo -n $i; done; echo", prints: "123\n")
        assertShell("for w in; do echo never; done; echo $?", prints: "0\n")
        assertShell("set -- x y; for a; do echo $a; done", prints: "x\ny\n")
        assertShell("for i in a b c; do if [ $i = b ]; then continue; fi; echo $i; done", prints: "a\nc\n")
        assertShell("for i in 1 2 3 4; do [ $i = 3 ] && break; echo $i; done", prints: "1\n2\n")
        assertShell("for i in 1 2; do for j in a b; do [ $j = b ] && break 2; echo $i$j; done; done", prints: "1a\n")
        assertShell("for i in 1 2; do for j in a b; do [ $j = a ] && continue 2; echo $i$j; done; done; echo end", prints: "end\n")
        assertShell("for ((i=0; i<5; i+=2)); do echo $i; done", prints: "0\n2\n4\n")
        assertShell("for i in {1..3}; do echo $((i * i)); done", prints: "1\n4\n9\n")
    }

    func testWhileUntil() {
        assertShell("i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i", prints: "3\n")
        assertShell("i=0; until [ $i -ge 3 ]; do i=$((i+1)); done; echo $i", prints: "3\n")
        assertShell("i=0; while true; do i=$((i+1)); [ $i -eq 5 ] && break; done; echo $i", prints: "5\n")
        assertShell("""
        while read line; do
            echo "got: $line"
        done <<EOF
        first
        second
        EOF
        """, prints: "got: first\ngot: second\n")
        assertShell("printf 'a\\nb\\n' | while read x; do echo \"[$x]\"; done", prints: "[a]\n[b]\n")
        assertShell("i=0; while [ $i -lt 2 ]; do echo $i; i=$((i+1)); done > /dev/null; echo done", prints: "done\n")
    }

    func testCase() {
        let script = """
        classify() {
            case "$1" in
                [0-9]) echo digit ;;
                [a-z]*) echo lower ;;
                *.txt|*.md) echo doc ;;
                "Hello There") echo quoted ;;
                *) echo other ;;
            esac
        }
        classify 7; classify abc; classify README.md; classify "Hello There"; classify ZZZ
        """
        assertShell(script, prints: "digit\nlower\ndoc\nquoted\nother\n")
        assertShell("case x in x) echo one;& y) echo two;; z) echo three;; esac", prints: "one\ntwo\n")
        assertShell("case x in x) echo one;;& x) echo again;; y) echo no;; esac", prints: "one\nagain\n")
        assertShell("case nothing in a) echo a;; esac; echo $?", prints: "0\n")
        assertShell("v='*'; case '*' in \"$v\") echo literal;; esac; case abc in $v) echo glob;; esac", prints: "literal\nglob\n")
        assertShell("case a in (a) echo paren;; esac", prints: "paren\n")
    }

    func testFunctions() {
        assertShell("greet() { echo \"hi $1\"; }; greet world", prints: "hi world\n")
        assertShell("function greet { echo \"hey $1 $#\"; }; greet you there", prints: "hey you 2\n")
        assertShell("f() { return 3; }; f; echo $?", prints: "3\n")
        assertShell("f() { echo before; return; echo after; }; f", prints: "before\n")
        assertShell("""
        fact() {
            local n=$1
            if [ "$n" -le 1 ]; then echo 1; return; fi
            local prev
            prev=$(fact $((n - 1)))
            echo $((n * prev))
        }
        fact 5
        """, prints: "120\n")
        assertShell("x=global; f() { local x=local; echo $x; g; }; g() { echo $x; }; f; echo $x", prints: "local\nlocal\nglobal\n")
        assertShell("f() { x=changed; }; f; echo $x", prints: "changed\n")
        assertShell("f() { echo $0 $1; }; set -- top; f arg; echo $1", prints: "tsh arg\ntop\n")
        assertShell("f() { shift; echo $@; }; f a b c", prints: "b c\n")
        assertShell("f() { echo inner > /dev/null; }; f; echo $?; g() { false; }; g; echo $?", prints: "0\n1\n")
        assertShell("f() { echo one; }; f() { echo two; }; f; unset -f f; f 2>/dev/null || echo gone", prints: "two\ngone\n")
        assertShell("outer() { inner() { echo nested; }; inner; }; outer; inner", prints: "nested\nnested\n")
        assertShell("recurse() { [ $1 -eq 0 ] && return 0; recurse $(($1 - 1)); }; recurse 200; echo ok", prints: "ok\n")
    }

    func testSubshellsAndGroups() {
        assertShell("(x=inside; echo $x); echo \"[$x]\"", prints: "inside\n[]\n")
        assertShell("{ x=inside; echo $x; }; echo $x", prints: "inside\ninside\n")
        assertShell("(cd /; pwd); pwd | grep -c tsh-tests", prints: "/\n1\n")
        assertShell("(exit 4); echo $?", prints: "4\n")
        assertShell("(echo a; echo b) | wc -l | tr -d ' '", prints: "2\n")
        assertShell("{ echo a; echo b; } > /dev/null; echo quiet", prints: "quiet\n")
        assertShell("x=1; (x=2; (x=3; echo $x); echo $x); echo $x", prints: "3\n2\n1\n")
    }

    func testExitAndStatus() {
        let result = ShellTesting.run("echo before; exit 7; echo after", interactive: true)
        XCTAssertEqual(result.stdout, "before\n")
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.host.exitStatus, 7)
        assertShell("f() { exit 5; }; (f); echo $?", prints: "5\n")
        assertShell("true && echo yes || echo no; false && echo yes || echo no", prints: "yes\nno\n")
        assertShell("false || false || echo third", prints: "third\n")
        assertShell("true && false && echo never; echo $?", prints: "1\n")
        assertShell("! false; echo $?; ! true; echo $?", prints: "0\n1\n")
        assertShell("true; false; echo $?", prints: "1\n")
    }

    func testErrexit() {
        let result = ShellTesting.run("set -e; echo one; false; echo two")
        XCTAssertEqual(result.stdout, "one\n")
        XCTAssertEqual(result.status, 1)
        assertShell("set -e; if false; then :; fi; echo survived", prints: "survived\n")
        assertShell("set -e; false || echo rescued; while false; do :; done; echo end", prints: "rescued\nend\n")
        assertShell("set -e; ! false; echo negated", prints: "negated\n")
        assertShell("set -e; false && echo no; echo still here", prints: "still here\n")
        let function = ShellTesting.run("set -e; f() { false; echo in; }; f; echo out")
        XCTAssertEqual(function.stdout, "")
        XCTAssertEqual(function.status, 1)
    }

    func testTraps() {
        assertShell("trap 'echo bye' EXIT; echo hi; exit 0", prints: "hi\nbye\n")
        assertShell("trap 'echo cleanup $?' EXIT; false; exit", prints: "cleanup 1\n", status: 1)
        assertShell("trap 'echo a' EXIT; trap - EXIT; exit 0", prints: "")
        assertShell("trap 'echo x' INT; trap", prints: "trap -- 'echo x' INT\n")
    }

    func testXtrace() {
        let result = ShellTesting.run("set -x; x=1; echo hi $x")
        XCTAssertEqual(result.stdout, "hi 1\n")
        XCTAssertTrue(result.stderr.contains("+ echo hi 1"), result.stderr)
    }

    func testEvalAndSource() throws {
        assertShell("cmd='echo evaluated'; eval $cmd", prints: "evaluated\n")
        assertShell("eval 'x=5; y=$((x + 1))'; echo $y", prints: "6\n")
        let directory = ShellTesting.makeTemporaryDirectory()
        try "value=sourced\nsay() { echo \"$value $1\"; }\necho args: $@\nreturn 3\necho not reached\n".write(toFile: directory + "/lib.sh", atomically: true, encoding: .utf8)
        assertShell("source lib.sh one two; echo $?; say hello; . ./lib.sh", prints: "args: one two\n3\nsourced hello\nargs:\n", status: 3, workingDirectory: directory)
        let missing = ShellTesting.run("source nope.sh; echo $?")
        XCTAssertEqual(missing.stdout, "1\n")
        XCTAssertTrue(missing.stderr.contains("nope.sh"))
    }

    func testScriptsRunThroughInterpreter() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        try "#!/bin/sh\necho \"script $1 $#\"\nexit 3\n".write(toFile: directory + "/run.sh", atomically: true, encoding: .utf8)
        chmod(directory + "/run.sh", 0o755)
        assertShell("./run.sh a b; echo $?", prints: "script a 2\n3\n", workingDirectory: directory)
        assertShell("sh run.sh z; echo $?", prints: "script z 1\n3\n", workingDirectory: directory)
        assertShell("bash -c 'echo \"$0 $1\"' name arg", prints: "name arg\n")
        assertShell("x=outer; sh -c 'echo \"[$x]\"'; export x; sh -c 'echo \"[$x]\"'", prints: "[]\n[outer]\n")
    }

    func testBackgroundJobs() {
        assertShell("sleep 0.2 & wait; echo waited", prints: "waited\n")
        assertShell("(sleep 0.1; echo late) & echo early; wait", prints: "early\nlate\n")
        let result = ShellTesting.run("sleep 0.1 & echo $!; wait $!; echo $?")
        XCTAssertEqual(result.stdout, "1\n0\n")
        assertShell("false & wait $!; echo $?", prints: "1\n")
        assertShell("sleep 5 & kill %1; wait; echo killed", prints: "killed\n")
        let timed = ShellTesting.run("sleep 5 & kill %1; wait; jobs; echo done")
        XCTAssertEqual(timed.stdout, "done\n")
        let listing = ShellTesting.run("sleep 0.3 & jobs")
        XCTAssertTrue(listing.stdout.hasPrefix("[1]  Running"), listing.stdout)
        XCTAssertTrue(listing.stdout.contains("sleep 0.3"), listing.stdout)
    }

    func testBackgroundKillIsFast() {
        let start = Date()
        assertShell("sleep 5 & sleep 0.05; kill %1; wait; echo fast", prints: "fast\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTimeKeyword() {
        let result = ShellTesting.run("time sleep 0.1")
        XCTAssertTrue(result.stderr.contains("real"), result.stderr)
        XCTAssertTrue(result.stderr.contains("0m0.1"), result.stderr)
    }

    func testInterruptRunsIntTrap() {
        let host = TestHost()
        let shell = ShellTesting.makeShell(host: host)
        let expectation = expectation(description: "finished")
        Thread.detachNewThread {
            shell.run("trap 'echo trapped' INT; sleep 30")
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        shell.interrupt()
        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(host.finish().stdout, "trapped\n")
    }

    func testInterruptStopsRunningCommand() {
        let host = TestHost()
        let shell = ShellTesting.makeShell(host: host)
        let expectation = expectation(description: "finished")
        var status: Int32 = -1
        Thread.detachNewThread {
            status = shell.run("sleep 30; echo after")
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        let start = Date()
        shell.interrupt()
        wait(for: [expectation], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(status, 130)
        XCTAssertEqual(host.finish().stdout, "")
        XCTAssertFalse(shell.isRunning)
    }

    func testInterruptStopsLoops() {
        let host = TestHost()
        let shell = ShellTesting.makeShell(host: host)
        let expectation = expectation(description: "finished")
        var status: Int32 = -1
        Thread.detachNewThread {
            status = shell.run("while true; do :; done; echo after")
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        shell.interrupt()
        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(status, 130)
    }
}
