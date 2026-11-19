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
    /// The last tree read with no modal over the app, kept while later reads of the same app on the same screen show a modal, which hides it.
    public var beneath: Beneath?

    /// One tree read and when; `confirmed` once a modal's own shape or a capture's text read showed it hides that screen.
    public struct Beneath: Equatable, Sendable {
        /// A memory nothing confirmed lasts an agent's next step or two, as moving to a new screen with no read between looks like a modal too.
        public static let unconfirmedLifetime: TimeInterval = 120

        public var readAt: Date
        public var roots: [UINode]
        public var confirmed: Bool

        public init(readAt: Date, roots: [UINode], confirmed: Bool = false) {
            self.readAt = readAt
            self.roots = roots
            self.confirmed = confirmed
        }

        /// Under its lifetime at `now`: the cache's own once confirmed, else `unconfirmedLifetime`.
        public func isFresh(now: Date) -> Bool {
            let age = now.timeIntervalSince(readAt)
            return age >= 0 && age < (confirmed ? TreeCacheRecord.lifetime : Self.unconfirmedLifetime)
        }

        /// The same app, named alike, in an app frame of the same size within 1 pt, so the screen did not turn or resize.
        public func fits(_ tree: UITree) -> Bool {
            let app = roots.first { $0.role == .application }
            guard let app, app.normalizedLabel == tree.roots.first(where: { $0.role == .application })?.normalizedLabel else { return false }
            guard let old = UITree.applicationFrame(in: roots), let new = tree.applicationFrame else { return true }
            return abs(old.width - new.width) <= 1 && abs(old.height - new.height) <= 1
        }
    }

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
        roots: [UINode]? = nil,
        beneath: Beneath? = nil
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
        self.beneath = beneath
    }

    /// What a modal shown now hides: `beneath`, else this record's own tree when no iOS modal covers it.
    public func uncovered(statusBar: Double) -> Beneath? {
        if let beneath { return beneath }
        guard platform == .ios, let roots, let tree, HiddenScreen.modal(in: tree, belowStatusBar: statusBar) == nil else { return nil }
        return Beneath(readAt: treeReadAt ?? writtenAt, roots: roots)
    }

    /// The cached tree, without a screen; nil for a record with no tree.
    public var tree: UITree? {
        roots.map { UITree(platform: platform, device: device, roots: $0, sourceTruncated: truncated) }
    }

    /// `<first 16 hex of SHA-256 of "platform:device">.json`, so device names never reach a file name.
    public static func fileName(platform: DevicePlatform, device: String) -> String {
        let digest = SHA256.hash(data: Data("\(platform.rawValue):\(device)".utf8))
        return digest.prefix(8).map { unsafe String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Absent once 10 minutes old, when dated in the future, or from another boot of the device.
    public func isUsable(now: Date, bootMarker current: String?) -> Bool {
        let age = now.timeIntervalSince(writtenAt)
        guard age >= 0, age < Self.lifetime else { return false }
        return bootMarker == current
    }

    /// True for a cache file last written a lifetime or more before `now`, whichever device it is for.
    public static func isExpired(modifiedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(modifiedAt) >= lifetime
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
            ("beneath", beneath.map {
                .object([("readAt", .integer(Self.milliseconds($0.readAt))), ("confirmed", .bool($0.confirmed)), ("roots", .array($0.roots.map(Self.encode)))])
            } ?? .null),
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
            roots: try (object["roots"] as? [[String: Any]]).map { try $0.map { try UINode(jsonObject: $0, platform: platform) } },
            beneath: try (object["beneath"] as? [String: Any]).flatMap { beneath -> Beneath? in
                guard let read = beneath["readAt"] as? NSNumber, let roots = beneath["roots"] as? [[String: Any]] else { return nil }
                return Beneath(
                    readAt: Self.date(read), roots: try roots.map { try UINode(jsonObject: $0, platform: platform) }, confirmed: beneath["confirmed"] as? Bool ?? false
                )
            }
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
    /// The record one command leaves for a device, or nil to leave the file; `inputAtEnd` stamps input no event recorded.
    public static func committing(
        _ activity: DeviceActivityLedger.Activity,
        previous: TreeCacheRecord?,
        command: String,
        inputAtEnd: Bool,
        bootMarker: String?,
        now: Date,
        statusBar: Double
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
        var carried = previous.flatMap { $0.uncovered(statusBar: statusBar) }
        if carried?.isFresh(now: now) == false { carried = nil }
        guard let role, let tree = activity.tree else {
            var record = tombstone
            record.beneath = carried
            return record
        }
        var record = tombstone
        record.treeRole = role
        record.treeReadAt = activity.treeReadAt
        record.screen = activity.screen
        record.appFrame = tree.applicationFrame
        record.hash = TreeDiff.hash(tree)
        record.truncated = tree.sourceTruncated
        record.roots = tree.roots
        // A modal over the same app on the same screen hides what the last read without one showed; any other read starts afresh.
        if let previous, var carried, activity.beneathShown != false, carried.fits(tree),
           let modal = HiddenScreen.modal(in: tree, belowStatusBar: statusBar, remembered: UITree(platform: tree.platform, device: tree.device, roots: carried.roots)),
           previous.matches(appFrame: record.appFrame, screen: activity.screen) {
            if !modal.byMemory || activity.beneathShown == true { carried.confirmed = true }
            record.beneath = carried
        }
        return record
    }
}

extension TreeCacheRecord {
    /// The same record without the tree a modal hides, for one over the size cap.
    public func withoutBeneath() -> TreeCacheRecord {
        var record = self
        record.beneath = nil
        return record
    }

    /// The same record with the tree dropped, for one over the size cap.
    public func withoutTree() -> TreeCacheRecord {
        TreeCacheRecord(platform: platform, device: device, command: command, writtenAt: writtenAt, lastInputAt: lastInputAt, bootMarker: bootMarker)
    }
}
