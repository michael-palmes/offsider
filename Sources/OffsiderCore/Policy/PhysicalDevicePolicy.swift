import Foundation

/// Why a physical device may not be driven.
public enum DeviceRefusal: Equatable, Sendable {
    /// The managed preference turns physical devices off.
    case managedOff
    /// A managed preference could not be read, so every physical device is refused.
    case managedUnreadable
    /// The managed device list does not name this device.
    case managedNotListed
    /// No one allowed this device.
    case notAllowed
    /// The device's entry has expired.
    case expired(Date)
    /// The allow-list file is unsafe or does not parse; it counts as empty.
    case listUnreadable(String)
    /// The file no longer matches the seal `devices add` stored in the login Keychain.
    case listChanged

    /// True when only an administrator can lift it; `devices add` cannot.
    public var isManaged: Bool {
        switch self {
        case .managedOff, .managedUnreadable, .managedNotListed: return true
        default: return false
        }
    }

    /// One sentence for an error message.
    public var explanation: String {
        switch self {
        case .managedOff: return "managed policy on this Mac turns physical devices off, and the allow-list cannot override it"
        case .managedUnreadable: return "managed policy on this Mac could not be read, so every physical device is refused, and the allow-list cannot override it"
        case .managedNotListed: return "managed policy on this Mac does not list it, and the allow-list cannot override it"
        case .notAllowed: return "it is not on the allow-list"
        case .expired(let date): return "its allow-list entry expired at \(ProcessStamp.timestamp(date))"
        case .listUnreadable(let detail): return "the allow-list could not be read (\(detail))"
        case .listChanged: return "the allow-list was changed outside Offsider"
        }
    }

    /// Stable JSON value.
    public var code: String {
        switch self {
        case .managedOff: return "managed_off"
        case .managedUnreadable: return "managed_unreadable"
        case .managedNotListed: return "managed_not_listed"
        case .notAllowed: return "not_allowed"
        case .expired: return "expired"
        case .listUnreadable: return "list_unreadable"
        case .listChanged: return "list_changed"
        }
    }
}

public enum DeviceDecision: Equatable, Sendable {
    case allowed(DeviceAllowance)
    case refused(DeviceRefusal)
}

/// The managed ceiling and the person's consent together: both must say yes before a physical device is driven.
public struct PhysicalDevicePolicy: Equatable, Sendable {
    public let managed: ManagedDevicePolicy
    public let list: DeviceAllowList
    /// Set when the file could not be read or parsed; the list is then empty.
    public let listProblem: String?
    /// False when the file does not match its Keychain seal.
    public let sealIntact: Bool

    public init(managed: ManagedDevicePolicy, list: DeviceAllowList, listProblem: String? = nil, sealIntact: Bool = true) {
        self.managed = managed
        self.list = listProblem == nil ? list : .empty
        self.listProblem = listProblem
        self.sealIntact = sealIntact
    }

    public func decision(platform: DevicePlatform, key: String, now: Date = Date()) -> DeviceDecision {
        if managed.unreadable { return .refused(.managedUnreadable) }
        if managed.allowPhysicalDevices == false { return .refused(.managedOff) }
        if !managed.lists(platform: platform, key: key) { return .refused(.managedNotListed) }
        if let listProblem { return .refused(.listUnreadable(listProblem)) }
        if !sealIntact { return .refused(.listChanged) }
        guard let entry = list.entry(platform: platform, key: key) else { return .refused(.notAllowed) }
        guard entry.isActive(now: now) else { return .refused(.expired(entry.expires ?? now)) }
        return .allowed(entry)
    }

    /// The apps the entry pins, within the managed bundle list; nil when neither limits them.
    public func permittedApps(for allowance: DeviceAllowance) -> Set<String>? {
        let pinned = allowance.pinnedApps.isEmpty ? nil : Set(allowance.pinnedApps)
        let ceiling = managed.allowedBundleIDs.map(Set.init)
        switch (pinned, ceiling) {
        case (nil, nil): return nil
        case (let pinned?, nil): return pinned
        case (nil, let ceiling?): return ceiling
        case (let pinned?, let ceiling?): return pinned.intersection(ceiling)
        }
    }

    /// Whether `app` may be driven on the device: never a deny-listed app, and only within `permittedApps`.
    public func permits(app: String, on allowance: DeviceAllowance) -> Bool {
        guard !SystemAppDenyList.isDenied(app, platform: allowance.platform) else { return false }
        return permittedApps(for: allowance)?.contains(app) ?? true
    }

    /// Why `app` may not be driven or read on the device, in one sentence ending "Nothing was read or sent."; nil when it may.
    public func appRefusal(_ app: String, on allowance: DeviceAllowance, audience: ErrorAudience = .current) -> String? {
        if let why = SystemAppDenyList.refusal(app, platform: allowance.platform) {
            return "\(why). Nothing was read or sent."
        }
        guard permits(app: app, on: allowance) else {
            if managed.allowedBundleIDs.map({ !$0.contains(app) }) ?? false {
                return "Managed policy on this Mac does not list \(app), and the allow-list cannot override it. Nothing was read or sent."
            }
            return "\(app) is not among the apps allowed on \(allowance.name) (\(allowance.key)). Nothing was read or sent."
                + audience.personStep("offsider devices add", agentTail: ", choose \(allowance.name) (\(allowance.key)) and pin \(app)")
        }
        return nil
    }

    /// `devices status --json`, version 1.
    public func statusJSON(now: Date, only: (platform: DevicePlatform, key: String)? = nil) -> String {
        let entries = list.entries.filter { entry in only.map { $0.platform == entry.platform && $0.key == entry.key } ?? true }
        let devices = entries.map { entry -> OrderedJSON in
            var fields: [(String, OrderedJSON)] = [
                ("platform", .string(entry.platform.rawValue)),
                ("id", .string(entry.key)),
                ("name", .string(entry.name)),
                ("added", .string(ProcessStamp.timestamp(entry.added))),
                ("expires", .optional(entry.expires) { .string(ProcessStamp.timestamp($0)) }),
                ("apps", .array(entry.apps.map { .string($0) })),
            ]
            if let team = entry.team { fields.append(("team", .string(team))) }
            fields.append(("active", .bool(decision(platform: entry.platform, key: entry.key, now: now) == .allowed(entry))))
            return .object(fields)
        }
        var fields: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("managed", .object([
                ("present", .bool(managed.present)),
                ("allowPhysicalDevices", .optional(managed.allowPhysicalDevices) { .bool($0) }),
                ("allowedDeviceIDs", .optional(managed.allowedDeviceIDs) { .array($0.map { .string($0) }) }),
                ("allowedBundleIDs", .optional(managed.allowedBundleIDs) { .array($0.map { .string($0) }) }),
                ("unreadable", .bool(managed.unreadable)),
            ])),
            ("list", .object([
                ("readable", .bool(listProblem == nil)),
                ("sealed", .bool(sealIntact)),
            ])),
            ("devices", .array(devices)),
        ]
        if let only {
            let refusal: DeviceRefusal?
            if case .refused(let why) = decision(platform: only.platform, key: only.key, now: now) { refusal = why } else { refusal = nil }
            fields.append(("allowed", .bool(refusal == nil)))
            fields.append(("refusal", .optional(refusal) { .string($0.code) }))
        }
        return OrderedJSON.object(fields).rendered() + "\n"
    }
}
