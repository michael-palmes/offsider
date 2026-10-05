import XCTest

/// The app a command reads: the one named, else XCTest's private active application, else the last one named while it is in front, else SpringBoard.
enum ActiveApplication {
    static let springBoard = "com.apple.springboard"

    static func resolve(requested: String?, remembered: String?) -> XCUIApplication {
        if let requested { return XCUIApplication(bundleIdentifier: requested) }
        if let active = privateActive() { return active }
        if let remembered {
            let app = XCUIApplication(bundleIdentifier: remembered)
            if app.state == .runningForeground { return app }
        }
        return XCUIApplication(bundleIdentifier: springBoard)
    }

    static func privateActive() -> XCUIApplication? {
        let type: AnyObject = XCUIApplication.self
        let selector = NSSelectorFromString("activeApplication")
        guard type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? XCUIApplication
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
