import XCTest
@testable import TernCore

final class ShellExpansionTests: XCTestCase {
    // MARK: Quoting

    func testQuotingForms() {
        assertShell("echo 'single $HOME' \"double $((1+1))\" plain\\ escaped", prints: "single $HOME double 2 plain escaped\n")
        assertShell("echo \"a\\\"b\" 'c\\d' e\\\\f", prints: "a\"b c\\d e\\f\n")
        assertShell("echo $'tab\\there' $'new\\nline'", prints: "tab\there new\nline\n")
        assertShell("echo \"\"", prints: "\n")
        assertShell("printf '[%s]' \"\" a '' b; echo", prints: "[][a][][b]\n")
        assertShell("echo 'it''s' \"don\"'\"'\"t\"", prints: "its don\"t\n")
    }

    func testCommentsAndLineContinuation() {
        assertShell("echo one # comment here\necho two#notacomment", prints: "one\ntwo#notacomment\n")
        assertShell("echo a \\\n b", prints: "a b\n")
        assertShell("echo \"multi\nline\"", prints: "multi\nline\n")
    }

    // MARK: Parameters

    func testBasicParameterExpansion() {
        assertShell("x=hello; echo $x ${x} \"$x\" ${x}world $x-suffix", prints: "hello hello hello helloworld hello-suffix\n")
        assertShell("x=; echo \"[${x:-default}]\" \"[${x-notused}]\" \"[${y-unset}]\"", prints: "[default] [] [unset]\n")
        assertShell("unset y; echo ${y:=assigned}; echo $y", prints: "assigned\nassigned\n")
        assertShell("x=set; echo ${x:+alt} ${y:+alt}", prints: "alt\n")
        assertShell("x=hello; echo ${#x}", prints: "5\n")
        assertShell("set -- a b c; echo $# ${#@} ${#*}", prints: "3 3 3\n")
    }

    func testParameterErrorForms() {
        let result = ShellTesting.run("echo ${missing:?custom message}; echo after")
        XCTAssertEqual(result.stdout, "after\n")
        XCTAssertTrue(result.stderr.contains("missing: custom message"), result.stderr)
        XCTAssertEqual(result.status, 0)
        let bad = ShellTesting.run("echo ${!}; echo ${a b}")
        XCTAssertTrue(bad.stderr.contains("bad substitution"), bad.stderr)
    }

    func testPatternRemoval() {
        assertShell("f=/usr/local/bin/tool.tar.gz; echo ${f##*/} ${f#*/} ${f%.*} ${f%%.*}", prints: "tool.tar.gz usr/local/bin/tool.tar.gz /usr/local/bin/tool.tar /usr/local/bin/tool\n")
        assertShell("s=aXbXc; echo ${s/X/-} ${s//X/-} ${s/#a/A} ${s/%c/C}", prints: "a-bXc a-b-c AXbXc aXbXC\n")
        assertShell("s=hello; echo ${s^} ${s^^} ; t=WORLD; echo ${t,} ${t,,}", prints: "Hello HELLO\nwORLD world\n")
        assertShell("s=abcdef; echo ${s:1} ${s:1:2} ${s: -2} ${s:0:-1}", prints: "bcdef bc ef abcde\n")
        assertShell("v=\"a*b\"; echo \"${v//\\*/x}\"", prints: "axb\n")
    }

    func testIndirectionAndPrefixes() {
        assertShell("a=b; b=value; echo ${!a}", prints: "value\n")
        assertShell("TERN_ONE=1; TERN_TWO=2; echo ${!TERN_*}", prints: "TERN_ONE TERN_TWO\n")
    }

    func testPositionalAndSpecialParameters() {
        assertShell("set -- one two three; echo $1 $2 $3 ${10:-ten}; shift; echo $1 $#", prints: "one two three ten\ntwo 2\n")
        assertShell("false; echo $?; true; echo $?", prints: "1\n0\n")
        assertShell("echo $0", prints: "tsh\n")
        assertShell("set -- a 'b c' d; printf '[%s]' \"$@\"; echo; printf '[%s]' $*; echo; printf '[%s]' \"$*\"; echo", prints: "[a][b c][d]\n[a][b][c][d]\n[a b c d]\n")
        assertShell("set -- a b; IFS=:; echo \"$*\"", prints: "a:b\n")
        assertShell("set --; printf '[%s]' \"$@\"; echo done", prints: "[]done\n")
        assertShell("set --; for a in \"$@\"; do echo never; done; echo \"count=$#\"", prints: "count=0\n")
        assertShell("set -- x; printf '[%s]' \"pre$@post\"; echo", prints: "[prexpost]\n")
        assertShell("set -- 1 2 3; echo \"${@:2}\" \"${@: -1}\"", prints: "2 3 3\n")
        assertShell("echo ${#} $# -$- | tr -d ' '", prints: "00-h\n")
    }

    func testSpecialVariables() {
        let result = ShellTesting.run("echo $$ $PWD $HOME $RANDOM $LINENO $SECONDS $SHELL")
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        XCTAssertEqual(parts.count, 7)
        XCTAssertEqual(String(parts[0]), String(getpid()))
        XCTAssertEqual(parts[1], parts[2])
        XCTAssertNotNil(Int(parts[3]))
        XCTAssertEqual(parts[4], "1")
        XCTAssertEqual(parts[6], "/bin/tsh")
    }

    // MARK: Command substitution and arithmetic

    func testCommandSubstitution() {
        assertShell("echo $(echo nested $(echo deep)) `echo back`", prints: "nested deep back\n")
        assertShell("x=$(printf 'a\\nb\\n\\n'); echo \"[$x]\"", prints: "[a\nb]\n")
        assertShell("echo \"$(echo one; echo two)\"", prints: "one\ntwo\n")
        assertShell("x=$(false); echo $?", prints: "1\n")
        assertShell("echo $(echo 'quoted ) paren')", prints: "quoted ) paren\n")
        assertShell("for w in $(echo a b c); do echo -n \"$w.\"; done; echo", prints: "a.b.c.\n")
        assertShell("echo `echo \\`echo inner\\``", prints: "inner\n")
        assertShell("x=$(cd / && pwd); echo $x; pwd | grep -c tsh-tests", prints: "/\n1\n")
    }

    func testArithmetic() {
        assertShell("echo $((1 + 2 * 3)) $(( (1 + 2) * 3 )) $((10 / 3)) $((10 % 3)) $((2 ** 10))", prints: "7 9 3 1 1024\n")
        assertShell("x=5; echo $((x + 1)) $(($x * 2)) $((x++)) $x $((++x)) $((x--)) $x", prints: "6 10 5 6 7 7 6\n")
        assertShell("echo $((1 < 2)) $((2 < 1)) $((3 == 3)) $((3 != 3)) $((1 && 0)) $((1 || 0)) $((!0)) $((~0))", prints: "1 0 1 0 0 1 1 -1\n")
        assertShell("echo $((0x1f)) $((010)) $((2#1010)) $((16#ff)) $((-7 / 2)) $((-7 % 3))", prints: "31 8 10 255 -3 -1\n")
        assertShell("echo $((1 ? 2 : 3)) $((0 ? 2 : 3)) $((1 << 4)) $((256 >> 2)) $((6 & 3)) $((6 | 3)) $((6 ^ 3))", prints: "2 3 16 64 2 7 5\n")
        assertShell("x=1; echo $((x += 4)) $((x *= 2)) $((x -= 1)) $((x /= 3)) $x", prints: "5 10 9 3 3\n")
        assertShell("a=3; b=a; echo $((b + 1)) $((a, 2))", prints: "4 2\n")
        assertShell("let x=3*4 y=x+1; echo $x $y; (( x > 10 )) && echo big; (( x < 10 )) || echo notsmall", prints: "12 13\nbig\nnotsmall\n")
        let divide = ShellTesting.run("echo $((1/0)); echo after")
        XCTAssertTrue(divide.stderr.contains("division by 0"), divide.stderr)
        XCTAssertEqual(divide.stdout, "after\n")
        assertShell("i=0; while (( i < 3 )); do echo $i; (( i++ )); done", prints: "0\n1\n2\n")
        assertShell("for ((i = 0; i < 3; i++)); do echo -n $i; done; echo", prints: "012\n")
    }

    // MARK: Tilde, brace, glob

    func testTildeExpansion() {
        let result = ShellTesting.run("echo ~ ~/sub \"~\" '~' ~nobody x=~; p=~/bin:~/x; echo $p")
        let home = result.shell.homeDirectory
        XCTAssertEqual(result.stdout, "\(home) \(home)/sub ~ ~ ~nobody x=~\n\(home)/bin:\(home)/x\n")
        assertShell("cd /; echo ~+ ; cd /tmp; echo ~-", prints: "/\n/\n")
    }

    func testBraceExpansion() {
        assertShell("echo a{b,c}d {1..3} {a..c} {5..1..2} {01..03} x{,y} {a,b{1,2}}", prints: "abd acd 1 2 3 a b c 5 3 1 01 02 03 x xy a b1 b2\n")
        assertShell("echo '{a,b}' \"{1..2}\" {single} {} ${TERN_UNSET:-{x,y}}", prints: "{a,b} {1..2} {single} {} {x,y}\n")
        assertShell("echo {-2..2}", prints: "-2 -1 0 1 2\n")
    }

    func testPathnameExpansion() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        for name in ["alpha.txt", "beta.txt", "gamma.md", ".hidden", "dir/inner.txt", "dir/sub/deep.txt"] {
            let path = directory + "/" + name
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        assertShell("echo *.txt", prints: "alpha.txt beta.txt\n", workingDirectory: directory)
        assertShell("echo ?lpha.txt [ab]*.txt [!a]*.txt", prints: "alpha.txt alpha.txt beta.txt beta.txt\n", workingDirectory: directory)
        assertShell("echo *", prints: "alpha.txt beta.txt dir gamma.md\n", workingDirectory: directory)
        assertShell("echo .h*", prints: ".hidden\n", workingDirectory: directory)
        assertShell("echo dir/*.txt dir/*/", prints: "dir/inner.txt dir/sub/\n", workingDirectory: directory)
        assertShell("echo **/*.txt", prints: "alpha.txt beta.txt dir/inner.txt dir/sub/deep.txt\n", workingDirectory: directory)
        assertShell("echo nomatch* '*.txt' \"*.md\" \\*", prints: "nomatch* *.txt *.md *\n", workingDirectory: directory)
        assertShell("set -f; echo *.txt; set +f; p='*.txt'; echo $p", prints: "*.txt\nalpha.txt beta.txt\n", workingDirectory: directory)
        assertShell("echo \(directory)/*.md", prints: "\(directory)/gamma.md\n", workingDirectory: directory)
        assertShell("echo [[:alpha:]]lpha.txt [[:digit:]]*", prints: "alpha.txt [[:digit:]]*\n", workingDirectory: directory)
    }

    // MARK: Field splitting

    func testFieldSplitting() {
        assertShell("x='  a   b  '; printf '[%s]' $x; echo; printf '[%s]' \"$x\"; echo", prints: "[a][b]\n[  a   b  ]\n")
        assertShell("IFS=,; x='a,,b,'; printf '[%s]' $x; echo", prints: "[a][][b]\n")
        assertShell("IFS=', '; x='a, b ,c'; printf '[%s]' $x; echo", prints: "[a][b][c]\n")
        assertShell("IFS=; x='a b'; printf '[%s]' $x; echo", prints: "[a b]\n")
        assertShell("empty=; printf '[%s]' $empty \"$empty\" x; echo", prints: "[][x]\n")
        assertShell("x='a b'; echo pre${x}post | tr ' ' '_'", prints: "prea_bpost\n")
    }

    func testAssignmentsDoNotSplitOrGlob() {
        assertShell("v='a  b'; w=$v; echo \"$w\"; x=*; echo \"$x\"", prints: "a  b\n*\n")
        assertShell("x=1 y=2; echo $x$y; x+=5; echo $x", prints: "12\n15\n")
        assertShell("local_test() { local v=\"$1 $2\"; echo \"[$v]\"; }; local_test one two", prints: "[one two]\n")
        assertShell("export E=\"with space\"; sh -c 'echo \"$E\"'", prints: "with space\n")
    }

    func testNounset() {
        let result = ShellTesting.run("set -u; echo $undefined_var; echo after", interactive: true)
        XCTAssertTrue(result.stderr.contains("unbound variable"), result.stderr)
        XCTAssertEqual(result.stdout, "after\n")
        assertShell("set -u; echo ${undefined_var:-ok} $# $?", prints: "ok 0 0\n")
    }
}
