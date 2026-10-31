import XCTest
@testable import TernCore

/// The small coreutils style builtins that fill gaps in the ios_system toolchain.
final class ShellUtilitiesTests: XCTestCase {
    func testSeq() {
        assertShell("seq 3", prints: "1\n2\n3\n")
        assertShell("seq 2 4", prints: "2\n3\n4\n")
        assertShell("seq 1 2 7", prints: "1\n3\n5\n7\n")
        assertShell("seq 5 -2 1", prints: "5\n3\n1\n")
        assertShell("seq 0 0.5 1.5", prints: "0.0\n0.5\n1.0\n1.5\n")
        assertShell("seq -s , 1 4", prints: "1,2,3,4\n")
        assertShell("seq -w 8 11", prints: "08\n09\n10\n11\n")
        assertShell("seq -f '%03g' 1 2", prints: "001\n002\n")
        assertShell("seq 3 1", prints: "")
        let bad = ShellTesting.run("seq x; echo $?; seq -f '%s' 1; echo $?")
        XCTAssertEqual(bad.stdout, "2\n2\n")
        XCTAssertTrue(bad.stderr.contains("invalid floating point argument"), bad.stderr)
    }

    func testSeqFeedsLoopsAndPipes() {
        assertShell("for i in $(seq 3); do printf '%s-' $i; done; echo", prints: "1-2-3-\n")
        assertShell("seq 10 | tail -n 2", prints: "9\n10\n")
    }

    func testYesStopsWhenTheReaderGoesAway() {
        assertShell("yes | head -n 3", prints: "y\ny\ny\n")
        assertShell("yes hello world | head -n 2", prints: "hello world\nhello world\n")
    }

    func testCutFields() {
        assertShell("printf 'a:b:c\\nd:e:f\\n' | cut -d : -f 2", prints: "b\ne\n")
        assertShell("printf 'a:b:c\\n' | cut -d: -f1,3", prints: "a:c\n")
        assertShell("printf 'a:b:c:d\\n' | cut -d: -f2-", prints: "b:c:d\n")
        assertShell("printf 'a:b:c:d\\n' | cut -d: -f-2", prints: "a:b\n")
        assertShell("printf 'a\\tb\\tc\\n' | cut -f 3", prints: "c\n")
        assertShell("printf 'no delimiter\\nx:y\\n' | cut -d: -f2", prints: "no delimiter\ny\n")
        assertShell("printf 'no delimiter\\nx:y\\n' | cut -d: -s -f2", prints: "y\n")
        assertShell("printf 'a:b:c\\n' | cut -d: --output-delimiter=- -f1,2", prints: "a-b\n")
        assertShell("printf 'a:b:c\\n' | cut -d: --complement -f2", prints: "a:c\n")
    }

    func testCutCharactersAndBytes() {
        assertShell("echo abcdef | cut -c 2-4", prints: "bcd\n")
        assertShell("echo abcdef | cut -c1,6", prints: "af\n")
        assertShell("echo abcdef | cut -c4-", prints: "def\n")
        assertShell("echo héllo | cut -c 2", prints: "é\n")
        assertShell("echo abcdef | cut -b 1-3", prints: "abc\n")
        let bad = ShellTesting.run("echo x | cut; echo $?; echo x | cut -c 0; echo $?")
        XCTAssertEqual(bad.stdout, "2\n2\n")
    }

    func testCutReadsFiles() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        try "one,1\ntwo,2\n".write(toFile: directory + "/data.csv", atomically: true, encoding: .utf8)
        assertShell("cut -d, -f1 data.csv", prints: "one\ntwo\n", workingDirectory: directory)
        let missing = ShellTesting.run("cut -d, -f1 nope.csv; echo $?", workingDirectory: directory)
        XCTAssertEqual(missing.stdout, "1\n")
        XCTAssertTrue(missing.stderr.contains("nope.csv"), missing.stderr)
    }

    func testRevAndTac() {
        assertShell("printf 'abc\\nxyz\\n' | rev", prints: "cba\nzyx\n")
        assertShell("printf '1\\n2\\n3\\n' | tac", prints: "3\n2\n1\n")
        assertShell("printf 'no trailing newline' | rev", prints: "enilwen gniliart on\n")
    }

    func testMktempAndRealpath() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        let result = ShellTesting.run("f=$(mktemp); test -f \"$f\" && echo file-ok; d=$(mktemp -d); test -d \"$d\" && echo dir-ok; rm -r \"$f\" \"$d\"",
                                      workingDirectory: directory, environment: ["TMPDIR": directory])
        XCTAssertEqual(result.stdout, "file-ok\ndir-ok\n", result.stderr)
        let named = ShellTesting.run("mktemp build.XXXX | sed 's/[A-Za-z0-9]\\{4\\}$/XXXX/'", workingDirectory: directory)
        XCTAssertEqual(named.stdout, directory + "/build.XXXX\n")
        let short = ShellTesting.run("mktemp noX; echo $?", workingDirectory: directory)
        XCTAssertEqual(short.stdout, "1\n")

        try "x".write(toFile: directory + "/file", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: "file")
        let resolved = URL(fileURLWithPath: directory + "/file").resolvingSymlinksInPath().path
        assertShell("realpath link", prints: resolved + "\n", workingDirectory: directory)
        assertShell("realpath ./sub/../file", prints: resolved + "\n", workingDirectory: directory)
        let missing = ShellTesting.run("realpath missing; echo $?; realpath -m missing | grep -c missing", workingDirectory: directory)
        XCTAssertEqual(missing.stdout, "1\n1\n")
    }

    func testTty() {
        assertShell("echo | tty; echo $?", prints: "not a tty\n1\n")
    }

    func testUtilitiesAreBuiltinsAndComplete() {
        assertShell("type cut seq", prints: "cut is a shell builtin\nseq is a shell builtin\n")
        assertShell("type yes tac | cut -d' ' -f1,5", prints: "yes builtin\ntac builtin\n")
    }
}
