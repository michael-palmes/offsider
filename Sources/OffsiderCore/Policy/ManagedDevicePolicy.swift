import CoreFoundation
import Foundation

/// A managed preference as Offsider honours it: only a forced value (an MDM profile or `/Library/Managed Preferences`) counts.
public enum ManagedPreferenceValue: Equatable, Sendable {
    case bool(Bool)
    case strings([String])
    /// Forced, but not a type Offsider reads.
    case unreadable
}

/// Where managed preferences come from; tests inject forced and unforced values.
public protocol ManagedPreferenceSource: Sendable {
    /// The forced value for `key`, or nil when the key is absent or not forced.
    func forcedValue(forKey key: String) -> ManagedPreferenceValue?
}

/// `CFPreferences` in the `com.mpalmes.offsider` domain; a value someone wrote with `defaults write` is not forced and is ignored.
public struct LiveManagedPreferences: ManagedPreferenceSource {
    public static let domain = "com.mpalmes.offsider"

    let domain: String

    public init(domain: String = LiveManagedPreferences.domain) {
        self.domain = domain
    }

    public func forcedValue(forKey key: String) -> ManagedPreferenceValue? {
        let domain = self.domain as CFString
        guard CFPreferencesAppValueIsForced(key as CFString, domain), let value = CFPreferencesCopyAppValue(key as CFString, domain) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return .bool(CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)))
        }
        if CFGetTypeID(value) == CFArrayGetTypeID(), let items = value as? [Any] {
            let strings = items.compactMap { $0 as? String }
            return strings.count == items.count ? .strings(strings) : .unreadable
        }
        return .unreadable
    }
}

/// The ceiling an administrator set for physical devices. Absent keys set no limit; a key of the wrong type refuses every physical device.
public struct ManagedDevicePolicy: Equatable, Sendable {
    public static let allowPhysicalDevicesKey = "allowPhysicalDevices"
    public static let allowedDeviceIDsKey = "allowedDeviceIDs"
    public static let allowedBundleIDsKey = "allowedBundleIDs"

    public let allowPhysicalDevices: Bool?
    public let allowedDeviceIDs: [String]?
    public let allowedBundleIDs: [String]?
    /// A forced key held a value of the wrong type.
    public let unreadable: Bool

    public init(allowPhysicalDevices: Bool? = nil, allowedDeviceIDs: [String]? = nil, allowedBundleIDs: [String]? = nil, unreadable: Bool = false) {
        self.allowPhysicalDevices = allowPhysicalDevices
        self.allowedDeviceIDs = allowedDeviceIDs
        self.allowedBundleIDs = allowedBundleIDs
        self.unreadable = unreadable
    }

    public static let none = ManagedDevicePolicy()

    /// True when any key is forced.
    public var present: Bool {
        allowPhysicalDevices != nil || allowedDeviceIDs != nil || allowedBundleIDs != nil || unreadable
    }

    public static func read(from source: any ManagedPreferenceSource) -> ManagedDevicePolicy {
        var unreadable = false
        var allow: Bool?
        switch source.forcedValue(forKey: allowPhysicalDevicesKey) {
        case .bool(let value): allow = value
        case nil: break
        default: unreadable = true
        }
        func strings(_ key: String) -> [String]? {
            switch source.forcedValue(forKey: key) {
            case .strings(let values): return values
            case nil: return nil
            default:
                unreadable = true
                return nil
            }
        }
        let devices = strings(allowedDeviceIDsKey)
        let bundles = strings(allowedBundleIDsKey)
        return ManagedDevicePolicy(allowPhysicalDevices: allow, allowedDeviceIDs: devices, allowedBundleIDs: bundles, unreadable: unreadable)
    }

    /// Whether the managed list names the device; UDIDs compare without case.
    func lists(platform: DevicePlatform, key: String) -> Bool {
        guard let allowedDeviceIDs else { return true }
        return allowedDeviceIDs.contains { listed in
            let trimmed = listed.trimmingCharacters(in: .whitespaces)
            return platform == .ios ? trimmed.uppercased() == key.uppercased() : trimmed == key
        }
    }
}
