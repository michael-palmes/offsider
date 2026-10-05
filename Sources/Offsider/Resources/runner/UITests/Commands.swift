import UIKit
import XCTest

/// Every route the runner serves; called on the main thread, as XCUITest requires.
final class RunnerCommands {
    static let version = "1"

    let buildKey: String
    private(set) var lastActivity = Date()
    private(set) var stopRequested = false
    private var rememberedApp: String?

    init(buildKey: String) {
        self.buildKey = buildKey
    }

    func handle(_ request: RunnerRequest) -> RunnerResponse {
        lastActivity = Date()
        let body = (try? JSONSerialization.jsonObject(with: request.body.isEmpty ? Data("{}".utf8) : request.body)) as? [String: Any]
        guard let body else { return .failure(400, code: "bad_request", message: "the body is not a JSON object") }
        if let requested = body["app"] as? String, XCUIApplication(bundleIdentifier: requested).state != .runningForeground {
            return .failure(409, code: "app_not_in_front", message: "\(requested) is not the app in front")
        }
        switch (request.method, request.path) {
        case ("GET", "/ping"): return ping()
        case ("POST", "/snapshot"): return snapshot(app(body))
        case ("POST", "/tap-point"): return tapPoint(body)
        case ("POST", "/tap-element"): return tapElement(body)
        case ("POST", "/type"): return type(body)
        case ("POST", "/swipe"): return swipe(body)
        case ("POST", "/home"):
            XCUIDevice.shared.press(.home)
            return .ok([String: Any]())
        case ("POST", "/stop"):
            stopRequested = true
            return .ok([String: Any]())
        default:
            return .failure(404, code: "not_found", message: "\(request.method) \(request.path) is not a runner route")
        }
    }

    private func app(_ body: [String: Any]) -> XCUIApplication {
        let requested = body["app"] as? String
        if let requested { rememberedApp = requested }
        return ActiveApplication.resolve(requested: requested, remembered: rememberedApp)
    }

    private func ping() -> RunnerResponse {
        let screen = UIScreen.main
        let scale = screen.nativeScale
        let active = ActiveApplication.privateActive()
        return .ok([
            "version": Self.version,
            "buildKey": buildKey,
            "screenBounds": ["width": screen.nativeBounds.width / scale, "height": screen.nativeBounds.height / scale],
            "scale": scale,
            "orientation": Self.orientationName(XCUIDevice.shared.orientation),
            "activeBundleId": (active.flatMap(ActiveApplication.bundleID(of:)) ?? rememberedApp) as Any? ?? NSNull(),
        ])
    }

    private func snapshot(_ app: XCUIApplication) -> RunnerResponse {
        do {
            let root = try app.snapshot()
            var encoder = SnapshotEncoder(budget: 8)
            var node = encoder.encode(root)
            if let pid = ActiveApplication.processID(of: app) { node["pid"] = pid }
            if let bundleID = ActiveApplication.bundleID(of: app) { node["bundleId"] = bundleID }
            if encoder.truncated { node["truncated"] = true }
            return .ok([node])
        } catch {
            return .failure(409, code: "snapshot_failed", message: "\(error.localizedDescription)")
        }
    }

    private func tapPoint(_ body: [String: Any]) -> RunnerResponse {
        guard let x = number(body["x"]), let y = number(body["y"]) else {
            return .failure(400, code: "bad_request", message: "x and y are required")
        }
        coordinate(x, y, in: app(body)).tap()
        return .ok([String: Any]())
    }

    private func tapElement(_ body: [String: Any]) -> RunnerResponse {
        guard let query = body["query"] as? [String: Any] else { return .failure(400, code: "bad_request", message: "query is required") }
        var predicates: [NSPredicate] = []
        if let id = query["id"] as? String { predicates.append(NSPredicate(format: "identifier == %@", id)) }
        if let label = query["label"] as? String { predicates.append(NSPredicate(format: "label == %@", label)) }
        guard !predicates.isEmpty else { return .failure(400, code: "bad_request", message: "query needs id or label") }
        let element = app(body).descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates)).firstMatch
        guard element.exists else { return .failure(409, code: "element_not_found", message: "no element matches the query") }
        element.tap()
        return .ok([String: Any]())
    }

    private func type(_ body: [String: Any]) -> RunnerResponse {
        guard let text = body["text"] as? String else { return .failure(400, code: "bad_request", message: "text is required") }
        let app = app(body)
        guard body["replace"] as? Bool == true else {
            app.typeText(text)
            return .ok([String: Any]())
        }
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard focused.exists else { return .failure(409, code: "no_focus", message: "no field has keyboard focus") }
        guard focused.elementType != .secureTextField else {
            return .failure(422, code: "secure_field", message: "replacing the text of a secure field is refused")
        }
        guard clear(focused) else {
            return .failure(409, code: "replace_failed", message: "the focused field still held text after clearing it")
        }
        focused.typeText(text)
        return .ok([String: Any]())
    }

    /// Taps the field's right edge (the end of its text, or its clear button) and deletes the whole value, retrying while text is left.
    private func clear(_ field: XCUIElement) -> Bool {
        let placeholder = field.placeholderValue ?? ""
        for attempt in 0..<3 {
            let current = SnapshotEncoder.text(field.value) ?? ""
            if current.isEmpty || (attempt > 0 && current == placeholder) { return true }
            // A placeholder value may be real text: delete it without a tap, which in an empty search field lands on dictation.
            if current != placeholder { field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap() }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        let left = SnapshotEncoder.text(field.value) ?? ""
        return left.isEmpty || left == placeholder
    }

    private func swipe(_ body: [String: Any]) -> RunnerResponse {
        guard let fromX = number(body["fromX"]), let fromY = number(body["fromY"]),
              let toX = number(body["toX"]), let toY = number(body["toY"]) else {
            return .failure(400, code: "bad_request", message: "fromX, fromY, toX and toY are required")
        }
        let duration = max(number(body["duration"]) ?? 0.3, 0.05)
        let app = app(body)
        let distance = hypot(toX - fromX, toY - fromY)
        let velocity = XCUIGestureVelocity(rawValue: max(distance / duration, 1))
        coordinate(fromX, fromY, in: app).press(forDuration: 0.05, thenDragTo: coordinate(toX, toY, in: app), withVelocity: velocity, thenHoldForDuration: 0)
        return .ok([String: Any]())
    }

    /// Screen points, as snapshot frames are, so an app window that does not start at the screen's origin is allowed for.
    private func coordinate(_ x: Double, _ y: Double, in app: XCUIApplication) -> XCUICoordinate {
        let origin = app.frame.origin
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - origin.x, dy: y - origin.y))
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func orientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown"
        }
    }
}
