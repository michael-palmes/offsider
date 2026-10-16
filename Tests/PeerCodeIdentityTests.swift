import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Peer code identity")
struct PeerCodeIdentityTests {
    static func pair() throws -> [Int32] {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        return pair
    }

    @Test("a peer running this very binary satisfies the process's own designated requirement")
    func ownRequirementAccepted() throws {
        let pair = try Self.pair()
        defer { pair.forEach { close($0) } }
        let token = try #require(PeerCodeIdentity.auditToken(of: pair[0]))
        #expect(PeerCodeIdentity.pid(of: token) == getpid())
        let verdict = PeerCodeIdentity.check(auditToken: token, requirement: try PeerCodeIdentity.ownRequirement())
        #expect(verdict.accepted, "\(verdict.detail ?? "")")
        #expect(verdict.pid == getpid())
        #expect(verdict.cdhash?.isEmpty == false)
    }

    @Test("the same peer is refused against a requirement for another identifier")
    func otherIdentifierRefused() throws {
        let pair = try Self.pair()
        defer { pair.forEach { close($0) } }
        let other = try PeerCodeIdentity.requirement("identifier \"com.example.not-offsider\"")
        let verdict = PeerCodeIdentity.check(peer: pair[0], requirement: other)
        #expect(!verdict.accepted)
        #expect(verdict.detail?.contains("SecCodeCheckValidity") == true)
    }

    @Test("the pid fallback reaches the same verdicts")
    func pidFallback() throws {
        let pair = try Self.pair()
        defer { pair.forEach { close($0) } }
        let pid = try #require(PeerCodeIdentity.peerPID(of: pair[1]))
        #expect(PeerCodeIdentity.check(pid: pid, requirement: try PeerCodeIdentity.ownRequirement()).accepted)
        #expect(!PeerCodeIdentity.check(pid: pid, requirement: try PeerCodeIdentity.requirement("identifier \"com.example.not-offsider\"")).accepted)
    }

    @Test("a descriptor that is not a connected socket is refused, never accepted")
    func unidentifiedRefused() throws {
        let descriptor = open("/dev/null", O_RDONLY)
        defer { close(descriptor) }
        let verdict = PeerCodeIdentity.check(peer: descriptor, requirement: try PeerCodeIdentity.ownRequirement())
        #expect(!verdict.accepted)
    }

    @Test("one check costs milliseconds, not a second")
    func checkIsCheap() throws {
        let pair = try Self.pair()
        defer { pair.forEach { close($0) } }
        let requirement = try PeerCodeIdentity.ownRequirement()
        let clock = ContinuousClock()
        var verdict: PeerCodeIdentity.Verdict?
        let elapsed = clock.measure { verdict = PeerCodeIdentity.check(peer: pair[0], requirement: requirement) }
        #expect(verdict?.accepted == true)
        #expect(elapsed < .milliseconds(500))
    }
}
