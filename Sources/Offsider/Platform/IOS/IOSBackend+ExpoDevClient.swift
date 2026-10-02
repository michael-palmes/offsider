import Foundation
import OffsiderCore

extension IOSBackend: ExpoDevClientPreparing {
    /// Stops the app first: a running app keeps its preferences in memory and would write the old values back.
    func prepareExpoDevClient(_ appID: String, on id: DeviceID) async throws {
        let udid = id.rawValue
        let bundleID = try ExpoDevClient.validate(appID: appID)
        guard let app = try await Self.appContainer(udid: udid, bundleID: bundleID, kind: "app") else {
            throw ExpoDevClient.iosNotInstalled(bundleID: bundleID, udid: udid)
        }
        if let error = ExpoDevClient.iosBundleError(
            bundleID: bundleID,
            hasDevMenu: Self.containsDevMenuBundle(app: app),
            hasEmbeddedBundle: FileManager.default.fileExists(atPath: URL(fileURLWithPath: app).appendingPathComponent("main.jsbundle").path)
        ) {
            throw error
        }
        guard let data = try await Self.appContainer(udid: udid, bundleID: bundleID, kind: "data") else {
            throw ExpoDevClient.iosNotInstalled(bundleID: bundleID, udid: udid)
        }
        _ = try? await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ExpoDevClient.iosTerminateArguments(udid: udid, bundleID: bundleID), timeout: 15)
        for arguments in ExpoDevClient.iosDefaultsWriteArguments(udid: udid, dataContainer: data, bundleID: bundleID) {
            let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: arguments, timeout: 15)
            guard result.status == 0 else {
                throw Self.writeFailed(bundleID: bundleID, udid: udid, detail: result.stderr)
            }
        }
        let read = try await ProcessCapture.run(
            executable: "/usr/bin/xcrun",
            arguments: ExpoDevClient.iosDefaultsReadArguments(udid: udid, dataContainer: data, bundleID: bundleID),
            timeout: 15
        )
        guard read.status == 0, ExpoDevClient.iosDefaultsConfirmed(read.stdout) else {
            throw Self.writeFailed(bundleID: bundleID, udid: udid, detail: read.stderr.isEmpty ? "the values did not read back" : read.stderr)
        }
    }

    /// Nil when simctl cannot find the app, which means it is not installed.
    private static func appContainer(udid: String, bundleID: String, kind: String) async throws -> String? {
        let result = try await ProcessCapture.run(
            executable: "/usr/bin/xcrun",
            arguments: ExpoDevClient.iosAppContainerArguments(udid: udid, bundleID: bundleID, container: kind),
            timeout: 15
        )
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty ? path : nil
    }

    private static func containsDevMenuBundle(app: String) -> Bool {
        let root = URL(fileURLWithPath: app)
        let manager = FileManager.default
        if manager.fileExists(atPath: root.appendingPathComponent(ExpoDevClient.iosDevMenuBundle).path) {
            return true
        }
        let frameworks = root.appendingPathComponent("Frameworks")
        let names = (try? manager.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { name in
            manager.fileExists(atPath: frameworks.appendingPathComponent(name).appendingPathComponent(ExpoDevClient.iosDevMenuBundle).path)
        }
    }

    private static func writeFailed(bundleID: String, udid: String, detail: String) -> ExpoDevClientError {
        let line = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
        return ExpoDevClientError(.writeFailed, "Could not write the Expo dev menu preferences of \(bundleID) on simulator \(udid): \(line)")
    }
}
