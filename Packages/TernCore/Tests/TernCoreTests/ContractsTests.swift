import XCTest
@testable import TernCore

final class ContractsTests: XCTestCase {
    func testTerminalSizeClampsToAtLeastOneCell() {
        let size = TerminalSize(columns: 0, rows: -3)
        XCTAssertEqual(size.columns, 1)
        XCTAssertEqual(size.rows, 1)
    }

    func testPipeRoundTrip() throws {
        let pipe = try XCTUnwrap(FileDescriptorIO.makePipe())
        FileDescriptorIO.writeAll(pipe.write, "hello")
        FileDescriptorIO.closeQuietly(pipe.write)
        let bytes = FileDescriptorIO.readAll(pipe.read)
        FileDescriptorIO.closeQuietly(pipe.read)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hello")
    }

    func testSnapshotMergesCommandNamesWithoutDuplicates() {
        let snapshot = ShellSnapshot(
            workingDirectory: "/tmp",
            homeDirectory: "/tmp",
            aliases: ["ll": "ls -l", "ls": "ls -G"],
            functionNames: ["deploy"],
            builtinNames: ["cd", "echo"],
            externalCommandNames: ["ls", "echo", "vim"],
            hostCommandNames: ["tern"]
        )
        XCTAssertEqual(snapshot.allCommandNames, ["ll", "ls", "deploy", "cd", "echo", "tern", "vim"])
    }
}
