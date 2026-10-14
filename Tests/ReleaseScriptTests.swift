import CryptoKit
import Foundation
import Testing

@Suite("Release script")
struct ReleaseScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/release.sh")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private static func payloadDirectory() throws -> (dist: URL, payload: Data) {
        let dist = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let payload = Data("not a payload".utf8)
        try payload.write(to: dist.appendingPathComponent("offsider-0.0.0-arm64-unsigned.tar.gz"))
        return (dist, payload)
    }

    @Test("unpack-payload refuses a payload whose digest differs from the one the build job recorded, before unpacking")
    func unpackPayloadRefusesDigestMismatch() throws {
        let (dist, _) = try Self.payloadDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let wrong = String(repeating: "0", count: 64)
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", wrong])
        #expect(result.status == 1)
        #expect(result.stderr.contains("payload digest mismatch"))
        #expect(!FileManager.default.fileExists(atPath: dist.appendingPathComponent("offsider-0.0.0-arm64").path))
    }

    @Test("unpack-payload accepts the recorded digest and only then unpacks")
    func unpackPayloadAcceptsMatchingDigest() throws {
        let (dist, payload) = try Self.payloadDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", digest])
        #expect(result.stderr.contains("payload digest matches"))
        #expect(!result.stderr.contains("digest mismatch"))
    }

    @Test("unpack-payload refuses a digest that is not 64 hex characters without reading the payload")
    func unpackPayloadRefusesMalformedDigest() throws {
        let (dist, _) = try Self.payloadDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", "abc"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("64 lowercase hex"))
    }

    @Test("release builds carry no entitlements, so library validation stays on; ad-hoc builds carry the opt-out")
    func entitlementFiles() throws {
        let release = try Self.plist("entitlements.plist")
        let adhoc = try Self.plist("entitlements-adhoc.plist")
        #expect(release.isEmpty)
        #expect(adhoc["com.apple.security.cs.disable-library-validation"] as? Bool == true)
    }

    @Test("a release run refuses an entitlements file that disables library validation before doing anything")
    func releaseRefusesLibraryValidationOptOut() throws {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/release.sh")
        process.arguments = ["stage", "--version", "0.0.0"]
        var environment = ProcessInfo.processInfo.environment
        environment["ENTITLEMENTS"] = Self.root.appendingPathComponent("entitlements-adhoc.plist").path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 1)
        #expect(output.contains("release builds keep library validation on"))
        #expect(!output.contains("missing"))
    }
}
