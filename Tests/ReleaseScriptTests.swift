import Foundation
import Testing

@Suite("Release script")
struct ReleaseScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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
