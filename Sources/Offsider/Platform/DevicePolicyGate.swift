import Foundation
import OffsiderCore

/// Decides whether a physical device may be driven. Built only when a command names one, so simulators and emulators never read the file, the Keychain or cfprefsd.
struct DevicePolicyGate: Sendable {
    /// Tests inject a gate; there is no environment switch.
    @TaskLocal static var current = DevicePolicyGate.live

    let policy: @Sendable () -> PhysicalDevicePolicy
    let now: @Sendable () -> Date

    init(policy: @escaping @Sendable () -> PhysicalDevicePolicy, now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.now = now
    }

    static let live = DevicePolicyGate(policy: { LivePolicy.shared })

    /// A gate with a fixed policy, for tests and for `devices add` and `remove` right after it writes.
    static func fixed(_ policy: PhysicalDevicePolicy, now: Date? = nil) -> DevicePolicyGate {
        DevicePolicyGate(policy: { policy }, now: { now ?? Date() })
    }

    func decision(platform: DevicePlatform, key: String) -> DeviceDecision {
        policy().decision(platform: platform, key: key, now: now())
    }

    /// The allowance for the device, or `device_not_allowed` naming the command a person runs.
    @discardableResult
    func require(platform: DevicePlatform, key: String, displayName: String? = nil) throws -> DeviceAllowance {
        switch decision(platform: platform, key: key) {
        case .allowed(let allowance):
            return allowance
        case .refused(let refusal):
            throw CLIError.deviceNotAllowed(name: displayName, key: key, refusal: refusal)
        }
    }

    /// The live policy, read once per process.
    private enum LivePolicy {
        static let shared = read(store: DevicePolicySources.store(), seal: KeychainDeviceAllowListSeal(), managed: LiveManagedPreferences())
    }

    static func read(store: DeviceAllowListStore?, seal: any DeviceAllowListSealing, managed: any ManagedPreferenceSource) -> PhysicalDevicePolicy {
        let managedPolicy = ManagedDevicePolicy.read(from: managed)
        guard let store else {
            return PhysicalDevicePolicy(managed: managedPolicy, list: .empty, listProblem: "this account has no home folder")
        }
        do {
            let snapshot = try store.load()
            return PhysicalDevicePolicy(managed: managedPolicy, list: snapshot.list, sealIntact: seal.isIntact(snapshot))
        } catch {
            return PhysicalDevicePolicy(managed: managedPolicy, list: .empty, listProblem: "\(store.path): \(error)")
        }
    }
}

enum DevicePolicySources {
    /// `~/.config/offsider/allowed-devices.json` from the password database's home; nil when there is none.
    static func store() -> DeviceAllowListStore? {
        UserConfigDirectory.live().map(DeviceAllowListStore.init(directory:))
    }
}

extension DevicePolicyGate {
    /// On an allowed physical device, `app_not_allowed` unless `app` is within its pins (or any app is) and not deny-listed.
    func requireApp(_ app: String, on allowance: DeviceAllowance) throws {
        guard let refusal = policy().appRefusal(app, on: allowance) else { return }
        throw CLIError(
            errorDescription: refusal, reason: .appNotAllowed,
            hint: refusal.contains(" is not among the apps allowed on ") ? "offsider devices add" : nil
        )
    }
}
