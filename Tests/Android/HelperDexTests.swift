import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android helper dex")
struct HelperDexTests {
    static let bytes = Data("dex".utf8)

    @Test("a dex that matches its manifest keeps its hash and version, and lives at a content-addressed path")
    func matching() throws {
        let dex = try HelperDex(bytes: Self.bytes, manifestJSON: FakeHelperDevice.manifest(for: Self.bytes))
        #expect(dex.sha256 == "9d0fbf9349f646f1435072f2b0212084752ef4601bd6b012fbbe61b6c5e03930")
        #expect(dex.version == "1.0.0")
        #expect(dex.devicePath == "/data/local/tmp/offsider-helper-9d0fbf9349f646f1.dex")
    }

    @Test("a manifest whose size disagrees marks the dex damaged")
    func wrongSize() {
        let manifest = FakeHelperDevice.manifest(for: Data("dexx".utf8), sha256: "9d0fbf9349f646f1435072f2b0212084752ef4601bd6b012fbbe61b6c5e03930")
        #expect(throws: HelperDexError.damaged("the dex has 3 bytes, its manifest says 4")) {
            try HelperDex(bytes: Self.bytes, manifestJSON: manifest)
        }
    }

    @Test("a manifest whose hash disagrees marks the dex damaged")
    func wrongHash() {
        let manifest = FakeHelperDevice.manifest(for: Self.bytes, sha256: String(repeating: "0", count: 64))
        let error = #expect(throws: HelperDexError.self) { try HelperDex(bytes: Self.bytes, manifestJSON: manifest) }
        guard case .damaged(let detail) = error else {
            Issue.record("expected damaged, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("its manifest says 0000"))
    }

    @Test("a manifest for another protocol is a protocol mismatch")
    func otherProtocol() {
        #expect(throws: HelperDexError.protocolMismatch(found: 2, expected: 1)) {
            try HelperDex(bytes: Self.bytes, manifestJSON: FakeHelperDevice.manifest(for: Self.bytes, protocol: 2))
        }
    }

    @Test("an unreadable manifest marks the dex damaged")
    func unreadableManifest() {
        let error = #expect(throws: HelperDexError.self) { try HelperDex(bytes: Self.bytes, manifestJSON: Data("{}".utf8)) }
        guard case .damaged = error else {
            Issue.record("expected damaged, got \(String(describing: error))")
            return
        }
    }

    @Test("without a bundle, the library's host has no helper")
    func liveHostHasNoHelper() {
        #expect(throws: HelperDexError.notBundled("no helper was given")) { try AndroidHost.live(environment: [:]).helperDex() }
    }

    @Test("bundle failures become the fallback reasons, which say to reinstall")
    func reasons() {
        #expect(HelperUnavailableReason(.notBundled("x")).description == "Offsider's resource bundle has no helper; reinstall Offsider")
        #expect(HelperUnavailableReason(.damaged("x")).description == "the helper in Offsider's resource bundle does not match its manifest; reinstall Offsider")
        #expect(HelperUnavailableReason(.protocolMismatch(found: 2, expected: 1)).description == HelperUnavailableReason.damaged("").description)
    }
}
