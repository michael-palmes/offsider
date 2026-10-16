import Foundation
import OffsiderCore
import OffsiderIOSDevice

/// A physical iPhone or iPad is driven inside one app: `--app`, else `offsider.login.json`'s bundleId, else the allowance's only app.
enum IOSDevicePinning {
    @MainActor
    static func configure(
        _ backend: IOSDeviceBackend, allowance: DeviceAllowance, policy: PhysicalDevicePolicy,
        profileBundleID: () -> String? = { (try? LoginProfiles.load(project: nil, warn: { _ in }))??.bundleID }
    ) {
        backend.pinPolicy = { app in refusal(app, allowance: allowance, policy: policy) }
        if backend.targetApp == nil {
            backend.targetApp = defaultPin(profile: profileBundleID(), allowance: allowance)
        }
    }

    static func defaultPin(profile: String?, allowance: DeviceAllowance) -> String? {
        if let profile, !profile.isEmpty { return profile }
        return allowance.apps.count == 1 ? allowance.apps[0] : nil
    }

    /// Why `app` may not be driven on the device, or nil when it may.
    static func refusal(_ app: String, allowance: DeviceAllowance, policy: PhysicalDevicePolicy, audience: ErrorAudience = .current) -> String? {
        policy.appRefusal(app, on: allowance, audience: audience)
    }
}
