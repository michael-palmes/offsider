import Foundation
import OffsiderCore

extension IOSDeviceBackend {
    /// Set by the CLI for an allowed physical device: the refusal for an app it may not drive, or nil. Without it no pin is enforced.
    public var pinPolicy: (@MainActor (String) -> String?)? {
        get { state.pinPolicy }
        set { state.pinPolicy = newValue }
    }

    /// The pinned app is named, allowed and, per the runner's private active-app lookup, in front; `maxAge` reuses a recent answer.
    public func requirePinnedAppInFront(_ id: DeviceID, maxAge: TimeInterval = 0) async throws {
        guard state.pinPolicy != nil else { return }
        let app = try requirePermittedPin(id)
        if maxAge > 0, let confirmed = state.pinConfirmed[id.rawValue], Date().timeIntervalSince(confirmed) < maxAge { return }
        let client = try await runner(for: id)
        let answer = try await host.timing.measure("foreground") { try await client.foreground(app: app) }
        guard answer.inFront else {
            state.pinConfirmed[id.rawValue] = nil
            let active = answer.activeBundleID.map { "\($0) is in front" } ?? "another app or the system is in front"
            throw IOSDeviceError(
                .appNotAllowed,
                "\(app) is not the app in front on \(id.rawValue) (\(active)), so Offsider did not read or touch the screen. Ask the user to open \(app), then retry."
            )
        }
        state.pinConfirmed[id.rawValue] = Date()
    }

    /// The pinned app, checked against the policy without asking the device.
    @discardableResult
    func requirePermittedPin(_ id: DeviceID) throws -> String {
        guard let policy = state.pinPolicy else { return targetApp ?? "" }
        guard let app = targetApp else {
            throw IOSDeviceError(
                .appRequired,
                "A physical iPhone or iPad is driven only inside one app, and none was named for \(id.rawValue). Pass --app <bundle-id>, name it in offsider.login.json's bundleId, or pin one app when allowing the device."
            )
        }
        if let refusal = policy(app) {
            throw IOSDeviceError(.appNotAllowed, refusal)
        }
        return app
    }

    /// usbmuxd still lists the device on USB; checked before each input batch so a cable pulled mid-run sends nothing over Wi-Fi.
    func requireWired(_ id: DeviceID) async throws {
        guard state.pinPolicy != nil else { return }
        let usbmux = host.usbmux
        let udid = id.rawValue
        let listed: Bool
        do {
            listed = try await Task.detached { try usbmux.listsOnUSB(udid) }.value
        } catch {
            throw IOSDeviceError.notWired(udid)
        }
        guard listed else { throw IOSDeviceError.notWired(udid) }
    }
}
