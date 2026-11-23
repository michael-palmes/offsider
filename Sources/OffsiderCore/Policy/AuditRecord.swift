import CryptoKit
import Darwin
import Foundation

/// What a caller knows about one physical-device event; `AuditTrail` adds the time, the build, the process and the chain.
public struct AuditEvent: Equatable, Sendable {
    public var outcome: AuditRecord.Outcome
    public var platform: DevicePlatform
    /// The device's allow-list key. Only its hash is ever written.
    public var key: String
    public var app: String?
    public var exit: Int32?
    public var reason: String?
    public var refusal: String?
    public var testDevice: Bool
    public var managed: Bool
    public var expires: Date?
    public var pins: Int?

    public init(
        _ outcome: AuditRecord.Outcome, platform: DevicePlatform, key: String, app: String? = nil, exit: Int32? = nil, reason: String? = nil, refusal: String? = nil,
        testDevice: Bool = false, managed: Bool = false, expires: Date? = nil, pins: Int? = nil
    ) {
        self.outcome = outcome
        self.platform = platform
        self.key = key
        self.app = app
        self.exit = exit
        self.reason = reason
        self.refusal = refusal
        self.testDevice = testDevice
        self.managed = managed
        self.expires = expires
        self.pins = pins
    }
}

/// One line of the device audit trail: which command ran on which physical device and how it ended.
/// It has no field for a label, a value, typed text, tree text, a device name or an argument, and every string it holds is cut to a fixed shape.
public struct AuditRecord: Equatable, Sendable {
    public enum Outcome: String, CaseIterable, Sendable {
        case ran
        case refused
        case allowed
        case withdrawn
        case sessionStarted = "session_started"
        case sessionStopped = "session_stopped"
        case registration
        case unlockCodeSaved = "unlock_code_saved"
    }

    /// The agent or terminal session the command ran in: its pid and the kernel's short process name.
    public struct Session: Equatable, Sendable {
        public let pid: Int32
        public let name: String

        public init(pid: Int32, name: String) {
            self.pid = pid
            self.name = Shape.processName(name)
        }
    }

    public let time: Date
    public let version: String
    public let pid: Int32
    public let session: Session?
    /// The subcommand path, such as `tap` or `app launch`; never an argument.
    public let command: String
    public let platform: DevicePlatform
    /// First 16 hex digits of SHA-256 of `platform:key`.
    public let device: String
    public let app: String?
    public let outcome: Outcome
    public let exit: Int32?
    public let reason: String?
    public let refusal: String?
    public let testDevice: Bool
    public let managed: Bool
    public let milliseconds: Int?
    public let expires: Date?
    public let pins: Int?

    public init(_ event: AuditEvent, time: Date, version: String, pid: Int32, session: Session?, command: String?, milliseconds: Int?) {
        self.init(
            time: time, version: version, pid: pid, session: session, command: command ?? "", platform: event.platform,
            device: Self.deviceKey(platform: event.platform, key: event.key), app: event.app, outcome: event.outcome, exit: event.exit, reason: event.reason,
            refusal: event.refusal, testDevice: event.testDevice, managed: event.managed, milliseconds: milliseconds, expires: event.expires, pins: event.pins
        )
    }

    init(
        time: Date, version: String, pid: Int32, session: Session?, command: String, platform: DevicePlatform, device: String, app: String?, outcome: Outcome,
        exit: Int32?, reason: String?, refusal: String?, testDevice: Bool, managed: Bool, milliseconds: Int?, expires: Date?, pins: Int?
    ) {
        self.time = Date(timeIntervalSince1970: time.timeIntervalSince1970.rounded(.down))
        self.version = Shape.version(version)
        self.pid = pid
        self.session = session
        self.command = Shape.command(command)
        self.platform = platform
        self.device = Shape.isDeviceKey(device) ? device : Self.unknownDevice
        self.app = app.flatMap(Shape.app)
        self.outcome = outcome
        self.exit = exit
        self.reason = reason.flatMap(Shape.reason)
        self.refusal = refusal.flatMap(Shape.refusal)
        self.testDevice = testDevice
        self.managed = managed
        self.milliseconds = milliseconds.map { min(max($0, 0), Shape.maximumMilliseconds) }
        self.expires = expires.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.pins = pins.map { min(max($0, 0), Shape.maximumPins) }
    }

    public static let unknownDevice = String(repeating: "0", count: 16)

    /// As the tree cache names its files, so an administrator can match a record to inventory and nobody reads a serial from it.
    public static func deviceKey(platform: DevicePlatform, key: String) -> String {
        hex(SHA256.hash(data: Data("\(platform.rawValue):\(key)".utf8)).prefix(8))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lower-case hex without a formatter, which costs a fresh process far more than the hash itself.
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var text: [UInt8] = []
        for byte in bytes {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// `2026-10-05T03:12:44Z`, as `ProcessStamp.timestamp` writes it, from `gmtime_r` so a record never pays for a date formatter's first use.
    static func stamp(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = unsafe tm()
        unsafe gmtime_r(&seconds, &parts)
        func two(_ value: Int32) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let year = unsafe Int(parts.tm_year) + 1900
        guard (1000...9999).contains(year) else { return ProcessStamp.timestamp(date) }
        return unsafe "\(year)-\(two(parts.tm_mon + 1))-\(two(parts.tm_mday))T\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec))Z"
    }

    /// The keys a line may hold, in the order they are written.
    public static let keys = [
        "prev", "time", "version", "pid", "session", "command", "platform", "device", "app", "outcome", "exit", "reason", "refusal", "testDevice", "managed", "ms", "expires",
        "pins",
    ]

    /// One JSON object with no newline, `prev` first so the chain reads without parsing the rest.
    public func line(prev: String) -> String {
        // Written by hand: every value is already cut to a shape that needs no escaping, and the general renderer costs a fresh process far more.
        var text = "{\"prev\":\"\(prev)\",\"time\":\"\(Self.stamp(time))\",\"version\":\"\(version)\",\"pid\":\(pid)"
        if let session { text += ",\"session\":{\"pid\":\(session.pid),\"name\":\"\(session.name)\"}" }
        text += ",\"command\":\"\(command)\",\"platform\":\"\(platform.rawValue)\",\"device\":\"\(device)\""
        if let app { text += ",\"app\":\"\(app)\"" }
        text += ",\"outcome\":\"\(outcome.rawValue)\""
        if let exit { text += ",\"exit\":\(exit)" }
        if let reason { text += ",\"reason\":\"\(reason)\"" }
        if let refusal { text += ",\"refusal\":\"\(refusal)\"" }
        text += ",\"testDevice\":\(testDevice),\"managed\":\(managed)"
        if let milliseconds { text += ",\"ms\":\(milliseconds)" }
        if let expires { text += ",\"expires\":\"\(Self.stamp(expires))\"" }
        if let pins { text += ",\"pins\":\(pins)" }
        return text + "}"
    }

    /// The record's fields in file order; `prev` is left out when nil.
    func json(prev: String?) -> OrderedJSON {
        var fields: [(String, OrderedJSON)] = (prev.map { [("prev", .string($0))] } ?? []) + [
            ("time", .string(Self.stamp(time))),
            ("version", .string(version)),
            ("pid", .integer(Int(pid))),
        ]
        if let session { fields.append(("session", .object([("pid", .integer(Int(session.pid))), ("name", .string(session.name))]))) }
        fields.append(("command", .string(command)))
        fields.append(("platform", .string(platform.rawValue)))
        fields.append(("device", .string(device)))
        if let app { fields.append(("app", .string(app))) }
        fields.append(("outcome", .string(outcome.rawValue)))
        if let exit { fields.append(("exit", .integer(Int(exit)))) }
        if let reason { fields.append(("reason", .string(reason))) }
        if let refusal { fields.append(("refusal", .string(refusal))) }
        fields.append(("testDevice", .bool(testDevice)))
        fields.append(("managed", .bool(managed)))
        if let milliseconds { fields.append(("ms", .integer(milliseconds))) }
        if let expires { fields.append(("expires", .string(Self.stamp(expires)))) }
        if let pins { fields.append(("pins", .integer(pins))) }
        return .object(fields)
    }

    /// A line as this build wrote it; nil for anything else, since any process running as the user can write the file.
    public static func parse(_ line: Data) -> (record: AuditRecord, prev: String)? {
        guard line.count <= Shape.maximumLineBytes, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        guard let prev = object["prev"] as? String, Shape.isHash(prev) else { return nil }
        guard
            let stamp = object["time"] as? String, let time = try? Date(stamp, strategy: .iso8601),
            let version = object["version"] as? String, let pid = object["pid"] as? Int, let command = object["command"] as? String,
            let platform = (object["platform"] as? String).flatMap(DevicePlatform.init(rawValue:)),
            let device = object["device"] as? String, Shape.isDeviceKey(device),
            let outcome = (object["outcome"] as? String).flatMap(Outcome.init(rawValue:))
        else { return nil }
        var session: Session?
        if let found = object["session"] as? [String: Any], let pid = found["pid"] as? Int, let name = found["name"] as? String {
            session = Session(pid: Int32(truncatingIfNeeded: pid), name: name)
        }
        let record = AuditRecord(
            time: time, version: version, pid: Int32(truncatingIfNeeded: pid), session: session, command: command, platform: platform, device: device,
            app: object["app"] as? String, outcome: outcome, exit: (object["exit"] as? Int).map { Int32(truncatingIfNeeded: $0) }, reason: object["reason"] as? String,
            refusal: object["refusal"] as? String, testDevice: object["testDevice"] as? Bool ?? false, managed: object["managed"] as? Bool ?? false,
            milliseconds: object["ms"] as? Int, expires: (object["expires"] as? String).flatMap { try? Date($0, strategy: .iso8601) }, pins: object["pins"] as? Int
        )
        return (record, prev)
    }

    /// The fixed shapes that keep free text out of a record.
    public enum Shape {
        public static let maximumLineBytes = 2048
        static let maximumMilliseconds = 86_400_000
        static let maximumPins = 10_000
        static let lower = Set("abcdefghijklmnopqrstuvwxyz")
        static let digits = Set("0123456789")
        static let hex = digits.union("abcdef")
        static let identifier = lower.union(digits).union("ABCDEFGHIJKLMNOPQRSTUVWXYZ").union("._-")

        public static func isHash(_ text: String) -> Bool {
            text.utf8.count == 64 && text.allSatisfy(hex.contains)
        }

        public static func isDeviceKey(_ text: String) -> Bool {
            text.utf8.count == 16 && text.allSatisfy(hex.contains)
        }

        /// Lower-case words joined by single spaces, as `CommandPath` gives them; anything else is `unknown`.
        static func command(_ text: String) -> String {
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            let allowed = lower.union(digits).union("-")
            guard (1...4).contains(words.count), text.utf8.count <= 64, words.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.allSatisfy(allowed.contains) }) else { return "unknown" }
            return text
        }

        /// A bundle id or package name, as the allow-list takes one; nil for anything else.
        static func app(_ text: String) -> String? {
            let shaped = (1...255).contains(text.utf8.count) && text.contains(".") && !text.hasPrefix(".") && !text.hasSuffix(".") && !text.hasPrefix("-")
            return shaped && text.allSatisfy(identifier.contains) ? text : nil
        }

        /// One of the failure reasons Offsider exits with; nil for any other text.
        static func reason(_ text: String) -> String? {
            FailureReason(rawValue: text)?.rawValue
        }

        /// What the gate, an app pin or a broker's recheck can refuse with.
        public static let refusals: Set<String> = [
            "managed_off", "managed_unreadable", "managed_unknown_key", "managed_not_listed", "not_allowed", "expired", "list_unreadable", "list_changed", "newer_entry",
            "app_not_allowed", "device_not_named", "not_wired", other,
        ]
        /// A code this build has no name for, so a refusal is never written as if it had no cause.
        public static let other = "other"

        static func refusal(_ text: String) -> String? {
            if refusals.contains(text) { return text }
            return (1...64).contains(text.utf8.count) && text.allSatisfy(lower.union(digits).union("_").contains) ? other : nil
        }

        /// `0.18.0`, or `0.18.0-3-gabc1234` between releases.
        static func version(_ text: String) -> String {
            let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            let numbered = (2...3).contains(numbers.count) && numbers.allSatisfy { !$0.isEmpty && $0.count <= 5 && $0.allSatisfy(digits.contains) }
            let suffixed = parts.count == 1 || ((1...40).contains(parts[1].count) && parts[1].allSatisfy(identifier.union("+").contains))
            return numbered && suffixed ? text : "unknown"
        }

        /// The kernel keeps 16 characters of a process name; anything outside letters, digits, `.`, `_` and `-` becomes `_`.
        static func processName(_ text: String) -> String {
            let kept = String(text.prefix(16).map { identifier.contains($0) ? $0 : "_" })
            return kept.isEmpty ? "_" : kept
        }
    }
}
