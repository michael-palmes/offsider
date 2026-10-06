import XCTest

/// The app a command reads: the one named; else, when XCTest's private lookup finds no app or only SpringBoard, the last one named while it is in front; else the lookup's app, else SpringBoard.
enum ActiveApplication {
    static let springBoard = "com.apple.springboard"

    static func resolve(requested: String?, remembered: String?) -> XCUIApplication {
        if let requested { return XCUIApplication(bundleIdentifier: requested) }
        let active = privateActive()
        if let remembered, active.map(isSpringBoard) ?? true {
            let app = XCUIApplication(bundleIdentifier: remembered)
            if app.state == .runningForeground { return app }
        }
        return active ?? XCUIApplication(bundleIdentifier: springBoard)
    }

    /// An iPad with Stage Manager can report SpringBoard over the app in front.
    static func isSpringBoard(_ app: XCUIApplication) -> Bool {
        bundleID(of: app) == springBoard
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
