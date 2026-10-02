import CryptoKit
import Foundation
import Testing

@Suite("Android helper source consistency")
struct HelperSourceConsistencyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let bundled = root.appendingPathComponent("Sources/Offsider/Resources/helper")
    static let sources = root.appendingPathComponent("AndroidHelper/src")
    static let rebuildHint = "run scripts/build.sh helper and commit the dex and manifest with the Java source"

    struct Manifest: Decodable {
        struct Dex: Decodable {
            let file: String
            let bytes: Int
            let sha256: String
        }

        struct Sources: Decodable {
            let files: Int
            let sha256: String
        }

        let helperVersion: String
        let `protocol`: Int
        let dex: Dex
        let sources: Sources
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: bundled.appendingPathComponent("manifest.json")))
    }

    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Every `.java` file under `AndroidHelper/src`, relative to it, in byte order (the build script's `LC_ALL=C sort`).
    static func javaPaths() throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        let paths = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".java") }
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    @Test("the committed dex has the size and SHA-256 its manifest records")
    func dexMatchesManifest() throws {
        let manifest = try Self.manifest()
        #expect(manifest.dex.file == "offsider-helper.dex")
        let dex = try Data(contentsOf: Self.bundled.appendingPathComponent(manifest.dex.file))
        #expect(dex.count == manifest.dex.bytes, "The dex and its manifest disagree: \(Self.rebuildHint)")
        #expect(Self.hex(SHA256.hash(data: dex)) == manifest.dex.sha256, "The dex and its manifest disagree: \(Self.rebuildHint)")
    }

    @Test("the manifest's sources hash covers the Java as it is now, so an edit without a rebuild fails")
    func sourcesMatchManifest() throws {
        let manifest = try Self.manifest()
        let paths = try Self.javaPaths()
        var hasher = SHA256()
        for path in paths {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: Self.sources.appendingPathComponent(path)))
            hasher.update(data: Data([0]))
        }
        #expect(paths.count == manifest.sources.files, "AndroidHelper/src gained or lost files: \(Self.rebuildHint)")
        #expect(Self.hex(hasher.finalize()) == manifest.sources.sha256, "AndroidHelper/src changed: \(Self.rebuildHint)")
    }

    @Test("PROTOCOL and VERSION in OffsiderHelper.java equal the manifest's")
    func constantsMatchManifest() throws {
        let manifest = try Self.manifest()
        let main = Self.sources.appendingPathComponent("com/mpalmes/offsider/helper/OffsiderHelper.java")
        let source = try String(contentsOf: main, encoding: .utf8)
        let protocolNumber = try #require(source.firstMatch(of: #/static final int PROTOCOL = (\d+);/#)?.1)
        let version = try #require(source.firstMatch(of: #/static final String VERSION = "([^"]+)";/#)?.1)
        #expect(Int(protocolNumber) == manifest.protocol)
        #expect(String(version) == manifest.helperVersion)
    }
}
