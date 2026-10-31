import XCTest
@testable import TernCore

#if os(macOS)
/// Runs portable POSIX snippets through both Tern's interpreter and the system `/bin/sh` and expects
/// identical standard output.
final class ShellDifferentialTests: XCTestCase {
    static let snippets: [String] = [
        "echo hello world",
        "x=5; y=7; echo $((x * y + 1)) $((y % x)) $((x ** 2))",
        "for i in 1 2 3; do printf '%s-' $i; done; echo",
        "i=0; while [ $i -lt 4 ]; do i=$((i + 1)); echo $i; done",
        "case abc in a*) echo starts-with-a;; *) echo other;; esac",
        "f() { echo \"args=$# first=$1\"; return 2; }; f one two; echo \"status=$?\"",
        "set -- a 'b c' d; for a in \"$@\"; do echo \"[$a]\"; done; echo \"$*\"",
        "v=hello; echo ${v#he} ${v%lo} ${#v} ${v:-x} ${unset_var:-default}",
        "printf '%5d|%-5s|%05.1f|%x\\n' 42 ab 3.14159 255",
        "echo one | tr o 0; echo two | sed 's/t/T/'",
        "if [ -d /tmp ] && [ ! -f /tmp ]; then echo dir; else echo nodir; fi",
        "x='a b  c'; set -- $x; echo $#; IFS=:; y='p:q:r'; set -- $y; echo $# $2",
        "cat <<EOF\nheredoc $((1+1))\n  kept\nEOF",
        "echo a; (echo b; exit 3); echo $?",
        "true && echo and || echo or; false && echo and || echo or; ! false && echo negated",
        "n=3; until [ $n -eq 0 ]; do echo $n; n=$((n-1)); done",
        "x=1; { x=2; }; echo $x; (x=3); echo $x",
        "echo \"nested $(echo \"$(echo inner)\")\" `echo back`",
        "printf '%s\\n' 'line1' 'line2' | while read l; do echo \"<$l>\"; done",
        "a=1; b=2; echo $a$b ${a}x \"$a $b\" '$a'",
        "echo ~ | grep -c /",
        "s='path/to/file.txt'; echo ${s##*/} ${s%/*} ${s%%/*}",
        "f() { local_var=inner; }; f; echo $local_var",
        "set -e; echo before; (false); echo after-subshell || true",
        "echo \"$(printf 'a\\nb\\n\\n')\" | wc -l | tr -d ' '",
        "exec 3>&1; echo via3 >&3; exec 3>&-",
        "umask | tr -d '\\n'; echo",
        "i=0; for w in x y z; do i=$((i+1)); [ $w = y ] && continue; echo $i$w; done",
        "echo \"$((2#101 + 0x10 + 010))\"",
        "x=abc; [ \"${x}\" = abc ] && echo eq; [ \"$x\" != abd ] && echo ne; test -z \"\" && echo empty",
    ]

    func testSnippetsMatchSystemShell() throws {
        for snippet in ShellDifferentialTests.snippets {
            let expected = try runSystemShell(snippet)
            let result = ShellTesting.run(snippet)
            XCTAssertEqual(result.stdout, expected, "snippet: \(snippet)\nstderr: \(result.stderr)")
        }
    }

    private func runSystemShell(_ snippet: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", snippet]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSTemporaryDirectory()
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
