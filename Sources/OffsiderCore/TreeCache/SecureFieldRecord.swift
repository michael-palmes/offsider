import CryptoKit
import Foundation

/// Where one device's password fields were, so a later read that shows one of them as plain text (a show-password toggle) still masks it.
public struct SecureFieldRecord: Equatable, Sendable {
    public static let version = 1
    public static let maximumEntries = 32
    public static let maximumBytes = 16 * 1024
    /// A field with no id counts as the same one when its frame is within this many points.
    public static let frameTolerance = 2.0

    public struct Entry: Equatable, Sendable {
        public var id: String?
        public var frame: UIFrame?

        public init(id: String?, frame: UIFrame?) {
            self.id = id
            self.frame = frame
        }
    }

    public var platform: DevicePlatform
    public var device: String
    public var writtenAt: Date
    public var bootMarker: String?
    public var entries: [Entry]

    public init(platform: DevicePlatform, device: String, writtenAt: Date, bootMarker: String?, entries: [Entry]) {
        self.platform = platform
        self.device = device
        self.writtenAt = writtenAt
        self.bootMarker = bootMarker
        self.entries = entries
    }

    /// `<first 16 hex of SHA-256 of "platform:device">.secure.json`, beside the tree cache's own file.
    public static func fileName(platform: DevicePlatform, device: String) -> String {
        let digest = SHA256.hash(data: Data("\(platform.rawValue):\(device)".utf8))
        return digest.prefix(8).map { unsafe String(format: "%02x", $0) }.joined() + ".secure.json"
    }

    /// The tree cache's lifetime and boot rule.
    public func isUsable(now: Date, bootMarker current: String?) -> Bool {
        let age = now.timeIntervalSince(writtenAt)
        return age >= 0 && age < TreeCacheRecord.lifetime && bootMarker == current
    }

    /// The fields to remember after `tree`: its password fields, and earlier ones it still shows revealed; nil when there are none.
    public static func next(previous: SecureFieldRecord?, tree: UITree, bootMarker: String?, now: Date) -> SecureFieldRecord? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        var entries = nodes.filter(\.isSecure).map { Entry(id: $0.normalizedID, frame: $0.frame) }
        if let previous {
            let revealed = RevealedSecrets(previous)
            for entry in previous.entries where !entries.contains(entry) {
                if nodes.contains(where: { revealed.matches($0) && revealed.entryMatches(entry, $0) }) {
                    entries.append(entry)
                }
            }
        }
        guard !entries.isEmpty else { return nil }
        return SecureFieldRecord(
            platform: tree.platform, device: tree.device, writtenAt: now, bootMarker: bootMarker, entries: Array(entries.prefix(maximumEntries))
        )
    }

    public func encoded() -> Data {
        let members: [(String, OrderedJSON)] = [
            ("version", .integer(Self.version)),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("writtenAt", .integer(Int((writtenAt.timeIntervalSince1970 * 1000).rounded()))),
            ("bootMarker", .optional(bootMarker, OrderedJSON.string)),
            ("entries", .array(entries.map { entry in
                .object([("id", .optional(entry.id, OrderedJSON.string)), ("frame", entry.frame.map(\.jsonValue) ?? .null)])
            })),
        ]
        return Data(OrderedJSON.object(members).rendered(compact: true).utf8)
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == Self.version,
              let platform = (object["platform"] as? String).flatMap(DevicePlatform.init(rawValue:)),
              let device = object["device"] as? String,
              let written = object["writtenAt"] as? NSNumber,
              let rawEntries = object["entries"] as? [[String: Any]] else {
            throw UITreeDecodingError(description: "not a secure field record")
        }
        let entries = rawEntries.prefix(Self.maximumEntries).map { entry in
            let frame = (entry["frame"] as? [String: Any]).flatMap { frame -> UIFrame? in
                guard let x = frame["x"] as? NSNumber, let y = frame["y"] as? NSNumber,
                      let width = frame["width"] as? NSNumber, let height = frame["height"] as? NSNumber else { return nil }
                return UIFrame(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
            }
            return Entry(id: entry["id"] as? String, frame: frame)
        }
        self.init(
            platform: platform, device: device, writtenAt: Date(timeIntervalSince1970: written.doubleValue / 1000),
            bootMarker: object["bootMarker"] as? String, entries: Array(entries)
        )
    }
}

/// A recorded password field's id or frame, looked up once per text field in a later tree.
public struct RevealedSecrets: Equatable, Sendable {
    public let ids: Set<String>
    /// Frames of recorded fields that had no id.
    public let frames: [UIFrame]

    public init(_ record: SecureFieldRecord) {
        ids = Set(record.entries.compactMap(\.id))
        frames = record.entries.filter { $0.id == nil }.compactMap(\.frame)
    }

    public var isEmpty: Bool { ids.isEmpty && frames.isEmpty }

    /// A plain text field at a recorded id, or with no id at a recorded frame within 2 points.
    public func matches(_ node: UINode) -> Bool {
        guard node.role.isTextInput, !node.isSecure else { return false }
        if let id = node.normalizedID { return ids.contains(id) }
        guard let frame = node.frame else { return false }
        return frames.contains { Self.near($0, frame) }
    }

    func entryMatches(_ entry: SecureFieldRecord.Entry, _ node: UINode) -> Bool {
        if let id = entry.id { return node.normalizedID == id }
        guard node.normalizedID == nil, let recorded = entry.frame, let frame = node.frame else { return false }
        return Self.near(recorded, frame)
    }

    static func near(_ lhs: UIFrame, _ rhs: UIFrame) -> Bool {
        let tolerance = SecureFieldRecord.frameTolerance
        return abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}
