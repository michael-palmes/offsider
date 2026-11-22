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
    /// Every forced key in the domain, so a key this build does not know is seen rather than ignored.
    func forcedKeys() -> [String]
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
            return unsafe .bool(CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)))
        }
        if CFGetTypeID(value) == CFArrayGetTypeID(), let items = value as? [Any] {
            let strings = items.compactMap { $0 as? String }
            return strings.count == items.count ? .strings(strings) : .unreadable
        }
        return .unreadable
    }

    /// `CFPreferencesCopyKeyList` leaves out managed keys, so this filters the merged view; about a millisecond, read on the physical path only.
    public func forcedKeys() -> [String] {
        let defaults = Bundle.main.bundleIdentifier == domain ? UserDefaults.standard : UserDefaults(suiteName: domain)
        let names = defaults?.dictionaryRepresentation().keys.filter { !ManagedDevicePolicy.knownKeys.contains($0) } ?? []
        // A key forced for every app shows in this domain's merged view too, but is not Offsider's.
        return names.filter { CFPreferencesAppValueIsForced($0 as CFString, domain as CFString) && !CFPreferencesAppValueIsForced($0 as CFString, kCFPreferencesAnyApplication) }.sorted()
    }
}

/// Managed refusals name the organisation and the key it set, so a person knows whom to ask and an administrator what to change.
public enum ManagedRefusalText {
    public static let physicalOff = "your organisation turns off phones on this Mac (allowPhysicalDevices)"
    public static let deviceNotListed = "your organisation does not list this device (allowedDeviceIDs)"
    public static let testDevicesOff = "your organisation does not allow test devices (allowTestDevices)"

    public static func appNotListed(_ app: String) -> String { "your organisation does not list \(app) (allowedBundleIDs)" }
    public static func appDenied(_ app: String) -> String { "your organisation denies \(app) (deniedBundleIDs)" }
    public static func appsLimited(_ key: String) -> String { "your organisation limits the apps on this Mac (\(key))" }
    public static func unreadable(_ key: String) -> String { "your organisation's setting could not be read, so Offsider refuses every phone (\(key))" }
    public static func unknown(_ key: String) -> String { "your organisation sets a setting this Offsider does not know, so it refuses every phone (\(key))" }
    /// `deniedBundleIDs` of the wrong type, where `login` and `credential` read it for any device.
    public static let deniedListUnreadable = "your organisation's setting could not be read, so Offsider refuses every app (deniedBundleIDs)"

    /// `clause` with a capital, to open a sentence.
    public static func capitalised(_ clause: String) -> String { clause.prefix(1).uppercased() + clause.dropFirst() }
    /// `clause` as a sentence of its own.
    public static func sentence(_ clause: String) -> String { capitalised(clause) + "." }
}

/// The ceiling an administrator set for physical devices. Absent keys set no limit; a key of the wrong type refuses every physical device.
public struct ManagedDevicePolicy: Equatable, Sendable {
    public static let allowPhysicalDevicesKey = "allowPhysicalDevices"
    public static let allowedDeviceIDsKey = "allowedDeviceIDs"
    public static let allowedBundleIDsKey = "allowedBundleIDs"
    /// Apps added to the built-in deny-list; an entry ending in `.` denies every id it starts.
    public static let deniedBundleIDsKey = "deniedBundleIDs"
    /// True lets a test device be driven whole on a managed Mac; without it, or beside a bundle list, it is a plain Any app allowance.
    public static let allowTestDevicesKey = "allowTestDevices"

    public let allowPhysicalDevices: Bool?
    public let allowedDeviceIDs: [String]?
    public let allowedBundleIDs: [String]?
    public let deniedBundleIDs: [String]?
    public let allowTestDevices: Bool?
    /// Forced keys holding a value of the wrong type, in `knownKeys` order.
    public let unreadableKeys: [String]
    /// Forced keys this build does not know, perhaps set for a newer Offsider, sorted.
    public let unknownKeys: [String]

    public init(
        allowPhysicalDevices: Bool? = nil, allowedDeviceIDs: [String]? = nil, allowedBundleIDs: [String]? = nil, deniedBundleIDs: [String]? = nil,
        allowTestDevices: Bool? = nil, unreadableKeys: [String] = [], unknownKeys: [String] = []
    ) {
        self.allowPhysicalDevices = allowPhysicalDevices
        self.allowedDeviceIDs = allowedDeviceIDs
        self.allowedBundleIDs = allowedBundleIDs
        self.deniedBundleIDs = deniedBundleIDs
        self.allowTestDevices = allowTestDevices
        self.unreadableKeys = unreadableKeys
        self.unknownKeys = unknownKeys
    }

    public static let none = ManagedDevicePolicy()

    /// The keys this build honours.
    public static let knownKeys = [allowPhysicalDevicesKey, allowedDeviceIDsKey, allowedBundleIDsKey, deniedBundleIDsKey, allowTestDevicesKey]

    /// `PayloadUUID` and its kin, which some MDM tools leave beside the settings; never an Offsider key.
    static func isProfileMetadata(_ key: String) -> Bool { key.hasPrefix("Payload") }

    /// A forced key held a value of the wrong type.
    public var unreadable: Bool { !unreadableKeys.isEmpty }

    /// True when any key is forced.
    public var present: Bool {
        allowPhysicalDevices != nil || allowedDeviceIDs != nil || allowedBundleIDs != nil || deniedBundleIDs != nil || allowTestDevices != nil
            || unreadable || !unknownKeys.isEmpty
    }

    /// Why a test device is only a plain Any app allowance on this Mac; nil when it may be driven whole.
    public var testDeviceRefusal: String? {
        guard present else { return nil }
        if allowedBundleIDs != nil { return ManagedRefusalText.appsLimited(Self.allowedBundleIDsKey) }
        if deniedBundleIDs != nil { return ManagedRefusalText.appsLimited(Self.deniedBundleIDsKey) }
        return allowTestDevices == true ? nil : ManagedRefusalText.testDevicesOff
    }

    public static func read(from source: any ManagedPreferenceSource) -> ManagedDevicePolicy {
        var unreadable: [String] = []
        func bool(_ key: String) -> Bool? {
            switch source.forcedValue(forKey: key) {
            case .bool(let value): return value
            case nil: return nil
            default:
                unreadable.append(key)
                return nil
            }
        }
        func strings(_ key: String) -> [String]? {
            switch source.forcedValue(forKey: key) {
            case .strings(let values): return values
            case nil: return nil
            default:
                unreadable.append(key)
                return nil
            }
        }
        let allow = bool(allowPhysicalDevicesKey)
        let devices = strings(allowedDeviceIDsKey)
        let bundles = strings(allowedBundleIDsKey)
        let denied = strings(deniedBundleIDsKey)
        let testDevices = bool(allowTestDevicesKey)
        let unknown = source.forcedKeys().filter { !knownKeys.contains($0) && !isProfileMetadata($0) }.sorted()
        return ManagedDevicePolicy(
            allowPhysicalDevices: allow, allowedDeviceIDs: devices, allowedBundleIDs: bundles, deniedBundleIDs: denied, allowTestDevices: testDevices,
            unreadableKeys: unreadable, unknownKeys: unknown
        )
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
