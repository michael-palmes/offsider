import notify
import XCTest

/// The app a command reads: the one named; else what XCTest's private lookups report in front; else, with no lookup, the last one named while it is in front; else SpringBoard.
enum ActiveApplication {
    static let springBoard = "com.apple.springboard"

    static func resolve(requested: String?, remembered: String?) -> XCUIApplication {
        if let requested { return XCUIApplication(bundleIdentifier: requested) }
        let active = activeBundleIDs()
        if let front = active?.first { return XCUIApplication(bundleIdentifier: front) }
        if let remembered, active == nil {
            let app = XCUIApplication(bundleIdentifier: remembered)
            if app.state == .runningForeground { return app }
        }
        return XCUIApplication(bundleIdentifier: springBoard)
    }

    private static let lookup = NSSelectorFromString("activeApplication")
    private static let interfaceKey = NSSelectorFromString("accessibilityInterface")
    private static let monitorKey = NSSelectorFromString("applicationMonitor")
    private static let activeKey = NSSelectorFromString("activeApplications")
    private static let processKey = NSSelectorFromString("processIdentifier")
    private static let monitored = NSSelectorFromString("monitoredApplicationWithProcessIdentifier:")

    /// The bundle ids in front, SpringBoard for a sheet or alert it draws over an app; nil when this Xcode's XCTest offers neither lookup.
    static func activeBundleIDs() -> [String]? {
        if (XCUIApplication.self as AnyObject).responds(to: lookup) {
            let app = (XCUIApplication.self as AnyObject).perform(lookup)?.takeUnretainedValue() as? XCUIApplication
            return [app.flatMap(bundleID(of:))].compactMap { $0 }
        }
        return accessibilityActive()
    }

    /// Xcode 27.1 and later: the accessibility client's active elements, each mapped from its process to its app.
    private static func accessibilityActive() -> [String]? {
        let device = XCUIDevice.shared as NSObject
        guard device.responds(to: interfaceKey), device.responds(to: monitorKey),
              let interface = device.value(forKey: "accessibilityInterface") as? NSObject, interface.responds(to: activeKey),
              let monitor = device.value(forKey: "applicationMonitor") as? NSObject, monitor.responds(to: monitored),
              let elements = interface.value(forKey: "activeApplications") as? [NSObject] else { return nil }
        typealias Lookup = @convention(c) (NSObject, Selector, Int32) -> Unmanaged<NSObject>?
        let find = unsafeBitCast(monitor.method(for: monitored), to: Lookup.self)
        return elements.compactMap { element in
            guard element.responds(to: processKey), let pid = (element.value(forKey: "processIdentifier") as? NSNumber)?.int32Value else { return nil }
            return find(monitor, monitored, pid)?.takeUnretainedValue().value(forKey: "bundleID") as? String
        }
    }

    static func bundleID(of app: XCUIApplication) -> String? {
        privateValue(app, "bundleID") as? String
    }

    static func processID(of app: XCUIApplication) -> Int? {
        (privateValue(app, "processID") as? NSNumber)?.intValue
    }

    private static func privateValue(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
}

/// Whether the panel is lit and the lock screen is up, from the system's own notify state; both read at once, with no button pressed.
enum ScreenState {
    private static func flag(_ name: String) -> Bool? {
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return nil }
        defer { notify_cancel(token) }
        var value: UInt64 = 0
        guard notify_get_state(token, &value) == NOTIFY_STATUS_OK else { return nil }
        return value != 0
    }

    static var isOn: Bool? { flag("com.apple.iokit.hid.displayStatus") }
    static var isLocked: Bool? { flag("com.apple.springboard.lockstate") }

    private static let press = NSSelectorFromString("pressLockButton")

    /// False when this Xcode's XCTest has no lock press.
    static func pressLock() -> Bool {
        guard XCUIDevice.shared.responds(to: press) else { return false }
        _ = XCUIDevice.shared.perform(press)
        return true
    }
}
