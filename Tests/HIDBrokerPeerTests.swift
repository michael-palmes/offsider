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
}
