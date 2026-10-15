import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("HID broker peers", .serialized)
struct HIDBrokerPeerTests {
    static func pair() throws -> [Int32] {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        return pair
    }

    @Test("the broker admits only a peer running as the same user")
    func peerCheck() throws {
        let pair = try Self.pair()
        defer { pair.forEach { Darwin.close($0) } }
        #expect(HIDBroker.isSameUserPeer(pair[0]))
        #expect(!HIDBroker.isSameUserPeer(pair[0], expectedUID: getuid() + 1))
    }

    @Test("the broker admits code that satisfies its own requirement and logs one line naming any other peer's pid")
    func codeCheck() throws {
        let pair = try Self.pair()
        defer { pair.forEach { Darwin.close($0) } }
        var lines: [String] = []
        #expect(HIDBroker.admitsPeer(pair[0], requirement: try PeerCodeIdentity.ownRequirement()) { lines.append($0) })
        #expect(lines.isEmpty)
        let other = try PeerCodeIdentity.requirement("identifier \"com.example.not-offsider\"")
        #expect(!HIDBroker.admitsPeer(pair[0], requirement: other) { lines.append($0) })
        #expect(lines.count == 1)
        #expect(lines.first?.contains("refused pid \(getpid())") == true)
        #expect(lines.first?.contains("not this Offsider build") == true)
    }

    @Test("a broker stops at its first idle moment after 12 hours")
    func lifetime() {
        let start: UInt64 = 1_000
        #expect(!HIDBroker.hasOutlived(startedAt: start, now: start + HIDBroker.maxLifetimeNanoseconds - 1))
        #expect(HIDBroker.hasOutlived(startedAt: start, now: start + HIDBroker.maxLifetimeNanoseconds))
    }

    @Test("a broker of another build that closes before its handshake is stopped so a fresh one can start")
    func otherBuildReplaced() throws {
        let folder = "/private/tmp/ohp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/b.sock"
        // nc stands in for a broker from another build: same user, code that is not this binary.
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-lU", path]
        listener.standardInput = FileHandle.nullDevice
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { if listener.isRunning { listener.terminate() } }
        var descriptor: Int32 = -1
        for _ in 0..<100 {
            descriptor = (try? HIDBroker.connect(to: path)) ?? -1
            if descriptor >= 0 { break }
            usleep(50_000)
        }
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }

        var stopped: [pid_t] = []
        #expect(throws: HIDBrokerNotReadyError.self) {
            try HIDBroker.replaceRefusingBroker(
                on: descriptor,
                reconnect: { throw POSIXError(.ECONNREFUSED) },
                requirement: { try PeerCodeIdentity.ownRequirement() },
                stop: { stopped.append($0) }
            )
        }
        #expect(stopped == [listener.processIdentifier])
    }

    @Test("a peer of this very build is never stopped")
    func sameBuildKept() throws {
        let pair = try Self.pair()
        defer { pair.forEach { Darwin.close($0) } }
        var stopped: [pid_t] = []
        try HIDBroker.replaceRefusingBroker(on: pair[0], reconnect: { throw POSIXError(.ECONNREFUSED) }, stop: { stopped.append($0) })
        #expect(stopped.isEmpty)
    }

    @Test("the broker is spawned in its own session and inherits no descriptor beyond stdin, stdout and stderr")
    func spawnInheritsNoDescriptor() throws {
        let folder = NSTemporaryDirectory() + "offsider-hid-spawn-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let opened = open(folder + "/leak", O_WRONLY | O_CREAT, 0o600)
        let leaked = fcntl(opened, F_DUPFD, 200)
        Darwin.close(opened)
        defer { Darwin.close(leaked) }
        #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0)
        let log = folder + "/hid.log"
        let pid = try HIDBroker.launchDetached(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "ls /dev/fd"], logPath: log)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        let lines = String(decoding: FileManager.default.contents(atPath: log) ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
        let descriptors = Set(lines.filter { $0.allSatisfy(\.isNumber) })
        #expect(!descriptors.contains(String(leaked)))
        #expect(descriptors.isSuperset(of: ["0", "1", "2"]))

        let sleeper = try HIDBroker.launchDetached(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], logPath: log)
        defer {
            kill(sleeper, SIGKILL)
            _ = waitpid(sleeper, &status, 0)
        }
        #expect(getsid(sleeper) == sleeper)
    }
}
