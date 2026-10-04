import CryptoKit
import Foundation

/// The last tree Offsider read from one device, with secure values masked and platform attributes left out.
public struct TreeCacheRecord: Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes = 1_000_000
    public static let lifetime: TimeInterval = 600

    /// How the tree relates to the writing command's input.
    public enum TreeRole: String, Sendable {
        /// Written by a command that sent no input.
        case read
        /// A full read after the command's last input.
        case postAction
        /// The command sent input after its last full read, so the tree shows the screen before that input.
        case preAction
    }

    public var platform: DevicePlatform
    public var device: String
    public var command: String
    public var writtenAt: Date
    public var treeReadAt: Date?
    public var lastInputAt: Date?
    /// Nil with no tree: input with no read at all, or a tree over the size cap.
    public var treeRole: TreeRole?
    public var bootMarker: String?
    public var screen: UIScreenInfo?
    public var appFrame: UIFrame?
    public var hash: String?
    public var truncated: Bool
    public var roots: [UINode]?

    public init(
        platform: DevicePlatform,
        device: String,
        command: String,
        writtenAt: Date,
        treeReadAt: Date? = nil,
        lastInputAt: Date? = nil,
        treeRole: TreeRole? = nil,
        bootMarker: String? = nil,
        screen: UIScreenInfo? = nil,
        appFrame: UIFrame? = nil,
        hash: String? = nil,
        truncated: Bool = false,
        roots: [UINode]? = nil
    ) {
        self.platform = platform
        self.device = device
        self.command = command
        self.writtenAt = writtenAt
        self.treeReadAt = treeReadAt
        self.lastInputAt = lastInputAt
        self.treeRole = treeRole
        self.bootMarker = bootMarker
        self.screen = screen
        self.appFrame = appFrame
        self.hash = hash
        self.truncated = truncated
        self.roots = roots
    }

    /// The cached tree, without a screen; nil for a record with no tree.
    public var tree: UITree? {
        roots.map { UITree(platform: platform, device: device, roots: $0, sourceTruncated: truncated) }
    }

    /// `<first 16 hex of SHA-256 of "platform:device">.json`, so device names never reach a file name.
    public static func fileName(platform: DevicePlatform, device: String) -> String {
        let digest = SHA256.hash(data: Data("\(platform.rawValue):\(device)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Absent once 10 minutes old, when dated in the future, or from another boot of the device.
    public func isUsable(now: Date, bootMarker current: String?) -> Bool {
        let age = now.timeIntervalSince(writtenAt)
        guard age >= 0, age < Self.lifetime else { return false }
        return bootMarker == current
    }

    /// False when the app frame's size moved by more than 1 pt, or a rotation, display or posture both reads know differs.
    public func matches(appFrame current: UIFrame?, screen currentScreen: UIScreenInfo? = nil) -> Bool {
        if let appFrame, let current,
           abs(appFrame.width - current.width) > 1 || abs(appFrame.height - current.height) > 1 {
            return false
        }
        if let screen, let currentScreen {
            if let old = screen.resolvedRotationDegrees, let new = currentScreen.resolvedRotationDegrees, old != new { return false }
            if screen.resolvedDisplay(on: platform).id != currentScreen.resolvedDisplay(on: platform).id { return false }
            if screen.posture != currentScreen.posture { return false }
        }
        return true
    }

    // MARK: File form

    public func encoded() -> Data {
        let members: [(String, OrderedJSON)] = [
            ("version", .integer(Self.version)),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("command", .string(command)),
            ("writtenAt", .integer(Self.milliseconds(writtenAt))),
            ("treeReadAt", .optional(treeReadAt.map(Self.milliseconds), OrderedJSON.integer)),
            ("lastInputAt", .optional(lastInputAt.map(Self.milliseconds), OrderedJSON.integer)),
            ("treeRole", .optional(treeRole?.rawValue, OrderedJSON.string)),
            ("bootMarker", .optional(bootMarker, OrderedJSON.string)),
            ("screen", screen.map { $0.jsonValue(on: platform) } ?? .null),
            ("appFrame", appFrame.map { .array([$0.x, $0.y, $0.width, $0.height].map(OrderedJSON.number)) } ?? .null),
            ("hash", .optional(hash, OrderedJSON.string)),
            ("truncated", .bool(truncated)),
            ("roots", roots.map { .array($0.map(Self.encode)) } ?? .null),
        ]
        return Data(OrderedJSON.object(members).rendered(compact: true).utf8)
    }

    public init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == Self.version,
              let platformName = object["platform"] as? String, let platform = DevicePlatform(rawValue: platformName),
              let device = object["device"] as? String,
              let written = object["writtenAt"] as? NSNumber else {
            throw UITreeDecodingError(description: "not a tree cache record")
        }
        let frame = (object["appFrame"] as? [NSNumber]).flatMap { values -> UIFrame? in
            guard values.count == 4 else { return nil }
            return UIFrame(x: values[0].doubleValue, y: values[1].doubleValue, width: values[2].doubleValue, height: values[3].doubleValue)
        }
        self.init(
            platform: platform,
            device: device,
            command: object["command"] as? String ?? "offsider",
            writtenAt: Self.date(written),
            treeReadAt: (object["treeReadAt"] as? NSNumber).map(Self.date),
            lastInputAt: (object["lastInputAt"] as? NSNumber).map(Self.date),
            treeRole: (object["treeRole"] as? String).flatMap(TreeRole.init(rawValue:)),
            bootMarker: object["bootMarker"] as? String,
            screen: (object["screen"] as? [String: Any]).flatMap(UIScreenInfo.init(jsonObject:)),
            appFrame: frame,
            hash: object["hash"] as? String,
            truncated: object["truncated"] as? Bool ?? false,
            roots: try (object["roots"] as? [[String: Any]]).map { try $0.map { try UINode(jsonObject: $0, platform: platform) } }
        )
    }

    private static func encode(_ node: UINode) -> OrderedJSON {
        .object(node.jsonFields.filter { $0.0 != "native" } + [("children", .array(node.children.map(encode)))])
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ value: NSNumber) -> Date {
        Date(timeIntervalSince1970: value.doubleValue / 1000)
    }
}

extension TreeCacheRecord {
    /// The record one command leaves for a device, or nil to leave the file as it is.
    /// `inputAtEnd` covers an input command that recorded no input event: it counts as input when the command ends.
    public static func committing(
        _ activity: DeviceActivityLedger.Activity,
        previous: TreeCacheRecord?,
        command: String,
        inputAtEnd: Bool,
        bootMarker: String?,
        now: Date
    ) -> TreeCacheRecord? {
        let input = activity.lastInputAt ?? (inputAtEnd ? now : nil)
        let role: TreeRole?
        var lastInputAt = input
        if let input {
            if let readAt = activity.treeReadAt, activity.tree != nil {
                role = readAt >= input ? .postAction : .preAction
            } else {
                role = nil
            }
        } else {
            guard activity.tree != nil else { return nil }
            // A read that began before another command's input must not replace that command's record.
            if let started = activity.firstReadStartedAt, let previousInput = previous?.lastInputAt, previousInput > started {
                return nil
            }
            role = .read
            lastInputAt = previous?.lastInputAt
        }
        let tombstone = TreeCacheRecord(
            platform: activity.device.platform,
            device: activity.device.rawValue,
            command: command,
            writtenAt: now,
            lastInputAt: lastInputAt,
            bootMarker: bootMarker
        )
        guard let role, let tree = activity.tree else { return tombstone }
        var record = tombstone
        record.treeRole = role
        record.treeReadAt = activity.treeReadAt
        record.screen = activity.screen
        record.appFrame = tree.applicationFrame
        record.hash = TreeDiff.hash(tree)
        record.truncated = tree.sourceTruncated
        record.roots = tree.roots
        return record
    }
}

extension TreeCacheRecord {
    /// The same record with the tree dropped, for one over the size cap.
    public func withoutTree() -> TreeCacheRecord {
        TreeCacheRecord(platform: platform, device: device, command: command, writtenAt: writtenAt, lastInputAt: lastInputAt, bootMarker: bootMarker)
    }
}
