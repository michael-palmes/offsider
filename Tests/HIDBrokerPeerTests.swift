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

    static let udid = "00000000-0000-0000-0000-000000000001"
    static let endpoint = "/tmp/offsider-hid-test/endpoint-v3.sock"

    @Test("a broker of another build that closes before its handshake is found by its arguments and the endpoint it holds, and stopped")
    func otherBuildReplaced() throws {
        var asked: [(serving: [String], endpoint: String)] = []
        #expect(throws: HIDBrokerNotReadyError.self) {
            try HIDBroker.replaceRefusingBroker(
                simulatorUDID: Self.udid,
                endpoint: Self.endpoint,
                reconnect: { throw POSIXError(.ECONNREFUSED) },
                requirement: { try PeerCodeIdentity.ownRequirement() },
                stopOtherBuilds: { serving, endpoint, _ in
                    asked.append((serving, endpoint))
                    return ([4242], [])
                }
            )
        }
        #expect(asked.map(\.serving) == [["hid-broker", "--udid", Self.udid]])
        #expect(asked.map(\.endpoint) == [Self.endpoint])
    }

    @Test("with no udid, as session status and stop have, the broker holding the endpoint is still found and stopped")
    func endpointAlone() throws {
        var asked: [[String]] = []
        #expect(throws: HIDBrokerNotReadyError.self) {
            try HIDBroker.replaceRefusingBroker(
                simulatorUDID: nil, endpoint: Self.endpoint, reconnect: { throw POSIXError(.ECONNREFUSED) },
                stopOtherBuilds: { serving, _, _ in
                    asked.append(serving)
                    return ([9], [])
                }
            )
        }
        #expect(asked == [["hid-broker"]])
    }

    @Test("a broker of this very build that closes a second connection too is a dead end named in one line, and one that answers is not")
    func sameBuildKept() throws {
        // The helper closes the descriptor `reconnect` hands it, so the test must not close it again.
        let closed = try Self.pair()
        Darwin.close(closed[1])
        let deadEnd = #expect(throws: CLIError.self) {
            try HIDBroker.replaceRefusingBroker(
                simulatorUDID: Self.udid,
                endpoint: Self.endpoint,
                reconnect: { closed[0] },
                requirement: { try PeerCodeIdentity.ownRequirement() },
                stopOtherBuilds: { _, _, _ in ([], [getpid()]) }
            )
        }
        #expect(deadEnd?.reason == .hidBrokerFailed)

        let answering = try Self.pair()
        try HIDBroker.writeAll(Data("{\"ready\":true}\n".utf8), to: answering[1])
        try HIDBroker.replaceRefusingBroker(
            simulatorUDID: Self.udid,
            endpoint: Self.endpoint,
            reconnect: { answering[0] },
            requirement: { try PeerCodeIdentity.ownRequirement() },
            stopOtherBuilds: { _, _, _ in ([], [getpid()]) }
        )
        Darwin.close(answering[1])
    }

    @Test("with no broker found, the retry loop is left to decide")
    func nothingFound() throws {
        try HIDBroker.replaceRefusingBroker(
            simulatorUDID: Self.udid, endpoint: Self.endpoint, reconnect: { throw POSIXError(.ECONNREFUSED) }, stopOtherBuilds: { _, _, _ in ([], []) }
        )
    }
}
