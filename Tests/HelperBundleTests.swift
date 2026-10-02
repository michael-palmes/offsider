import Foundation
@testable import OffsiderAndroid
import Testing
@testable import Offsider

@Suite("Android helper bundle")
struct HelperBundleTests {
    static let committed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Offsider/Resources/helper")

    struct Manifest: Decodable {
        struct Dex: Decodable {
            let sha256: String
        }

        let `protocol`: Int
        let dex: Dex
    }

    @Test("the executable's bundle holds the committed dex, checked against its manifest, at this Offsider's protocol")
    func loadsCommittedDex() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.committed.appendingPathComponent("manifest.json")))
        let dex = try HelperBundle.load()

        #expect(dex.sha256 == manifest.dex.sha256)
        #expect(dex.bytes == (try Data(contentsOf: Self.committed.appendingPathComponent("offsider-helper.dex"))))
        #expect(manifest.protocol == HelperDex.protocolVersion)
        #expect(try AndroidHost.cli().helperDex() == dex)
    }

    static func folder(dex: Data?, manifest: Data?) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-helper-bundle-\(UUID().uuidString)")
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try dex?.write(to: helper.appendingPathComponent("offsider-helper.dex"))
        try manifest?.write(to: helper.appendingPathComponent("manifest.json"))
        return try #require(Bundle(url: root))
    }

    @Test("a bundle without the helper is not bundled, and a changed dex is damaged")
    func brokenBundles() throws {
        let manifest = try Data(contentsOf: Self.committed.appendingPathComponent("manifest.json"))
        let dex = try Data(contentsOf: Self.committed.appendingPathComponent("offsider-helper.dex"))

        let missing = #expect(throws: HelperDexError.self) { try HelperBundle.read(from: Self.folder(dex: nil, manifest: manifest)) }
        guard case .notBundled = missing else {
            Issue.record("expected notBundled, got \(String(describing: missing))")
            return
        }
        var changed = dex
        changed[changed.count - 1] ^= 0xFF
        let damaged = #expect(throws: HelperDexError.self) { try HelperBundle.read(from: Self.folder(dex: changed, manifest: manifest)) }
        guard case .damaged = damaged else {
            Issue.record("expected damaged, got \(String(describing: damaged))")
            return
        }
    }
}
