import Foundation

/// A person's consent to drive one physical device, until `expires` (nil: until removed), limited to `apps` when any are pinned.
public struct DeviceAllowance: Equatable, Sendable {
    public static let maximumNameLength = 120
    public static let maximumApps = 32
    public static let maximumMetroPorts = 8

    public let platform: DevicePlatform
    /// The stable key: an uppercased UDID or a phone serial.
    public let key: String
    public let name: String
    public let added: Date
    public let expires: Date?
    public let apps: [String]
    /// The Apple development team that signs the runner for this iPhone or iPad; nil leaves it to `OFFSIDER_IOS_TEAM_ID`.
    public let team: String?
    /// The ports `rn open` may map with `adb reverse tcp:<port> tcp:<port>` on this Android phone, ascending; empty for none.
    public let metroPorts: [Int]

    public init(platform: DevicePlatform, key: String, name: String, added: Date, expires: Date?, apps: [String], team: String? = nil, metroPorts: [Int] = []) {
        self.platform = platform
        self.key = key
        self.name = name
        self.added = added
        self.expires = expires
        self.apps = apps
        self.team = team
        self.metroPorts = metroPorts
    }

    public func isActive(now: Date) -> Bool {
        expires.map { $0 > now } ?? true
    }

    /// The pin a person chooses for "Any app and all logs" on an Android phone: whole-device logs, and any app named on each command.
    public static let wholeDevicePin = "*"

    /// The apps pinned by id, without the whole-device pin.
    public var pinnedApps: [String] {
        apps.filter { $0 != Self.wholeDevicePin }
    }

    /// True when a person chose whole-device logs for this Android phone.
    public var allowsWholeDevice: Bool {
        platform == .android && apps.contains(Self.wholeDevicePin)
    }

    /// The stable key for a physical device's ID: an uppercased UDID for an iPhone or iPad, the serial for a USB phone; nil for anything else.
    public static func physicalKey(platform: DevicePlatform, id raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (platform, DeviceIDClassifier.classify(id)) {
        case (.ios, .iosDevice(let udid)): return udid.uppercased()
        case (.android, .androidName(let serial)): return serial
        default: return nil
        }
    }

    /// Ten ASCII letters or digits, as an Apple team ID is.
    public static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Letters, digits, `.`, `_` and `-`, at least one dot, as bundle ids and package names are.
    public static func isAppID(_ text: String) -> Bool {
        (1...255).contains(text.count) && text.contains(".") && !text.hasPrefix(".") && !text.hasSuffix(".")
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}

/// Why an allow-list file was refused; nothing in it is honoured.
public struct DeviceAllowListError: Error, Equatable, Sendable, CustomStringConvertible {
    public let detail: String

    public init(_ detail: String) {
        self.detail = detail
    }

    public var description: String { detail }
}

/// `~/.config/offsider/allowed-devices.json`: version 1, one entry per physical device. Parsing is strict, so a hand edit that drifts is refused whole.
public struct DeviceAllowList: Equatable, Sendable {
    public static let version = 1
    public static let maximumEntries = 64
    static let topKeys: Set<String> = ["version", "devices"]
    static let entryKeys: Set<String> = ["platform", "id", "name", "added", "expires", "apps", "team", "metroPorts"]

    public let entries: [DeviceAllowance]

    public init(entries: [DeviceAllowance] = []) {
        self.entries = entries
    }

    public static let empty = DeviceAllowList()

    public func active(now: Date) -> [DeviceAllowance] {
        entries.filter { $0.isActive(now: now) }
    }

    /// The entry for the device, active or expired.
    public func entry(platform: DevicePlatform, key: String) -> DeviceAllowance? {
        entries.first { $0.platform == platform && $0.key == key }
    }

    /// The entry only while it is active.
    public func entry(platform: DevicePlatform, key: String, now: Date) -> DeviceAllowance? {
        entry(platform: platform, key: key).flatMap { $0.isActive(now: now) ? $0 : nil }
    }

    /// Replaces any entry for the same device.
    public func adding(_ allowance: DeviceAllowance) -> DeviceAllowList {
        DeviceAllowList(entries: removing(platform: allowance.platform, key: allowance.key).entries + [allowance])
    }

    public func removing(platform: DevicePlatform, key: String) -> DeviceAllowList {
        DeviceAllowList(entries: entries.filter { !($0.platform == platform && $0.key == key) })
    }

    /// Without the entries that have expired.
    public func pruned(now: Date) -> DeviceAllowList {
        DeviceAllowList(entries: active(now: now))
    }

    public static func parse(_ data: Data) throws -> DeviceAllowList {
        guard let object = try? JSONSerialization.jsonObject(with: data), let top = object as? [String: Any] else {
            throw DeviceAllowListError("the file is not a JSON object")
        }
        if let extra = Set(top.keys).subtracting(topKeys).sorted().first { throw DeviceAllowListError("unknown key \"\(extra)\"") }
        guard let version = top["version"] as? NSNumber, !isBool(version), version.intValue == Self.version, version.doubleValue == Double(Self.version) else {
            throw DeviceAllowListError("version must be \(Self.version)")
        }
        guard let rows = top["devices"] as? [Any] else { throw DeviceAllowListError("devices must be an array") }
        guard rows.count <= maximumEntries else { throw DeviceAllowListError("more than \(maximumEntries) devices") }
        var seen = Set<String>()
        let entries = try rows.enumerated().map { index, row -> DeviceAllowance in
            let entry = try parseEntry(row, index: index)
            guard seen.insert("\(entry.platform.rawValue) \(entry.key)").inserted else {
                throw DeviceAllowListError("devices[\(index)] repeats \(entry.key)")
            }
            return entry
        }
        return DeviceAllowList(entries: entries)
    }

    private static func parseEntry(_ row: Any, index: Int) throws -> DeviceAllowance {
        let at = "devices[\(index)]"
        guard let fields = row as? [String: Any] else { throw DeviceAllowListError("\(at) is not an object") }
        if let extra = Set(fields.keys).subtracting(entryKeys).sorted().first { throw DeviceAllowListError("\(at) has unknown key \"\(extra)\"") }
        guard let platformText = fields["platform"] as? String, let platform = DevicePlatform(rawValue: platformText) else {
            throw DeviceAllowListError("\(at).platform must be ios or android")
        }
        guard let id = fields["id"] as? String, let key = DeviceAllowance.physicalKey(platform: platform, id: id), key == id else {
            throw DeviceAllowListError("\(at).id is not a physical \(platform == .ios ? "iPhone or iPad UDID in uppercase" : "phone serial")")
        }
        guard let name = fields["name"] as? String, (1...DeviceAllowance.maximumNameLength).contains(name.count),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw DeviceAllowListError("\(at).name must be 1 to \(DeviceAllowance.maximumNameLength) printable characters")
        }
        guard let addedText = fields["added"] as? String, let added = ProcessStamp.date(fromTimestamp: addedText) else {
            throw DeviceAllowListError("\(at).added must be an ISO 8601 time")
        }
        let expires: Date?
        switch fields["expires"] {
        case is NSNull: expires = nil
        case let text as String:
            guard let date = ProcessStamp.date(fromTimestamp: text) else { throw DeviceAllowListError("\(at).expires must be an ISO 8601 time or null") }
            expires = date
        default: throw DeviceAllowListError("\(at).expires must be an ISO 8601 time or null")
        }
        guard let apps = fields["apps"] as? [Any], apps.count <= DeviceAllowance.maximumApps else {
            throw DeviceAllowListError("\(at).apps must be an array of at most \(DeviceAllowance.maximumApps) app ids")
        }
        let appIDs = try apps.map { app -> String in
            if let text = app as? String, text == DeviceAllowance.wholeDevicePin, platform == .android { return text }
            guard let text = app as? String, DeviceAllowance.isAppID(text) else { throw DeviceAllowListError("\(at).apps holds something that is not an app id") }
            return text
        }
        guard Set(appIDs).count == appIDs.count else { throw DeviceAllowListError("\(at).apps repeats an app id") }
        let team: String?
        switch fields["team"] {
        case nil, is NSNull: team = nil
        case let text as String where platform == .ios && DeviceAllowance.isTeamID(text): team = text
        default: throw DeviceAllowListError("\(at).team must be a 10-character Apple team ID on an iOS entry")
        }
        let metroPorts: [Int]
        switch fields["metroPorts"] {
        case nil: metroPorts = []
        case let rows as [Any] where platform == .android && (1...DeviceAllowance.maximumMetroPorts).contains(rows.count):
            metroPorts = try rows.map { row -> Int in
                guard let number = row as? NSNumber, !isBool(number), let port = Int(exactly: number.doubleValue), MetroReverse.refusal(port: port) == nil else {
                    throw DeviceAllowListError("\(at).metroPorts holds something that is not a Metro port")
                }
                return port
            }
            guard metroPorts == Array(Set(metroPorts)).sorted() else { throw DeviceAllowListError("\(at).metroPorts must be ascending, each port once") }
        default:
            throw DeviceAllowListError("\(at).metroPorts must be 1 to \(DeviceAllowance.maximumMetroPorts) ports on an Android entry")
        }
        return DeviceAllowance(platform: platform, key: key, name: name, added: added, expires: expires, apps: appIDs, team: team, metroPorts: metroPorts)
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Stable, readable JSON with keys in schema order, ending in a newline.
    public func encoded() -> Data {
        let rows = entries.map { entry -> OrderedJSON in
            var fields: [(String, OrderedJSON)] = [
                ("platform", .string(entry.platform.rawValue)),
                ("id", .string(entry.key)),
                ("name", .string(entry.name)),
                ("added", .string(ProcessStamp.timestamp(entry.added))),
                ("expires", .optional(entry.expires) { .string(ProcessStamp.timestamp($0)) }),
                ("apps", .array(entry.apps.map { .string($0) })),
            ]
            // Written only when set, so a list without teams or ports stays byte-identical to version 1 files.
            if let team = entry.team { fields.append(("team", .string(team))) }
            if !entry.metroPorts.isEmpty { fields.append(("metroPorts", .array(entry.metroPorts.map { .integer($0) }))) }
            return .object(fields)
        }
        let object = OrderedJSON.object([("version", .integer(Self.version)), ("devices", .array(rows))])
        return Data((object.rendered() + "\n").utf8)
    }
}
