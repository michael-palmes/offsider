import Foundation
import Testing

/// Installs only the playground, from a copy of the bundle the simulator already holds, and leaves it installed.
@Suite("App install and uninstall on a simulator", .serialized, .enabled(if: isE2EEnabled))
struct AppInstallE2ETests {
    static var udid: String { defaultSimulatorUDID ?? "" }
    static let playground = "com.mpalmes.offsider.playground"

    static func offsider(_ command: String) async throws -> SeparatedCommandOutput {
        try await TestHelpers.runOffsiderCommandSeparated(command, simulatorUDID: udid)
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The installed playground copied to a temp folder, so the test owns a simulator build whatever built it.
    static func playgroundCopy() async throws -> URL {
        let found = try await CommandRunner.runSeparated("xcrun simctl get_app_container \(udid) \(playground) app")
        let installed = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.exitCode == 0, !installed.isEmpty else {
            throw TestError.unexpectedState("the playground is not installed on \(udid): \(found.stderr)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-install-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("OffsiderPlayground.app", isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: installed, isDirectory: true), to: copy)
        return copy
    }

    static func object(_ output: SeparatedCommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: TestHelpers.jsonObject(in: output.stdout)) as? [String: Any], "no JSON in: \(output.stdout)\(output.stderr)")
    }

    @Test("the playground is removed, reads as not installed, installs again, and a second install replaces it")
    func roundTrip() async throws {
        let copy = try await Self.playgroundCopy()
        let path = Self.quote(copy.path)
        do {
            let removed = try Self.object(try await Self.offsider("app uninstall --app \(Self.playground) --json"))
            #expect(removed["wasInstalled"] as? Bool == true)
            let info = try await Self.offsider("app info --app \(Self.playground)")
            #expect(info.exitCode == 1 && (info.stdout + info.stderr).contains("app_not_installed"))
            let again = try Self.object(try await Self.offsider("app uninstall --app \(Self.playground) --json"))
            #expect(again["wasInstalled"] as? Bool == false)

            let installed = try Self.object(try await Self.offsider("app install \(path) --json"))
            #expect(installed["app"] as? String == Self.playground)
            #expect(installed["replaced"] as? Bool == false)
            #expect(installed["path"] as? String == copy.path && installed["apk"] == nil)
            #expect((installed["bytes"] as? Int ?? 0) > 0)
            #expect(try await Self.offsider("app info --app \(Self.playground)").exitCode == 0)

            let replaced = try Self.object(try await Self.offsider("app install \(path) --app \(Self.playground) --json"))
            #expect(replaced["replaced"] as? Bool == true)
        } catch {
            _ = try? await CommandRunner.runSeparated("xcrun simctl install \(Self.udid) \(path)")
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            throw error
        }
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }

    @Test("a bundle that names another app, a device build and an .ipa are refused with nothing installed")
    func refusals() async throws {
        let copy = try await Self.playgroundCopy()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        let mismatch = try await Self.offsider("app install \(Self.quote(copy.path)) --app com.example.other")
        #expect(mismatch.exitCode == 1 && (mismatch.stdout + mismatch.stderr).contains("package_mismatch"))

        let plist = copy.appendingPathComponent("Info.plist")
        var values = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        values["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: plist)
        let device = try await Self.offsider("app install \(Self.quote(copy.path))")
        #expect(device.exitCode == 1 && (device.stdout + device.stderr).contains("bundle_unreadable") && (device.stdout + device.stderr).contains("device build"))

        let archive = copy.deletingLastPathComponent().appendingPathComponent("OffsiderPlayground.ipa")
        try Data("x".utf8).write(to: archive)
        let ipa = try await Self.offsider("app install \(Self.quote(archive.path))")
        #expect(ipa.exitCode == 1 && (ipa.stdout + ipa.stderr).contains("bundle_unreadable"))

        #expect(try await Self.offsider("app info --app \(Self.playground)").exitCode == 0, "the playground is still installed")
    }
}
