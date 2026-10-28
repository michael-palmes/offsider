import Foundation

/// Optional capability: the notifications one app has posted, read without another app's text leaving the device where it can.
@MainActor
public protocol PostedNotificationReading: DeviceBackend {
    func notifications(of app: String, on id: DeviceID) async throws -> NotificationSnapshot
}

/// One app's posted notifications, and whether the device picked them by key or by a line filter over the whole dump.
public struct NotificationSnapshot: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// `cmd notification list` then `get` for the app's keys (Android 11 and later).
        case keys
        /// `dumpsys notification --noredact` through a line filter on the device (Android 8 to 10).
        case dump
    }

    public var notifications: [PostedNotification]
    public var source: Source

    public init(notifications: [PostedNotification], source: Source) {
        self.notifications = notifications
        self.source = source
    }
}

public struct PostedNotification: Hashable, Sendable {
    public var key: String
    public var id: Int?
    public var tag: String?
    public var channel: String?
    public var title: String?
    public var text: String?
    public var bigText: String?
    public var subText: String?
    public var postedAt: Date?
    public var ongoing: Bool

    public init(
        key: String, id: Int? = nil, tag: String? = nil, channel: String? = nil, title: String? = nil, text: String? = nil,
        bigText: String? = nil, subText: String? = nil, postedAt: Date? = nil, ongoing: Bool = false
    ) {
        self.key = key
        self.id = id
        self.tag = tag
        self.channel = channel
        self.title = title
        self.text = text
        self.bigText = bigText
        self.subText = subText
        self.postedAt = postedAt
        self.ongoing = ongoing
    }

    /// One-time codes, card numbers, wallet addresses and recovery phrases hidden, as `describe-ui` hides them; and how many.
    public func redacted() -> (notification: PostedNotification, count: Int) {
        var copy = self
        var count = 0
        func hide(_ value: String?) -> String? {
            guard let value else { return nil }
            let result = LogRedactor.redactValue(value)
            count += result.count
            return result.text
        }
        copy.title = hide(title)
        copy.text = hide(text)
        copy.bigText = hide(bigText)
        copy.subText = hide(subText)
        return (copy, count)
    }

    /// Whether any of its text holds `needle`, ignoring case.
    public func contains(_ needle: String) -> Bool {
        [title, text, bigText, subText].contains { $0?.localizedCaseInsensitiveContains(needle) == true }
    }
}

/// The JSON `notifications` prints with `--json`.
public enum NotificationReport {
    static let untrusted = ["notifications[].tag", "notifications[].channel", "notifications[].title", "notifications[].text", "notifications[].bigText", "notifications[].subText"]

    public static func json(_ notifications: [PostedNotification], app: String, source: NotificationSnapshot.Source, redacted: Int, matched: String? = nil, on device: DeviceID) -> String {
        var members: [(String, OrderedJSON)] = [
            ("version", .integer(1)), ("device", .string(device.rawValue)), ("platform", .string(device.platform.rawValue)),
            ("app", .string(app)), ("source", .string(source.rawValue)),
            ("notifications", .array(notifications.map(object))),
            ("redacted", .integer(redacted)),
        ]
        if let matched { members.append(("matched", .string(matched))) }
        return UntrustedPaths.marked(.object(members), untrusted).rendered(compact: true)
    }

    static func object(_ notification: PostedNotification) -> OrderedJSON {
        let text: (String?) -> OrderedJSON = { value in .optional(value) { .string($0) } }
        return .object([
            ("key", .string(notification.key)),
            ("id", .optional(notification.id) { .integer($0) }),
            ("tag", text(notification.tag)),
            ("channel", text(notification.channel)),
            ("title", text(notification.title)),
            ("text", text(notification.text)),
            ("bigText", text(notification.bigText)),
            ("subText", text(notification.subText)),
            ("postedAt", .optional(notification.postedAt) { .string(ProcessStamp.timestamp($0)) }),
            ("ongoing", .bool(notification.ongoing)),
        ])
    }
}
