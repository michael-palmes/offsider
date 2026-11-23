import Foundation
import OffsiderCore

/// `devicectl` alone, as for the other app commands: no runner or session broker starts, so this works over plain ssh too.
extension IOSDeviceBackend: AppBundleManaging {
    public func installBundle(_ bundle: AppBundle, as app: String, on id: DeviceID, replacing: (InstalledAppCopy) async throws -> Void) async throws -> AppInstall {
        let app = try ExpoDevClient.validate(appID: app)
        let udid = id.rawValue
        try await requireWired(id)
        let root = host.privateRoot
        let clone = try await host.timing.measure("install.clone") { try await Task.detached { try AppBundleStaging.clone(bundle, as: app, root: root) }.value }
        defer { clone.remove() }
        if let refusal = AppProvisioning.refusal(ProvisioningProfile.coverage(inBundle: clone.path), udid: udid, bundle: TerminalText.field(bundle.name), now: Date()) {
            throw refusal
        }
        let existing = try await installedCopy(of: app, on: id)
        if let existing { try await replacing(existing) }

        let started = ContinuousClock.now
        let result: ProcessCaptureResult
        do {
            result = try await run(DevicectlAppInstall.installArguments(udid: udid, path: clone.path), label: "device install app", on: id, timeout: DevicectlAppInstall.outerTimeout)
        } catch is ProcessCaptureTimeoutError {
            throw AppLifecycleError(.installFailed, "\(udid) did not finish the install in \(Int(DevicectlAppInstall.outerTimeout)) s, so \(app) may or may not have changed. Check with `offsider app info --app \(app) --device \(udid)`.")
        }
        guard result.status == 0 else {
            throw try refusal(result, label: "device install app", app: app, on: id)
        }
        let elapsed = ContinuousClock.now - started
        try await requireInstalled(app, reported: DevicectlAppInstall.installedIDs(Data(result.stdout.utf8)), replaced: existing != nil, on: id)
        return AppInstall(
            app: app, replaced: existing != nil, bytes: clone.bytes,
            milliseconds: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        )
    }

    public func removeBundle(_ app: String, on id: DeviceID, removing: (InstalledAppCopy) async throws -> Void) async throws -> AppUninstall {
        let app = try ExpoDevClient.validate(appID: app)
        try await requireWired(id)
        guard let existing = try await installedCopy(of: app, on: id) else { return AppUninstall(app: app, wasInstalled: false) }
        try await removing(existing)
        let result = try await run(DevicectlAppInstall.uninstallArguments(udid: id.rawValue, bundleID: app), label: "device uninstall app", on: id, timeout: DevicectlAppInstall.uninstallTimeout)
        guard result.status == 0 else {
            let cause = CoreDeviceErrorInfo(devicectlOutput: result.stdout)
            let error = IOSDeviceError.devicectlFailed("device uninstall app", udid: id.rawValue, detail: Self.firstLine(result.stderr), cause: cause)
            guard error.kind == .devicectlFailed else { throw error }
            throw AppLifecycleError(.failed, "\(id.rawValue) did not remove \(app): \(TerminalText.line(cause?.rootCause ?? Self.firstLine(result.stderr), cap: 300)). Nothing else changed.")
        }
        return AppUninstall(app: app, wasInstalled: true)
    }

    /// The copy the device holds under this id, App Store and TestFlight copies included; nil when there is none.
    private func installedCopy(of app: String, on id: DeviceID) async throws -> InstalledAppCopy? {
        let output = try await devicectl(DevicectlAppProcess.infoArguments(udid: id.rawValue, bundleID: app), label: "device info apps", on: id, app: app)
        do {
            return try DevicectlAppProcess.app(Data(output.utf8), bundleID: app).map { InstalledAppCopy(app: app, builtByDeveloper: $0.info.installer == "developer") }
        } catch let error as DevicectlDeviceList.ParseError {
            throw IOSDeviceError.devicectlFailed("device info apps", udid: id.rawValue, detail: error.detail)
        }
    }

    /// The device's own word on what it installed. Anything but the allowed app is removed at once. A reply that names nothing is settled by reading the app back, which proves an install only where no copy was there before.
    private func requireInstalled(_ app: String, reported: [String]?, replaced: Bool, on id: DeviceID) async throws {
        guard let reported else {
            let check = "Check with `offsider app info --app \(app) --device \(id.rawValue)`."
            guard !replaced else {
                throw AppLifecycleError(.installFailed, "\(id.rawValue) took the app but did not say what it installed, so the copy of \(app) there may be the old one. \(check)")
            }
            guard try await installedCopy(of: app, on: id) != nil else {
                throw AppLifecycleError(.installFailed, "\(id.rawValue) took the app but gave no answer, and does not list \(app). \(check)")
            }
            return
        }
        let foreign = reported.filter { $0 != app }
        guard !foreign.isEmpty else { return }
        var kept: [String] = []
        for other in foreign {
            let arguments = DevicectlAppInstall.uninstallArguments(udid: id.rawValue, bundleID: other)
            let removed = try? await host.devicectl.run(arguments, timeout: DevicectlAppInstall.uninstallTimeout)
            if removed?.status != 0 { kept.append(other) }
        }
        let names = foreign.map { TerminalText.field($0) }.joined(separator: ", ")
        let outcome = kept.isEmpty
            ? "Offsider removed it at once."
            : "Offsider could not remove \(kept.map { TerminalText.field($0) }.joined(separator: ", ")): remove it on the device."
        throw AppLifecycleError(.installFailed, "\(id.rawValue) installed \(names), not \(app), which Offsider's own check should have stopped. \(outcome) Please report this.")
    }

    private func run(_ arguments: [String], label: String, on id: DeviceID, timeout: TimeInterval) async throws -> ProcessCaptureResult {
        do {
            return try await host.devicectl.run(arguments, timeout: timeout)
        } catch let error as IOSDeviceError {
            throw error
        } catch let error as ProcessCaptureTimeoutError {
            throw error
        } catch {
            throw IOSDeviceError.devicectlFailed(label, udid: id.rawValue, detail: error.localizedDescription)
        }
    }

    /// A lock or Developer Mode off keeps its own reason and exit 7; any other refusal is the device's verdict on the build.
    private func refusal(_ result: ProcessCaptureResult, label: String, app: String, on id: DeviceID) throws -> AppLifecycleError {
        let cause = CoreDeviceErrorInfo(devicectlOutput: result.stdout)
        let error = IOSDeviceError.devicectlFailed(label, udid: id.rawValue, detail: Self.firstLine(result.stderr), cause: cause)
        guard error.kind == .devicectlFailed else { throw error }
        if Self.saysLocked(result.stderr) || Self.saysLocked(cause?.rootCause ?? "") {
            throw IOSDeviceError(.locked, "\(id.rawValue) is locked, so iOS did not install \(app). Unlock it and retry; Offsider never types a passcode.")
        }
        return DevicectlAppInstall.refusal(cause, stderr: result.stderr, app: app, device: id.rawValue)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "devicectl gave no reason"
    }
}
