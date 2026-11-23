import Foundation
import Testing

/// Every device suite installs the playground through `offsider app install`; these add the refusals, which send nothing.
@Suite("iOS device app install", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceAppInstallE2ETests {
    static func bundle(id: String, platform: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-ios-install-e2e-\(UUID().uuidString)/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleSupportedPlatforms": [platform]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
        return folder
    }

    @Test("the playground is installed and reads as built by a developer")
    func installed() async throws {
        try await IOSDeviceE2E.ensurePlaygroundInstalled()
        let info = try await IOSDeviceE2E.run("app info --app \(IOSDeviceE2E.playgroundBundleID) --json", timeout: 120)
        #expect(info.stdout.contains(#""installer":"developer""#))
    }

    @Test("a simulator build is refused before anything is sent")
    func simulatorBuild() async throws {
        let bundle = try Self.bundle(id: IOSDeviceE2E.playgroundBundleID, platform: "iPhoneSimulator")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let result = try await IOSDeviceE2E.offsider("app install \(IOSDeviceE2E.quote(bundle.path)) --app \(IOSDeviceE2E.playgroundBundleID) --json")
        #expect(result.exitCode == 1 && (result.stdout + result.stderr).contains("bundle_unreadable"))
    }

    @Test("a bundle that names another app is package_mismatch, with nothing sent")
    func mismatch() async throws {
        let bundle = try Self.bundle(id: "com.example.other", platform: "iPhoneOS")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let result = try await IOSDeviceE2E.offsider("app install \(IOSDeviceE2E.quote(bundle.path)) --app \(IOSDeviceE2E.playgroundBundleID) --json")
        #expect(result.exitCode == 1 && (result.stdout + result.stderr).contains("package_mismatch"))
    }
}
