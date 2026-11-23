import Foundation

/// The managed keys that cap what a person or an agent may loosen. Absent keys set no limit; a forced key of the wrong type reads as its strictest value.
public struct ManagedCeilings: Equatable, Sendable {
    /// A boolean key that turns one thing off for everyone on this Mac.
    public enum Switch: String, CaseIterable, Sendable {
        case forceMasks
        case allowSavedLogins
        case allowFileInput
        case allowMetroReverse
        case allowRunnerRegistration
        case requirePinnedApps
        case allowUnlockCodes
        case allowPhonePermissionChanges

        public var key: String { rawValue }

        /// The forced value that restricts: `true` for the keys that force or require, `false` for the keys that allow.
        public var restrictsWhen: Bool { self == .forceMasks || self == .requirePinnedApps }

        /// What the organisation did, naming the key.
        public var refusal: String {
            switch self {
            case .forceMasks: return "your organisation keeps masks and redaction on (\(key))"
            case .allowSavedLogins: return "your organisation turns off saved logins on this Mac (\(key))"
            case .allowFileInput: return "your organisation turns off --allow-path (\(key))"
            case .allowMetroReverse: return "your organisation turns off adb reverse to Metro on phones (\(key))"
            case .allowRunnerRegistration: return "your organisation does not let Offsider register devices or create signing profiles (\(key))"
            case .requirePinnedApps: return "your organisation limits each phone to named apps (\(key))"
            case .allowUnlockCodes: return "your organisation turns off saved unlock codes (\(key))"
            case .allowPhonePermissionChanges: return "your organisation turns off permission changes on phones (\(key))"
            }
        }

        /// A few words for `devices status`, for the forced value.
        func shown(_ value: Bool) -> String {
            switch self {
            case .forceMasks: return value ? "masks forced on" : "masks not forced"
            case .allowSavedLogins: return value ? "saved logins on" : "saved logins off"
            case .allowFileInput: return value ? "--allow-path on" : "--allow-path off"
            case .allowMetroReverse: return value ? "Metro reverses on" : "Metro reverses off"
            case .allowRunnerRegistration: return value ? "runner registration on" : "runner registration off"
            case .requirePinnedApps: return value ? "named apps required" : "named apps not required"
            case .allowUnlockCodes: return value ? "unlock codes on" : "unlock codes off"
            case .allowPhonePermissionChanges: return value ? "phone permission changes on" : "phone permission changes off"
            }
        }
    }

    public static let maxAllowanceDaysKey = "maxAllowanceDays"
    public static let allowedTeamIDsKey = "allowedTeamIDs"
    /// The longest cap a profile may set; a larger number is a mistake, and reads as unreadable.
    public static let longestAllowanceDays = 3_650

    /// Every ceiling key, in the order the docs list them.
    public static let keys: [String] = [
        Switch.forceMasks.key, maxAllowanceDaysKey, Switch.allowSavedLogins.key, Switch.allowFileInput.key, Switch.allowMetroReverse.key,
        Switch.allowRunnerRegistration.key, allowedTeamIDsKey, Switch.requirePinnedApps.key, Switch.allowUnlockCodes.key, Switch.allowPhonePermissionChanges.key,
    ]

    public let switches: [Switch: Bool]
    public let maxAllowanceDays: Int?
    public let allowedTeamIDs: [String]?
    /// Forced keys holding a value of the wrong type, in `keys` order.
    public let unreadableKeys: [String]

    public init(switches: [Switch: Bool] = [:], maxAllowanceDays: Int? = nil, allowedTeamIDs: [String]? = nil, unreadableKeys: [String] = []) {
        self.switches = switches
        self.maxAllowanceDays = maxAllowanceDays
        self.allowedTeamIDs = allowedTeamIDs
        self.unreadableKeys = unreadableKeys
    }

    public static let none = ManagedCeilings()

    /// True when any ceiling key is forced, readable or not.
    public var present: Bool {
        !switches.isEmpty || maxAllowanceDays != nil || allowedTeamIDs != nil || !unreadableKeys.isEmpty
    }

    /// Reads `keys` only, so a gate asks cfprefsd for the one key it enforces.
    public static func read(_ keys: [String] = ManagedCeilings.keys, from source: any ManagedPreferenceSource) -> ManagedCeilings {
        var switches: [Switch: Bool] = [:]
        var days: Int?
        var teams: [String]?
        var unreadable: [String] = []
        for key in Self.keys where keys.contains(key) {
            guard let value = source.forcedValue(forKey: key) else { continue }
            if let item = Switch(rawValue: key), case .bool(let flag) = value {
                switches[item] = flag
            } else if key == maxAllowanceDaysKey, case .integer(let count) = value, (1...longestAllowanceDays).contains(count) {
                days = count
            } else if key == allowedTeamIDsKey, case .strings(let ids) = value {
                teams = ids
            } else {
                unreadable.append(key)
            }
        }
        return ManagedCeilings(switches: switches, maxAllowanceDays: days, allowedTeamIDs: teams, unreadableKeys: unreadable)
    }

    /// Why the organisation refuses what `item` governs, as a clause naming the key; nil when it sets no limit.
    public func refusal(_ item: Switch) -> String? {
        if unreadableKeys.contains(item.key) { return ManagedRefusalText.strictest(item.key) }
        return switches[item] == item.restrictsWhen ? item.refusal : nil
    }

    /// The longest an allowance may last; nil for no cap. An unreadable cap refuses every phone before this is asked.
    public var allowanceCap: TimeInterval? {
        maxAllowanceDays.map { TimeInterval($0) * 86_400 }
    }

    /// Why `team` may not sign the runner; team IDs compare without case.
    public func teamRefusal(_ team: String) -> String? {
        if unreadableKeys.contains(Self.allowedTeamIDsKey) { return ManagedRefusalText.strictest(Self.allowedTeamIDsKey) }
        guard let allowedTeamIDs else { return nil }
        let listed = allowedTeamIDs.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(team) == .orderedSame }
        return listed ? nil : ManagedRefusalText.teamNotListed(team)
    }

    /// Whether `team` may sign the runner.
    public func permits(team: String) -> Bool { teamRefusal(team) == nil }

    /// Each forced ceiling in a few words, in `keys` order, for `devices status`.
    public var shown: [String] {
        Self.keys.compactMap { key in
            if let item = Switch(rawValue: key) { return switches[item].map(item.shown) }
            if key == Self.maxAllowanceDaysKey { return maxAllowanceDays.map { "allowances last at most \(Self.days($0))" } }
            return allowedTeamIDs.map { "teams limited to \($0.isEmpty ? "none" : $0.joined(separator: ", "))" }
        }
    }

    /// Each forced ceiling as `key=value`, in `keys` order, for `doctor`.
    public var inForce: [String] {
        Self.keys.compactMap { key in
            if unreadableKeys.contains(key) { return "\(key)=unreadable" }
            if let item = Switch(rawValue: key) { return switches[item].map { "\(key)=\($0)" } }
            if key == Self.maxAllowanceDaysKey { return maxAllowanceDays.map { "\(key)=\($0)" } }
            return allowedTeamIDs.map { "\(key)=[\($0.joined(separator: ", "))]" }
        }
    }

    /// The `managed` members of `devices status --json`, one per ceiling key, null when not forced.
    var json: [(String, OrderedJSON)] {
        Self.keys.map { key in
            if let item = Switch(rawValue: key) { return (key, .optional(switches[item]) { .bool($0) }) }
            if key == Self.maxAllowanceDaysKey { return (key, .optional(maxAllowanceDays) { .integer($0) }) }
            return (key, .optional(allowedTeamIDs) { .array($0.map { .string($0) }) })
        }
    }

    static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
}

/// One ceiling read where it is enforced: the loosening flag, the phone path or that command. Nothing else asks cfprefsd.
public enum ManagedGate {
    /// Tests bind forced and unforced values; there is no environment switch.
    @TaskLocal public static var sourceOverride: (any ManagedPreferenceSource)?
    static let live = LiveManagedPreferences()

    public static var source: any ManagedPreferenceSource { sourceOverride ?? live }

    /// Why the organisation refuses what `item` governs; nil on an unmanaged Mac.
    public static func refusal(_ item: ManagedCeilings.Switch) -> String? {
        ManagedCeilings.read([item.key], from: source).refusal(item)
    }

    /// Why `team` may not sign the runner; nil when `allowedTeamIDs` is not forced or lists it.
    public static func teamRefusal(_ team: String) -> String? {
        ManagedCeilings.read([ManagedCeilings.allowedTeamIDsKey], from: source).teamRefusal(team)
    }
}
