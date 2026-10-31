import Foundation
import XCTest
@testable import TernCore

/// A `ShellHost` for tests: captures stdout and stderr through pipes, serves scripted lines to `read`,
/// and records host callbacks.
final class TestHost: ShellHost {
    private let outPipe: (read: Int32, write: Int32)
    private let errPipe: (read: Int32, write: Int32)
    private let outCollector: OutputCollector
    private let errCollector: OutputCollector
    private var finished = false

    var terminalSize = TerminalSize(columns: 80, rows: 24)
    /// Lines handed to `read` (and continuation prompts), in order. Empty means EOF.
    var scriptedLines: [String] = []
    var prompts: [String] = []
    /// Data an external command reading the terminal will see.
    var terminalInput: String?
    var openedTerminalInputs = 0
    var exitStatus: Int32?
    var directoryChanges: [String] = []
    var startedCommands: [[String]] = []
    var finishedCommands: [([String], Int32)] = []
    var hostCommands: [String: ([String], ShellIO) -> Int32] = [:]

    init() {
        outPipe = FileDescriptorIO.makePipe()!
        errPipe = FileDescriptorIO.makePipe()!
        outCollector = OutputCollector(fd: outPipe.read)
        errCollector = OutputCollector(fd: errPipe.read)
    }

    var terminalOutput: Int32 { outPipe.write }
    var terminalError: Int32 { errPipe.write }

    func readLine(prompt: String, secure: Bool) -> String? {
        prompts.append(prompt)
        guard !scriptedLines.isEmpty else { return nil }
        return scriptedLines.removeFirst()
    }

    func openTerminalInput() -> Int32? {
        openedTerminalInputs += 1
        guard let pipe = FileDescriptorIO.makePipe() else { return nil }
        if let terminalInput {
            FileDescriptorIO.writeAll(pipe.write, terminalInput)
        }
        FileDescriptorIO.closeQuietly(pipe.write)
        return pipe.read
    }

    func closeTerminalInput(_ fd: Int32) {
        FileDescriptorIO.closeQuietly(fd)
    }

    func shellWillRun(externalCommand argv: [String]) { startedCommands.append(argv) }
    func shellDidFinish(externalCommand argv: [String], status: Int32) { finishedCommands.append((argv, status)) }
    func shellDidRequestExit(status: Int32) { exitStatus = status }
    func shellDidChangeDirectory(_ path: String) { directoryChanges.append(path) }

    func runHostCommand(_ argv: [String], io: ShellIO) -> Int32? {
        guard let command = hostCommands[argv[0]] else { return nil }
        return command(argv, io)
    }

    func hostCommandNames() -> [String] { Array(hostCommands.keys) }

    /// Closes the output pipes and returns everything written so far. Call once.
    func finish() -> (stdout: String, stderr: String) {
        if !finished {
            finished = true
            FileDescriptorIO.closeQuietly(outPipe.write)
            FileDescriptorIO.closeQuietly(errPipe.write)
        }
        let out = String(decoding: outCollector.finish(), as: UTF8.self)
        let err = String(decoding: errCollector.finish(), as: UTF8.self)
        return (out, err)
    }
}

struct ShellRunResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var host: TestHost
    var shell: Shell
}

enum ShellTesting {
    static let executor = ProcessCommandExecutor()

    static func makeTemporaryDirectory() -> String {
        let path = NSTemporaryDirectory() + "tsh-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func makeShell(host: TestHost, workingDirectory: String? = nil, environment: [String: String] = [:], interactive: Bool = false) -> Shell {
        let directory = workingDirectory ?? makeTemporaryDirectory()
        var env = environment
        if env["PATH"] == nil { env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin" }
        let shell = Shell(executor: executor, host: host, environment: env, workingDirectory: directory, homeDirectory: directory)
        shell.isInteractive = interactive
        return shell
    }

    /// Runs `script` in a fresh shell and returns status plus captured output.
    @discardableResult
    static func run(
        _ script: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        scriptedLines: [String] = [],
        terminalInput: String? = nil,
        interactive: Bool = false,
        configure: ((TestHost, Shell) -> Void)? = nil
    ) -> ShellRunResult {
        let host = TestHost()
        host.scriptedLines = scriptedLines
        host.terminalInput = terminalInput
        let shell = makeShell(host: host, workingDirectory: workingDirectory, environment: environment, interactive: interactive)
        configure?(host, shell)
        let status = shell.run(script)
        let output = host.finish()
        return ShellRunResult(status: status, stdout: output.stdout, stderr: output.stderr, host: host, shell: shell)
    }
}

extension XCTestCase {
    /// Asserts that `script` prints `expected` on stdout and exits with `status`.
    func assertShell(
        _ script: String,
        prints expected: String,
        status expectedStatus: Int32 = 0,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        scriptedLines: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = ShellTesting.run(script, workingDirectory: workingDirectory, environment: environment, scriptedLines: scriptedLines)
        XCTAssertEqual(result.stdout, expected, "stdout of: \(script)\nstderr: \(result.stderr)", file: file, line: line)
        XCTAssertEqual(result.status, expectedStatus, "status of: \(script)\nstderr: \(result.stderr)", file: file, line: line)
    }
}
