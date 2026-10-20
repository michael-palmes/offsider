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

    @Test("a broker of another build that closes before its handshake is found by its arguments and stopped so a fresh one can start")
    func otherBuildReplaced() throws {
        var asked: [[String]] = []
        #expect(throws: HIDBrokerNotReadyError.self) {
            try HIDBroker.replaceRefusingBroker(
                simulatorUDID: "00000000-0000-0000-0000-000000000001",
                reconnect: { throw POSIXError(.ECONNREFUSED) },
                requirement: { try PeerCodeIdentity.ownRequirement() },
                stopOtherBuilds: { arguments, _ in
                    asked.append(arguments)
                    return ([4242], [])
                }
            )
        }
        #expect(asked == [["hid-broker", "--udid", "00000000-0000-0000-0000-000000000001"]])
    }

    @Test("a broker of this very build that closes a second connection too is a dead end named in one line, and one that answers is not")
    func sameBuildKept() throws {
        let closed = try Self.pair()
        Darwin.close(closed[1])
        defer { Darwin.close(closed[0]) }
        let deadEnd = #expect(throws: CLIError.self) {
            try HIDBroker.replaceRefusingBroker(
                simulatorUDID: "00000000-0000-0000-0000-000000000001",
                reconnect: { closed[0] },
                requirement: { try PeerCodeIdentity.ownRequirement() },
                stopOtherBuilds: { _, _ in ([], [getpid()]) }
            )
        }
        #expect(deadEnd?.reason == .hidBrokerFailed)

        let answering = try Self.pair()
        try HIDBroker.writeAll(Data("{\"ready\":true}\n".utf8), to: answering[1])
        try HIDBroker.replaceRefusingBroker(
            simulatorUDID: "00000000-0000-0000-0000-000000000001",
            reconnect: { answering[0] },
            requirement: { try PeerCodeIdentity.ownRequirement() },
            stopOtherBuilds: { _, _ in ([], [getpid()]) }
        )
        Darwin.close(answering[1])
    }

    @Test("with no broker found, or no udid, the retry loop is left to decide")
    func nothingFound() throws {
        try HIDBroker.replaceRefusingBroker(simulatorUDID: "00000000-0000-0000-0000-000000000001", reconnect: { throw POSIXError(.ECONNREFUSED) }, stopOtherBuilds: { _, _ in ([], []) })
        try HIDBroker.replaceRefusingBroker(simulatorUDID: nil, reconnect: { throw POSIXError(.ECONNREFUSED) }, stopOtherBuilds: { _, _ in ([9], []) })
    }
}
