import XCTest
@testable import Tern

final class SSHConfigTests: XCTestCase {
    func testParsesHostBlocksAndIgnoresWildcards() {
        let config = """
        # comment
        Host *
            ServerAliveInterval 60

        Host blue
            HostName blue.example.net
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host red pink
            User admin
        """
        let hosts = SSHConfig.parse(config)
        XCTAssertEqual(hosts.map(\.name), ["blue", "red", "pink"])
        let blue = hosts[0]
        XCTAssertEqual(blue.hostName, "blue.example.net")
        XCTAssertEqual(blue.user, "deploy")
        XCTAssertEqual(blue.port, 2222)
        XCTAssertEqual(blue.identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(blue.summary, "deploy@blue.example.net:2222")
        XCTAssertEqual(hosts[1].summary, "admin@red")
    }

    func testAddAndRemoveRoundTrip() throws {
        let directory = NSTemporaryDirectory() + "tern-ssh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/config"
        try "Host keep\n    User me\n".write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertTrue(SSHConfig.add(SSHHost(name: "new", hostName: "10.0.0.5", user: "root", port: 22, identityFile: nil), path: path))
        XCTAssertFalse(SSHConfig.add(SSHHost(name: "new"), path: path), "duplicate names are rejected")
        var hosts = SSHConfig.load(path: path)
        XCTAssertEqual(hosts.map(\.name), ["keep", "new"])
        XCTAssertEqual(hosts[1].hostName, "10.0.0.5")

        XCTAssertTrue(SSHConfig.remove(hosts[0], path: path))
        hosts = SSHConfig.load(path: path)
        XCTAssertEqual(hosts.map(\.name), ["new"])
        XCTAssertEqual(hosts[0].user, "root")
    }

    func testQuotingMatchesIOSSystemRules() {
        XCTAssertEqual(IOSSystemQuoting.quote("plain"), "\"plain\"")
        XCTAssertEqual(IOSSystemQuoting.quote("has \"quote\""), "'has \"quote\"'")
        XCTAssertEqual(IOSSystemQuoting.quote("it's"), "\"it's\"")
        XCTAssertEqual(IOSSystemQuoting.quote(""), "\"\"")
        let both = IOSSystemQuoting.quote("a\"b'c")
        XCTAssertTrue(both.hasPrefix("\u{1e}") && both.hasSuffix("\u{1e}"))
        XCTAssertEqual(IOSSystemQuoting.commandLine(["echo", "$HOME", "~"]), "echo \"$HOME\" \"~\"")
    }

    func testKeyGenerationCommand() {
        let command = SSHKeyStore.generateCommand(name: "id_ed25519", type: .ed25519, comment: "me@phone", passphrase: "")
        XCTAssertEqual(command, "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C me@phone")
        let rsa = SSHKeyStore.generateCommand(name: "work key", type: .rsa, comment: "", passphrase: "p'q")
        XCTAssertEqual(rsa, "ssh-keygen -t rsa -b 4096 -f ~/.ssh/'work key' -N 'p'\\''q'")
    }
}
