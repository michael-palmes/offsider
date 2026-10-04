import Darwin
import Testing
@testable import Offsider

@Suite("HID broker peers")
struct HIDBrokerPeerTests {
    @Test("the broker admits only a peer running as the same user")
    func peerCheck() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        #expect(HIDBroker.isSameUserPeer(pair[0]))
        #expect(!HIDBroker.isSameUserPeer(pair[0], expectedUID: getuid() + 1))
    }
}
