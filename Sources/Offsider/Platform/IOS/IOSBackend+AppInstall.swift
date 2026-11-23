import Foundation
import OffsiderCore

/// A simulator has no allowance and holds nothing personal, so a copy already there is replaced or removed without a question.
extension IOSBackend: AppBundleManaging {
    static let installTimeout: TimeInterval = 120

    func installBundle(_ bundle: AppBundle, as app: String, on id: DeviceID, replacing: (InstalledAppCopy) async throws -> Void) async throws -> AppInstall {
        let bundleID = try ExpoDevClient.validate(appID: app)
        let clone = try await Task.detached { try AppBundleStaging.clone(bundle, as: bundleID) }.value
        defer { clone.remove() }
        let existing = try await installedCopy(of: bundleID, on: id)
        if let existing { try await replacing(existing) }

        let started = ContinuousClock.now
        let result = try await Self.simctl(SimulatorApps.installArguments(udid: id.rawValue, path: clone.path), timeout: Self.installTimeout)
        guard result.status == 0 else {
            throw AppLifecycleError(.installFailed, "Simulator \(id.rawValue) refused to install \(bundleID), so nothing changed. It said: \(Self.reason(result)).")
        }
        let elapsed = ContinuousClock.now - started
        guard try await installedCopy(of: bundleID, on: id) != nil else {
            throw AppLifecycleError(.installFailed, "simctl reported an install, but simulator \(id.rawValue) does not list \(bundleID). Check with `offsider app info --app \(bundleID) --device \(id.rawValue)`.")
        }
        return AppInstall(
            app: bundleID, replaced: existing != nil, bytes: clone.bytes,
            milliseconds: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        )
    }

    func removeBundle(_ app: String, on id: DeviceID, removing: (InstalledAppCopy) async throws -> Void) async throws -> AppUninstall {
        let bundleID = try ExpoDevClient.validate(appID: app)
        guard let existing = try await installedCopy(of: bundleID, on: id) else { return AppUninstall(app: bundleID, wasInstalled: false) }
        try await removing(existing)
        let result = try await Self.simctl(SimulatorApps.uninstallArguments(udid: id.rawValue, bundleID: bundleID), timeout: 60)
        guard result.status == 0 else {
            throw AppLifecycleError(.failed, "Simulator \(id.rawValue) did not remove \(bundleID): \(Self.reason(result)).")
        }
        return AppUninstall(app: bundleID, wasInstalled: true)
    }

    /// `simctl get_app_container` fails with "No such file" for an app that is not installed, whatever `appinfo` prints for one.
    private func installedCopy(of bundleID: String, on id: DeviceID) async throws -> InstalledAppCopy? {
        let result = try await Self.simctl(ExpoDevClient.iosAppContainerArguments(udid: id.rawValue, bundleID: bundleID, container: "app"))
        if result.status == 0 { return InstalledAppCopy(app: bundleID, builtByDeveloper: true) }
        guard SimulatorApps.notInstalled(stderr: result.stderr) else {
            throw AppLifecycleError(.failed, "Simulator \(id.rawValue) did not say whether \(bundleID) is installed: \(Self.reason(result)).")
        }
        return nil
    }

    private static func reason(_ result: ProcessCaptureResult) -> String {
        let lines = result.stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return TerminalText.line(lines.isEmpty ? "exit status \(result.status)" : lines.suffix(2).joined(separator: " "), cap: 300)
    }
}
