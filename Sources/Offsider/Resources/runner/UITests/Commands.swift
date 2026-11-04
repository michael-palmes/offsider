import UIKit
import XCTest

/// Every route the runner serves; called on the main thread, as XCUITest requires.
final class RunnerCommands {
    static let version = "3"
    static let inputRoutes: Set<String> = ["/tap-point", "/tap-element", "/type", "/swipe", "/home", "/lock"]

    /// Just under how long Offsider waits for a route, whose clock starts first; later, nobody is listening and running it would only hold the main thread.
    static func queueLimit(_ path: String) -> TimeInterval? {
        if path == "/snapshot" { return 14 }
        return inputRoutes.contains(path) ? 4 : nil
    }

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
        if request.method == "POST", request.path == "/foreground" { return foreground(body) }
        let requested = body["app"] as? String
        // An app waiting on the prompt would hold this thread for about 20 s per read, and input would reach the prompt, not the app.
        if request.path == "/snapshot" || Self.inputRoutes.contains(request.path), let requested, let prompt = systemPrompt(over: requested) {
            return .systemPrompt(prompt)
        }
        if let requested, XCUIApplication(bundleIdentifier: requested).state != .runningForeground {
            if ScreenState.isLocked == true { return .failure(409, code: "screen_locked", message: "the lock screen is up") }
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
        case ("GET", "/screen"):
            return screen()
        case ("POST", "/lock"):
            return ScreenState.pressLock() ? .ok([String: Any]()) : .failure(409, code: "lock_unavailable", message: "this Xcode's XCTest cannot press the lock button")
        case ("POST", "/stop"):
            stopRequested = true
            return .ok([String: Any]())
        default:
            return .failure(404, code: "not_found", message: "\(request.method) \(request.path) is not a runner route")
        }
    }

    /// What iOS calls a system alert or sheet over `app`, or a prompt in its own process.
    private func systemPrompt(over app: String) -> String? {
        guard app != ActiveApplication.springBoard else { return nil }
        return ActiveApplication.hostedPrompt() ?? springBoardPrompt(active: ActiveApplication.activeBundleIDs())
    }

    /// SpringBoard's alert or sheet. The active list comes first, as it costs about 10 ms and looking for one about 70 ms; with no list, it looks.
    private func springBoardPrompt(active: [String]?) -> String? {
        guard active?.contains(ActiveApplication.springBoard) != false else { return nil }
        let springBoard = XCUIApplication(bundleIdentifier: ActiveApplication.springBoard)
        return [springBoard.alerts.firstMatch, springBoard.sheets.firstMatch].first(where: \.exists)?.label
    }

    private func app(_ body: [String: Any]) -> XCUIApplication {
        let requested = body["app"] as? String
        if let requested { rememberedApp = requested }
        return ActiveApplication.resolve(requested: requested, remembered: rememberedApp)
    }

    private func ping() -> RunnerResponse {
        let screen = UIScreen.main
        let scale = screen.nativeScale
        return .ok([
            "version": Self.version,
            "buildKey": buildKey,
            "screenBounds": ["width": screen.nativeBounds.width / scale, "height": screen.nativeBounds.height / scale],
            "scale": scale,
            "orientation": Self.orientationName(XCUIDevice.shared.orientation),
            "activeBundleId": ActiveApplication.activeBundleIDs()?.first as Any? ?? NSNull(),
        ])
    }

    private func screen() -> RunnerResponse {
        guard let on = ScreenState.isOn, let locked = ScreenState.isLocked else {
            return .failure(409, code: "screen_unreadable", message: "the device did not report its screen state")
        }
        return .ok(["on": on, "locked": locked])
    }

    /// Whether the named app is in front, by XCTest's private active-app lookups, where SpringBoard stands for a sheet or alert over it; else, where Xcode has neither, by the app's own foreground state. A remembered app never stands in.
    private func foreground(_ body: [String: Any]) -> RunnerResponse {
        guard let app = body["app"] as? String, !app.isEmpty else { return .failure(400, code: "bad_request", message: "app is required") }
        let running = XCUIApplication(bundleIdentifier: app).state == .runningForeground
        // A dark screen counts as locked: the lock state itself can lag the press by up to a second.
        let locked = ScreenState.isLocked == true || ScreenState.isOn == false
        var reply: [String: Any] = ["locked": locked]
        let hosted = app == ActiveApplication.springBoard ? nil : ActiveApplication.hostedPrompt()
        reply["prompt"] = hosted
        guard let active = ActiveApplication.activeBundleIDs() else {
            reply["inFront"] = running && !locked && hosted == nil
            reply["activeBundleId"] = running ? app as Any : NSNull()
            reply["sheetsVisible"] = false
            return .ok(reply)
        }
        let covered = app != ActiveApplication.springBoard && active.contains(ActiveApplication.springBoard)
        if hosted == nil, covered, let prompt = springBoardPrompt(active: active) { reply["prompt"] = prompt }
        reply["inFront"] = running && active.contains(app) && !covered && !locked && hosted == nil
        reply["activeBundleId"] = active.first as Any? ?? NSNull()
        reply["sheetsVisible"] = true
        return .ok(reply)
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
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        let field = try? focused.snapshot()
        // XCTest names the text in each typeText's activity, which runner.log and the result bundle keep.
        if let field, Self.isSecure(field) {
            return .failure(422, code: "secure_field", message: "typing into a secure field is refused")
        }
        guard body["replace"] as? Bool == true else {
            app.typeText(text)
            return .ok([String: Any]())
        }
        guard field != nil else { return .failure(409, code: "no_focus", message: "no field has keyboard focus") }
        guard clear(focused) else {
            return .failure(409, code: "replace_failed", message: "the focused field still held text after clearing it")
        }
        focused.typeText(text)
        return .ok([String: Any]())
    }

    /// A secure field, or a React Native one XCTest reports as a text field whose value is only its mask's dots.
    static func isSecure(_ field: XCUIElementSnapshot) -> Bool {
        if field.elementType == .secureTextField { return true }
        guard let value = SnapshotEncoder.text(field.value), !value.isEmpty, value != field.placeholderValue else { return false }
        return value.unicodeScalars.allSatisfy { $0 == "\u{2022}" || $0 == "\u{25CF}" }
    }

    /// Taps the field's right edge (the end of its text, or its clear button) and deletes the whole value, again while text is left.
    /// Two passes in a row that change nothing leave no text to delete: the value is the app's own, such as "empty" or a mask's `(___) ___-____`.
    private func clear(_ field: XCUIElement) -> Bool {
        let placeholder = field.placeholderValue ?? ""
        var current = SnapshotEncoder.text(field.value) ?? ""
        var unchanged = false
        for attempt in 0..<3 {
            if current.isEmpty || (attempt > 0 && current == placeholder) { return true }
            // A placeholder value may be real text: delete it without a tap, which in an empty search field lands on dictation.
            if current != placeholder { field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap() }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            let left = SnapshotEncoder.text(field.value) ?? ""
            // One pass a field ignored, before its cursor or keyboard was ready, must not leave its text to be typed after.
            if left == current, unchanged { return true }
            unchanged = left == current
            current = left
        }
        return current.isEmpty || current == placeholder
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
