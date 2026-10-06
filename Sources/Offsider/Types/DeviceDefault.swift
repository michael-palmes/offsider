import Foundation

/// Where a command's device came from.
enum DeviceSource: String, Sendable {
    case option
    case environment
}

/// `OFFSIDER_DEVICE`, the device a command uses when `--device` is absent; a test binds its own value.
enum DeviceDefault {
    static let environmentKey = "OFFSIDER_DEVICE"
    static let missingMessage = "Missing --device <id>. Pass --device, or set OFFSIDER_DEVICE; run offsider list-devices to see IDs."

    @TaskLocal static var environment: @Sendable () -> String? = { ProcessInfo.processInfo.environment[environmentKey] }

    /// `--device` wins; a blank `OFFSIDER_DEVICE` counts as unset.
    static func resolve(explicit: String?, environment: String?) -> (id: String, source: DeviceSource)? {
        if let explicit { return (explicit, .option) }
        guard let value = environment?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return (value, .environment)
    }

    static func resolve(explicit: String?) -> (id: String, source: DeviceSource)? {
        resolve(explicit: explicit, environment: environment())
    }
}
