import XCTest
@testable import TernCore

final class ShellBuiltinsTests: XCTestCase {
    func testEcho() {
        assertShell("echo -n no newline; echo", prints: "no newline\n")
        assertShell("echo -e 'a\\tb\\nc'", prints: "a\tb\nc\n")
        assertShell("echo 'a\\tb'", prints: "a\\tb\n")
        assertShell("echo -E 'a\\tb'", prints: "a\\tb\n")
        assertShell("echo -ne 'x\\c'; echo y", prints: "xy\n")
        assertShell("echo -x", prints: "-x\n")
        assertShell("echo -e '\\x41\\101\\u00e9'", prints: "AAé\n")
        assertShell("echo", prints: "\n")
    }

    func testPrintf() {
        assertShell("printf '%s-%s\\n' a b c", prints: "a-b\nc-\n")
        assertShell("printf '%d %i %5d|%-5d|%05d\\n' 42 -7 3 3 3", prints: "42 -7     3|3    |00003\n")
        assertShell("printf '%x %X %o %u\\n' 255 255 8 42", prints: "ff FF 10 42\n")
        assertShell("printf '%.2f %e %g\\n' 3.14159 1234.5 0.0001", prints: "3.14 1.234500e+03 0.0001\n")
        assertShell("printf '%c%c\\n' hello world", prints: "hw\n")
        assertShell("printf '%10s|%-10s|%.3s\\n' right left truncated", prints: "     right|left      |tru\n")
        assertShell("printf '%%|%b|\\n' 'tab\\there'", prints: "%|tab\there|\n")
        assertShell("printf '%q\\n' \"it's\"", prints: "'it'\\''s'\n")
        assertShell("printf 'no args\\n'", prints: "no args\n")
        assertShell("printf '%s\\n'", prints: "\n")
        assertShell("printf -v var '%03d' 7; echo $var", prints: "007\n")
        assertShell("printf '%d\\n' \"'A\"", prints: "65\n")
        assertShell("printf '%*d|%-*d|\\n' 4 1 4 2", prints: "   1|2   |\n")
        let bad = ShellTesting.run("printf '%d\\n' abc; echo $?")
        XCTAssertEqual(bad.stdout, "0\n1\n")
        XCTAssertTrue(bad.stderr.contains("abc"), bad.stderr)
    }

    func testTest() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        try "data".write(toFile: directory + "/file", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: directory + "/dir", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: "file")
        FileManager.default.createFile(atPath: directory + "/empty", contents: Data())
        let checks: [(String, Int32)] = [
            ("[ -e file ]", 0), ("[ -f file ]", 0), ("[ -d dir ]", 0), ("[ -d file ]", 1), ("[ -L link ]", 0), ("[ -h link ]", 0),
            ("[ -s file ]", 0), ("[ -s empty ]", 1), ("[ -r file ]", 0), ("[ -e missing ]", 1), ("[ -z '' ]", 0), ("[ -z a ]", 1),
            ("[ -n a ]", 0), ("[ -n '' ]", 1), ("[ a = a ]", 0), ("[ a = b ]", 1), ("[ a != b ]", 0), ("[ 2 -eq 2 ]", 0),
            ("[ 2 -ne 2 ]", 1), ("[ 1 -lt 2 ]", 0), ("[ 2 -le 2 ]", 0), ("[ 3 -gt 2 ]", 0), ("[ 3 -ge 4 ]", 1),
            ("[ a \\< b ]", 0), ("[ b \\> a ]", 0), ("[ ! -e missing ]", 0), ("[ -e file -a -e dir ]", 0), ("[ -e file -a -e missing ]", 1),
            ("[ -e missing -o -e file ]", 0), ("[ \\( -e missing -o -e file \\) -a -d dir ]", 0), ("[ file -nt dir -o file -ot dir ]", 0),
            ("[ file -ef link ]", 0), ("test", 1), ("test x", 0), ("test ''", 1), ("[ ]", 1), ("[ -x dir ]", 0), ("test 5 -eq 5 -a 1 -lt 0", 1),
        ]
        for (expression, expected) in checks {
            let result = ShellTesting.run(expression, workingDirectory: directory)
            XCTAssertEqual(result.status, expected, "\(expression) stderr: \(result.stderr)")
        }
        let missingBracket = ShellTesting.run("[ a = a")
        XCTAssertEqual(missingBracket.status, 2)
        XCTAssertTrue(missingBracket.stderr.contains("missing `]'"))
        let notInteger = ShellTesting.run("[ abc -eq 1 ]")
        XCTAssertEqual(notInteger.status, 2)
        XCTAssertTrue(notInteger.stderr.contains("integer expression expected"))
    }

    func testDoubleBracket() {
        assertShell("[[ abc == a* ]] && echo glob; [[ abc == 'a*' ]] || echo literal", prints: "glob\nliteral\n")
        assertShell("[[ 2024-01-02 =~ ^([0-9]+)-([0-9]+) ]] && echo $BASH_REMATCH $BASH_REMATCH_1 $BASH_REMATCH_2", prints: "2024-01 2024 01\n")
        assertShell("[[ -n abc && ! -z abc || -z abc ]] && echo ok", prints: "ok\n")
        assertShell("[[ apple < banana ]] && echo lt; [[ 10 -gt 9 ]] && echo gt", prints: "lt\ngt\n")
        assertShell("x=''; [[ -z $x ]] && echo empty; [[ $x ]] || echo falsy", prints: "empty\nfalsy\n")
        assertShell("[[ ( 1 -eq 1 ) && ( 2 -eq 3 || 3 -eq 3 ) ]] && echo nested", prints: "nested\n")
        assertShell("v=set; [[ -v v ]] && echo declared; [[ -v nope ]] || echo undeclared", prints: "declared\nundeclared\n")
        assertShell("[[ a == a ]] && echo eq; [[ a != b ]] && echo ne", prints: "eq\nne\n")
    }

    func testCdAndPwd() throws {
        let directory = ShellTesting.makeTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: directory + "/a/b", withIntermediateDirectories: true)
        assertShell("cd a; pwd; cd b; pwd; cd ..; pwd; cd -; pwd; cd; pwd", prints: "\(directory)/a\n\(directory)/a/b\n\(directory)/a\n\(directory)/a/b\n\(directory)/a/b\n\(directory)\n", workingDirectory: directory)
        assertShell("cd a/./b/../b; pwd; echo $PWD $OLDPWD", prints: "\(directory)/a/b\n\(directory)/a/b \(directory)\n", workingDirectory: directory)
        let result = ShellTesting.run("cd missing; echo $?; cd a; cd ../a/b/../..; pwd", workingDirectory: directory)
        XCTAssertEqual(result.stdout, "1\n\(directory)\n")
        XCTAssertTrue(result.stderr.contains("cd: missing: No such file or directory"))
        XCTAssertEqual(result.host.directoryChanges.last, directory)
        assertShell("CDPATH=\(directory); cd a; pwd", prints: "\(directory)/a\n\(directory)/a\n", workingDirectory: "/")
        assertShell("pushd a > /dev/null; pwd; pushd b > /dev/null; pwd; popd > /dev/null; pwd; popd > /dev/null; pwd; dirs", prints: "\(directory)/a\n\(directory)/a/b\n\(directory)/a\n\(directory)\n~\n", workingDirectory: directory)
    }

    func testVariablesExportUnset() {
        assertShell("x=1; unset x; echo \"[$x]\"", prints: "[]\n")
        assertShell("export A=1 B=2; env | grep -E '^(A|B)=' | sort", prints: "A=1\nB=2\n")
        assertShell("C=3; export C; export -p | grep 'C=' | head -1", prints: "export C=\"3\"\n")
        assertShell("export D=4; export -n D; env | grep -c '^D=' || true", prints: "0\n")
        assertShell("readonly R=1; R=2; echo $R", prints: "1\n")
        let readonlyError = ShellTesting.run("readonly R=1; unset R; echo $?")
        XCTAssertTrue(readonlyError.stderr.contains("readonly"))
        assertShell("set -a; AUTO=1; set +a; env | grep -c '^AUTO='", prints: "1\n")
        assertShell("declare -x DX=1; env | grep -c '^DX='; declare -r DR=2; DR=3 2>/dev/null; echo $DR", prints: "1\n2\n")
        assertShell("f() { local a=1; typeset b=2; echo $a $b; }; f; echo \"[$a$b]\"", prints: "1 2\n[]\n")
        let localOutside = ShellTesting.run("local x=1")
        XCTAssertEqual(localOutside.status, 1)
        assertShell("x=1; set | grep '^x='", prints: "x=1\n")
    }

    func testSetOptions() {
        assertShell("set -o pipefail; set -o | grep pipefail", prints: "pipefail       on\n")
        assertShell("set -- a b c; echo $2; set -- ; echo $#", prints: "b\n0\n")
        assertShell("set -e; set +e; false; echo continued", prints: "continued\n")
        let bad = ShellTesting.run("set -Q; echo $?")
        XCTAssertEqual(bad.stdout, "2\n")
        assertShell("set -o noglob; echo *; set +o noglob", prints: "*\n")
        assertShell("set -C; echo one > f; echo two > f 2>/dev/null || echo blocked; echo three >| f; cat f", prints: "blocked\nthree\n")
    }

    func testReadBuiltin() {
        assertShell("read a b c; echo \"[$a][$b][$c]\"", prints: "[one][two][three four]\n", scriptedLines: ["one two three four"])
        assertShell("read -p 'name: ' name; echo \"hi $name\"", prints: "hi Tern\n", scriptedLines: ["Tern"])
        let prompt = ShellTesting.run("read -p 'name: ' name", scriptedLines: ["x"])
        XCTAssertEqual(prompt.host.prompts, ["name: "])
        assertShell("read; echo \"[$REPLY]\"", prints: "[plain]\n", scriptedLines: ["plain"])
        assertShell("read line; echo $?; read line2; echo $? \"[$line2]\"", prints: "0\n1 []\n", scriptedLines: ["only"])
        assertShell("echo 'a\\tb' | { read raw; read -r rest <<< 'c\\td'; echo \"$raw|$rest\"; }", prints: "atb|c\\td\n")
        assertShell("printf 'x:y:z\\n' | { IFS=: read a b; echo \"$a|$b\"; }", prints: "x|y:z\n")
        assertShell("printf 'k=v\\n' | { IFS== read k v; echo \"$k -> $v\"; }", prints: "k -> v\n")
        assertShell("printf '  spaced  \\n' | { read s; echo \"[$s]\"; }", prints: "[spaced]\n")
        assertShell("read -d , part <<< 'first,second'; echo $part", prints: "first\n")
        assertShell("printf 'abcdef' | { read -n 3 x; echo $x; }", prints: "abc\n")
        assertShell("while read -r l; do echo \"<$l>\"; done <<< $'1\\n2'", prints: "<1>\n<2>\n")
    }

    func testTypeCommandWhichHash() {
        assertShell("type cd echo", prints: "cd is a shell builtin\necho is a shell builtin\n")
        assertShell("f() { :; }; type -t f; type -t if; type -t cd; type -t ls", prints: "function\nkeyword\nbuiltin\nfile\n")
        assertShell("alias ll='ls -l'; type ll", prints: "ll is an alias for `ls -l'\n")
        let whichLS = ShellTesting.run("which ls; command -v ls; command -v cd; command -v nope; echo $?")
        XCTAssertTrue(whichLS.stdout.hasPrefix("/"), whichLS.stdout)
        XCTAssertTrue(whichLS.stdout.hasSuffix("cd\n1\n"), whichLS.stdout)
        let notFound = ShellTesting.run("type nothing_here; echo $?")
        XCTAssertEqual(notFound.stdout, "1\n")
        assertShell("echo() { printf 'custom\\n'; }; echo hi; command echo plain; builtin echo again; unset -f echo", prints: "custom\nplain\nagain\n")
        assertShell("hash; hash -r; echo $?", prints: "0\n")
    }

    func testAliases() {
        assertShell("alias greet='echo hello'\ngreet world", prints: "hello world\n")
        assertShell("alias a='echo A'\nalias b='a B'\nb C", prints: "A B C\n")
        assertShell("alias a='echo A'; alias b='a B'; b C 2>&1 | grep -c 'not found'", prints: "1\n")
        assertShell("alias e='echo'; alias; unalias e; e x 2>&1 | head -1 | grep -c 'command not found'", prints: "alias e='echo'\n1\n")
        assertShell("alias loop='loop x'; loop 2>&1 | grep -c 'not found'", prints: "1\n")
        assertShell("alias q='echo'; 'q' 2>&1 | grep -c 'not found'", prints: "1\n")
    }

    func testGetopts() {
        let script = """
        parse() {
            OPTIND=1
            while getopts "ab:c" opt; do
                case $opt in
                    a) echo flag-a ;;
                    b) echo "b=$OPTARG" ;;
                    c) echo flag-c ;;
                    ?) echo "bad" ;;
                esac
            done
            shift $((OPTIND - 1))
            echo "rest: $@"
        }
        parse -a -b value -c positional
        parse -ab compact more
        parse -z
        parse -b
        """
        let result = ShellTesting.run(script)
        XCTAssertEqual(result.stdout, "flag-a\nb=value\nflag-c\nrest: positional\nflag-a\nb=compact\nrest: more\nbad\nrest: \nbad\nrest: \n")
        XCTAssertTrue(result.stderr.contains("illegal option -- z"))
        XCTAssertTrue(result.stderr.contains("option requires an argument -- b"))
        assertShell("OPTIND=1; getopts ':x:' o -x; echo $o $OPTARG; getopts ':x:' o -x; echo $o $OPTARG", prints: ": x\n? x\n")
    }

    func testShiftExitReturnErrors() {
        let shift = ShellTesting.run("set -- a; shift 2; echo $?")
        XCTAssertEqual(shift.stdout, "1\n")
        let exitBad = ShellTesting.run("exit abc", interactive: true)
        XCTAssertEqual(exitBad.status, 2)
        XCTAssertTrue(exitBad.stderr.contains("numeric argument required"))
        let returnTop = ShellTesting.run("return 3; echo $?")
        XCTAssertEqual(returnTop.stdout, "1\n")
        let breakTop = ShellTesting.run("break; echo $?")
        XCTAssertEqual(breakTop.stdout, "0\n")
    }

    func testMiscBuiltins() {
        assertShell("umask; ulimit -n; times | wc -l | tr -d ' '", prints: "0022\n256\n2\n")
        assertShell(": ignored args; true; echo $?", prints: "0\n")
        assertShell("let 'x = 2 + 3'; echo $x; let x++; echo $x; let 0; echo $?", prints: "5\n6\n1\n")
        assertShell("bg 2>&1 | grep -c 'not supported'; fg 2>/dev/null; echo $?", prints: "1\n1\n")
        assertShell("jobs; echo clean", prints: "clean\n")
        assertShell("kill -l | head -2 | tr '\\n' ' '", prints: "1) SIGHUP 2) SIGINT ")
        assertShell("exec 3< /dev/null; read -u 3 x 2>/dev/null; cat <&3; echo ok", prints: "ok\n")
        assertShell("help 2>&1 | grep -c 'not available'; history 2>&1 | grep -c 'not available'", prints: "1\n1\n")
        let hostHelp = ShellTesting.run("help topic") { host, _ in
            host.hostCommands["help"] = { argv, io in
                io.writeOut("host help for \(argv.dropFirst().joined(separator: " "))\n")
                return 0
            }
        }
        XCTAssertEqual(hostHelp.stdout, "host help for topic\n")
        let clear = ShellTesting.run("clear")
        XCTAssertEqual(clear.stdout, "\u{1B}[H\u{1B}[2J\u{1B}[3J")
    }

    func testHostCommandsIntegrateWithPipes() {
        let result = ShellTesting.run("echo piped | shout; shout direct arg; type shout; echo $?") { host, _ in
            host.hostCommands["shout"] = { argv, io in
                var input = ""
                if argv.count == 1 {
                    input = String(decoding: FileDescriptorIO.readAll(io.stdin), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    input = argv.dropFirst().joined(separator: " ")
                }
                io.writeOut(input.uppercased() + "\n")
                return 0
            }
        }
        XCTAssertEqual(result.stdout, "PIPED\nDIRECT ARG\nshout is a shell builtin\n0\n")
    }

    func testCommandNotFoundSuggestions() {
        let result = ShellTesting.run("ehco hi; echo $?")
        XCTAssertEqual(result.stdout, "127\n")
        XCTAssertTrue(result.stderr.contains("tsh: ehco: command not found"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Did you mean: echo?"), result.stderr)
        let directory = ShellTesting.run("./nope; echo $?; ./; echo $?")
        XCTAssertEqual(directory.stdout, "127\n126\n")
    }
}
