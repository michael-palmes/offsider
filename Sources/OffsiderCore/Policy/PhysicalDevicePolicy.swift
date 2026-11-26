import Foundation

/// Why a physical device may not be driven.
public enum DeviceRefusal: Equatable, Sendable {
    /// The managed preference turns physical devices off.
    case managedOff
    /// The managed key could not be read, so every physical device is refused.
    case managedUnreadable(String)
    /// A forced key this build does not know, so it cannot honour it and refuses every physical device.
    case managedUnknownKey(String)
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
    /// The seal could not be read from the login Keychain, so the file cannot be trusted until it can.
    case sealUnreadable(String)
    /// A newer Offsider wrote this device's entry, with a key this build does not know and so cannot honour.
    case newerEntry(String)
    /// The entry is older than the managed `maxAllowanceDays`; a person may allow the device again.
    case cappedExpired(Date, days: Int)
    /// Managed `requirePinnedApps` is forced and the entry names no app, or pins every app; a person may allow it again with one.
    case pinsRequired

    /// True when only an administrator can lift it; `devices add` cannot.
    public var isManaged: Bool {
        switch self {
        case .managedOff, .managedUnreadable, .managedUnknownKey, .managedNotListed: return true
        default: return false
        }
    }

    /// The managed refusal a `code` and `key` describe, as `doctor --json` carries them; nil for any other code.
    public static func managed(code: String, key: String?) -> DeviceRefusal? {
        switch (code, key) {
        case ("managed_off", _): return .managedOff
        case ("managed_not_listed", _): return .managedNotListed
        case ("managed_unreadable", let key?): return .managedUnreadable(key)
        case ("managed_unknown_key", let key?): return .managedUnknownKey(key)
        default: return nil
        }
    }

    /// The managed key behind the refusal; nil for the allow-list's own refusals.
    public var managedKey: String? {
        switch self {
        case .managedOff: return ManagedDevicePolicy.allowPhysicalDevicesKey
        case .managedNotListed: return ManagedDevicePolicy.allowedDeviceIDsKey
        case .managedUnreadable(let key), .managedUnknownKey(let key): return key
        case .cappedExpired: return ManagedCeilings.maxAllowanceDaysKey
        case .pinsRequired: return ManagedCeilings.Switch.requirePinnedApps.key
        default: return nil
        }
    }

    /// One sentence for an error message.
    public var explanation: String {
        switch self {
        case .managedOff: return ManagedRefusalText.physicalOff
        case .managedUnreadable(let key): return ManagedRefusalText.unreadable(key)
        case .managedUnknownKey(let key): return ManagedRefusalText.unknown(key)
        case .managedNotListed: return ManagedRefusalText.deviceNotListed
        case .notAllowed: return "it is not on the allow-list"
        case .expired(let date): return "its allow-list entry expired at \(ProcessStamp.timestamp(date))"
        case .listUnreadable(let detail): return "the allow-list could not be read (\(detail))"
        case .listChanged: return "the allow-list was changed outside Offsider"
        case .sealUnreadable(let detail): return "the allow-list's seal could not be read from the login Keychain (\(detail)), so the list is not trusted until it can be"
        case .newerEntry(let key): return "a newer Offsider wrote its allow-list entry, with a setting this one cannot read (\(TerminalText.quoted(key)))"
        case .cappedExpired(let date, let days): return "\(ManagedRefusalText.allowanceCapped(days: days)), which its allow-list entry passed at \(ProcessStamp.timestamp(date))"
        case .pinsRequired: return "\(ManagedCeilings.Switch.requirePinnedApps.refusal), and its allow-list entry names none"
        }
    }

    /// Stable JSON value.
    public var code: String {
        switch self {
        case .managedOff: return "managed_off"
        case .managedUnreadable: return "managed_unreadable"
        case .managedUnknownKey: return "managed_unknown_key"
        case .managedNotListed: return "managed_not_listed"
        case .notAllowed: return "not_allowed"
        case .expired: return "expired"
        case .listUnreadable: return "list_unreadable"
        case .listChanged: return "list_changed"
        case .sealUnreadable: return "seal_unreadable"
        case .newerEntry: return "newer_entry"
        case .cappedExpired: return "expired_by_policy"
        case .pinsRequired: return "pins_required"
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
    /// False when the file does not match its Keychain seal, or the seal could not be read.
    public let sealIntact: Bool
    /// Why the seal could not be read, such as `the login Keychain is locked`; nil when it was read.
    public let sealUnreadable: String?

    public init(managed: ManagedDevicePolicy, list: DeviceAllowList, listProblem: String? = nil, sealIntact: Bool = true, sealUnreadable: String? = nil) {
        self.managed = managed
        self.list = listProblem == nil ? list : .empty
        self.listProblem = listProblem
        self.sealIntact = sealIntact && sealUnreadable == nil
        self.sealUnreadable = sealUnreadable
    }

    public func decision(platform: DevicePlatform, key: String, now: Date = Date()) -> DeviceDecision {
        if let key = managed.unreadableKeys.first { return .refused(.managedUnreadable(key)) }
        if let key = managed.unknownKeys.first { return .refused(.managedUnknownKey(key)) }
        if managed.allowPhysicalDevices == false { return .refused(.managedOff) }
        if !managed.lists(platform: platform, key: key) { return .refused(.managedNotListed) }
        if let listProblem { return .refused(.listUnreadable(listProblem)) }
        if let sealUnreadable { return .refused(.sealUnreadable(sealUnreadable)) }
        if !sealIntact { return .refused(.listChanged) }
        if let held = list.newerEntry(platform: platform, key: key) { return .refused(.newerEntry(held.unknownKeys[0])) }
        guard let listed = list.entry(platform: platform, key: key) else { return .refused(.notAllowed) }
        guard listed.isActive(now: now) else { return .refused(.expired(listed.expires ?? now)) }
        let entry = capped(listed)
        if let days = managed.ceilings.maxAllowanceDays, let end = entry.expires, end <= now { return .refused(.cappedExpired(end, days: days)) }
        if managed.ceilings.refusal(.requirePinnedApps) != nil, entry.pinnedApps.isEmpty || entry.apps.contains(DeviceAllowance.wholeDevicePin) {
            return .refused(.pinsRequired)
        }
        return .allowed(entry)
    }

    /// The entry as it holds under managed `maxAllowanceDays`: it ends that many days after it was added, or sooner.
    public func capped(_ entry: DeviceAllowance) -> DeviceAllowance {
        guard let cap = managed.ceilings.allowanceCap else { return entry }
        let limit = entry.added.addingTimeInterval(cap)
        return entry.expires.map { $0 <= limit } ?? false ? entry : entry.expiring(limit)
    }

    /// Why a managed ceiling refuses the allowance a person is about to save, as a clause naming the key; nil when none does.
    /// `lifetime` is nil when nothing was chosen yet, and holds nil for "until removed".
    public func addRefusal(apps: [String]? = nil, lifetime: TimeInterval?? = nil, team: String? = nil, metroPorts: [Int] = []) -> String? {
        let ceilings = managed.ceilings
        if let team, let why = ceilings.teamRefusal(team) { return why }
        if !metroPorts.isEmpty, let why = ceilings.refusal(.allowMetroReverse) { return why }
        if let apps, let why = ceilings.refusal(.requirePinnedApps), apps.isEmpty || apps.contains(DeviceAllowance.wholeDevicePin) { return why }
        if let lifetime, let days = ceilings.maxAllowanceDays, let cap = ceilings.allowanceCap, lifetime ?? .infinity > cap {
            return ManagedRefusalText.allowanceCapped(days: days)
        }
        return nil
    }

    /// Whether the device may be driven now.
    public func isActive(_ entry: DeviceAllowance, now: Date) -> Bool {
        if case .allowed = decision(platform: entry.platform, key: entry.key, now: now) { return true }
        return false
    }

    /// Whether agents may drive all of this device: a person chose a test device, and managed policy leaves it so.
    public func drivesWhole(_ allowance: DeviceAllowance) -> Bool {
        allowance.testDevice && managed.testDeviceRefusal == nil
    }

    /// Why managed policy keeps a test device a person chose from being driven whole, naming the key; nil for any other allowance.
    public func testDeviceOff(_ allowance: DeviceAllowance) -> String? {
        allowance.testDevice ? managed.testDeviceRefusal : nil
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
        guard (try? ExpoDevClient.validate(appID: app)) != nil else { return false }
        if drivesWhole(allowance) { return true }
        guard !SystemAppDenyList.isDenied(app, platform: allowance.platform) else { return false }
        return permittedApps(for: allowance)?.contains(app) ?? true
    }

    /// Why `app` may not be driven or read on the device, in one sentence ending "Nothing was read or sent."; nil when it may.
    public func appRefusal(_ app: String, on allowance: DeviceAllowance, audience: ErrorAudience = .current) -> String? {
        do {
            _ = try ExpoDevClient.validate(appID: app)
        } catch {
            return "\(error.localizedDescription) Nothing was read or sent."
        }
        if drivesWhole(allowance) { return nil }
        if let why = SystemAppDenyList.refusal(app, platform: allowance.platform) {
            return "\(why). Nothing was read or sent."
        }
        guard permits(app: app, on: allowance) else {
            if managed.allowedBundleIDs.map({ !$0.contains(app) }) ?? false {
                return "\(ManagedRefusalText.sentence(ManagedRefusalText.appNotListed(app))) Nothing was read or sent."
            }
            return "\(app) is not among the apps allowed on \(allowance.name) (\(allowance.key)). Nothing was read or sent."
                + audience.personStep(DeviceAddPlan.pinCommand(key: allowance.key, keeping: allowance.pinnedApps, adding: app))
        }
        return nil
    }

    /// `devices status --json`, version 1; `audit` adds the records `--audit` asked for.
    public func statusJSON(now: Date, only: (platform: DevicePlatform, key: String)? = nil, audit: [AuditRecord]? = nil) -> String {
        let entries = list.entries.filter { entry in only.map { $0.platform == entry.platform && $0.key == entry.key } ?? true }
        let devices = entries.map { entry -> OrderedJSON in
            var fields: [(String, OrderedJSON)] = [
                ("platform", .string(entry.platform.rawValue)),
                ("id", .string(entry.key)),
                ("name", .string(entry.name)),
                ("added", .string(ProcessStamp.timestamp(entry.added))),
                ("expires", .optional(capped(entry).expires) { .string(ProcessStamp.timestamp($0)) }),
                ("apps", .array(entry.apps.map { .string($0) })),
            ]
            if let team = entry.team { fields.append(("team", .string(team))) }
            if let prefix = entry.runnerPrefix { fields.append(("runnerPrefix", .string(prefix))) }
            if !entry.metroPorts.isEmpty { fields.append(("metroPorts", .array(entry.metroPorts.map { .integer($0) }))) }
            if entry.testDevice {
                fields.append(("testDevice", .bool(true)))
                if let off = managed.testDeviceRefusal { fields.append(("testDeviceOff", .string(off))) }
            }
            fields.append(("active", .bool(isActive(entry, now: now))))
            return .object(fields)
        }
        let held = list.newer.filter { entry in only.map { $0.platform == entry.platform && $0.key == entry.key } ?? true }.map { entry -> OrderedJSON in
            var refusal: DeviceRefusal?
            if case .refused(let why) = decision(platform: entry.platform, key: entry.key, now: now) { refusal = why }
            return .object([
                ("platform", .string(entry.platform.rawValue)),
                ("id", .string(entry.key)),
                ("name", .string(entry.name)),
                ("active", .bool(false)),
                ("refusal", .optional(refusal) { .string($0.code) }),
                ("key", .optional(refusal?.managedKey) { .string($0) }),
                ("unknownKeys", .array(entry.unknownKeys.map { .string($0) })),
            ])
        }
        var fields: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("managed", .object([
                ("present", .bool(managed.present)),
                ("allowPhysicalDevices", .optional(managed.allowPhysicalDevices) { .bool($0) }),
                ("allowedDeviceIDs", .optional(managed.allowedDeviceIDs) { .array($0.map { .string($0) }) }),
                ("allowedBundleIDs", .optional(managed.allowedBundleIDs) { .array($0.map { .string($0) }) }),
                ("deniedBundleIDs", .optional(managed.deniedBundleIDs) { .array($0.map { .string($0) }) }),
                ("allowTestDevices", .optional(managed.allowTestDevices) { .bool($0) }),
            ] + managed.ceilings.json + [
                ("unreadable", .bool(managed.unreadable)),
                ("unreadableKeys", .array(managed.unreadableKeys.map { .string($0) })),
                ("unknownKeys", .array(managed.unknownKeys.map { .string($0) })),
            ])),
            ("list", .object([
                ("readable", .bool(listProblem == nil)),
                ("sealed", .bool(sealIntact)),
            ])),
            ("devices", .array(devices + held)),
        ]
        if let only {
            let refusal: DeviceRefusal?
            if case .refused(let why) = decision(platform: only.platform, key: only.key, now: now) { refusal = why } else { refusal = nil }
            fields.append(("allowed", .bool(refusal == nil)))
            fields.append(("refusal", .optional(refusal) { .string($0.code) }))
            fields.append(("key", .optional(refusal?.managedKey) { .string($0) }))
        }
        if let audit { fields.append(("audit", AuditScreen.json(audit))) }
        return OrderedJSON.object(fields).rendered() + "\n"
    }
}
