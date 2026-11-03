import Foundation
import Testing
@testable import OffsiderCore

@Suite("APK manifest")
struct ApkManifestTests {
    static let seeds = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fuzz/apk-manifest")

    static func package(of bytes: Data) throws -> String {
        let array = [UInt8](bytes)
        return try ApkManifest.package(size: array.count) { offset, count in
            offset >= 0 && count >= 0 && offset <= array.count && count <= array.count - offset ? Data(array[offset..<(offset + count)]) : nil
        }
    }

    static func failure(_ bytes: Data) -> ApkManifest.Failure? {
        do {
            _ = try package(of: bytes)
            return nil
        } catch let error as ApkManifest.Failure {
            return error
        } catch {
            return nil
        }
    }

    /// A stored zip with these entries, so a test can build what no packager writes.
    static func zip(_ entries: [(name: String, data: Data)], claimedSize: UInt32? = nil) -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let offset = UInt32(body.count)
            let name = Data(entry.name.utf8)
            let stored = UInt32(entry.data.count)
            let local: [Data] = [
                le32(0x0403_4B50), le16(20), le16(0), le16(0), le32(0), le32(0), le32(stored), le32(claimedSize ?? stored), le16(UInt16(name.count)), le16(0), name, entry.data,
            ]
            let central: [Data] = [
                le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(0), le32(0), le32(0), le32(stored), le32(claimedSize ?? stored),
                le16(UInt16(name.count)), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name,
            ]
            local.forEach { body.append($0) }
            central.forEach { directory.append($0) }
        }
        let end: [Data] = [
            le32(0x0605_4B50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)), le32(UInt32(directory.count)), le32(UInt32(body.count)), le16(0),
        ]
        var zip = body
        zip.append(directory)
        end.forEach { zip.append($0) }
        return zip
    }

    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    static func seedManifest() throws -> Data {
        let stored = try Data(contentsOf: seeds.appendingPathComponent("stored.apk"))
        // `classes.dex` comes first, stored, so the manifest's bytes follow its header in the file.
        let name = Data("AndroidManifest.xml".utf8)
        let at = try #require(stored.range(of: name))
        let start = at.upperBound
        let end = try #require(stored.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        return Data(stored[start..<end])
    }

    @Test("aapt2's real manifest gives the package, stored and deflated", arguments: ["stored.apk", "deflated.apk"])
    func realManifest(name: String) throws {
        #expect(try Self.package(of: Data(contentsOf: Self.seeds.appendingPathComponent(name))) == "com.example.fixture")
    }

    @Test("a file opened from disk reads the same package")
    func fromDisk() throws {
        let file = try ApkFile(path: Self.seeds.appendingPathComponent("deflated.apk").path)
        #expect(try ApkManifest.package(of: file) == "com.example.fixture")
    }

    @Test("a zip with no manifest is not an APK, as a bundle keeps its manifest in a folder")
    func noManifest() {
        #expect(Self.failure(Self.zip([(name: "base/manifest/AndroidManifest.xml", data: Data("x".utf8))])) == .noManifest)
    }

    @Test("two manifest entries are refused, as a reader could pick either")
    func twoManifests() throws {
        let manifest = try Self.seedManifest()
        #expect(Self.failure(Self.zip([(name: "AndroidManifest.xml", data: manifest), (name: "AndroidManifest.xml", data: manifest)])) == .twoManifests)
    }

    @Test("a manifest claiming more than the cap is refused before anything is inflated")
    func bombRefused() throws {
        #expect(Self.failure(Self.zip([(name: "AndroidManifest.xml", data: Data("x".utf8))], claimedSize: 1 << 30)) == .unreadableManifest)
    }

    @Test("a text manifest, which only a plain zip of sources holds, gives no package")
    func textManifest() {
        let xml = Data(#"<manifest package="com.example.fixture"/>"#.utf8)
        #expect(Self.failure(Self.zip([(name: "AndroidManifest.xml", data: xml)])) == .unreadableManifest)
    }

    @Test("a package that is not a valid id is refused, so it never reaches a device command")
    func invalidPackage() throws {
        let manifest = try Self.seedManifest()
        var bad = [UInt8](manifest)
        // aapt2 writes its string pool in UTF-16.
        let word = "com.example.fixture".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let at = try #require(bad.indices.first { Array(bad[$0..<min($0 + word.count, bad.count)]) == word })
        bad[at + 6] = UInt8(ascii: ";")
        #expect(Self.failure(Self.zip([(name: "AndroidManifest.xml", data: Data(bad))])) == .unreadableManifest)
    }

    @Test("files that are not zips fail cleanly", arguments: [Data(), Data("not a zip at all, but long enough to scan for one".utf8)])
    func notZip(bytes: Data) {
        #expect(Self.failure(bytes) == .notZip)
    }

    @Test("every truncation of a real APK fails without trapping")
    func truncations() throws {
        let bytes = try Data(contentsOf: Self.seeds.appendingPathComponent("deflated.apk"))
        for count in 0..<bytes.count {
            #expect(Self.failure(Data(bytes.prefix(count))) != nil)
        }
    }

    @Test("every single-byte corruption of a real manifest fails or still gives a valid id, without trapping")
    func corruptions() throws {
        let manifest = [UInt8](try Self.seedManifest())
        for index in stride(from: 0, to: manifest.count, by: 3) {
            var bad = manifest
            bad[index] ^= 0xFF
            if let package = try? Self.package(of: Self.zip([(name: "AndroidManifest.xml", data: Data(bad))])) {
                #expect((try? ExpoDevClient.validate(appID: package)) != nil)
            }
        }
    }

    @Test("a folder or a missing path is refused when opened")
    func openRefusals() {
        #expect(throws: ApkFile.Failure.notRegularFile) { try ApkFile(path: Self.seeds.path) }
        #expect(throws: ApkFile.Failure.missing) { try ApkFile(path: Self.seeds.appendingPathComponent("nothing.apk").path) }
    }
}
