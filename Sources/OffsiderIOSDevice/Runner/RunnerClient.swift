import Foundation
import OffsiderCore

/// What `GET /ping` reports: the runner's protocol version and build, and the screen as the device sees it.
public struct RunnerPing: Equatable, Sendable {
    public var version: String
    public var buildKey: String
    /// The portrait panel in points.
    public var screenWidth: Double?
    public var screenHeight: Double?
    public var scale: Double?
    /// `UIDeviceOrientation` by name: portrait, landscapeLeft, ...
    public var orientation: String?
    public var activeBundleID: String?

    public init(version: String, buildKey: String, screenWidth: Double? = nil, screenHeight: Double? = nil, scale: Double? = nil, orientation: String? = nil, activeBundleID: String? = nil) {
        self.version = version
        self.buildKey = buildKey
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
        self.orientation = orientation
        self.activeBundleID = activeBundleID
    }
}

/// What `POST /foreground` reports.
public struct RunnerForeground: Equatable, Sendable {
    public let inFront: Bool
    public let activeBundleID: String?
    /// What iOS calls a system alert or sheet over the app.
    public let prompt: String?
    /// True when the lock screen is up; nil when the device did not say.
    public let locked: Bool?
    /// False when this Xcode offers no active-app lookup, so a system sheet over the app goes unseen.
    public let sheetsVisible: Bool

    public init(inFront: Bool, activeBundleID: String?, prompt: String? = nil, locked: Bool? = nil, sheetsVisible: Bool = true) {
        self.inFront = inFront
        self.activeBundleID = activeBundleID
        self.prompt = prompt
        self.locked = locked
        self.sheetsVisible = sheetsVisible
    }
}

/// What `POST /alert` reports: SpringBoard's alert, if any, and the state of the app it may be over.
public struct RunnerAlert: Sendable {
    /// The app's process is in the foreground, as it stays beneath an alert.
    public let appInFront: Bool
    /// The bundle ids XCTest reports as active; nil when this Xcode offers no lookup.
    public let active: [String]?
    /// A prompt drawn by a process of its own, by its fixed name.
    public let hosted: String?
    public let locked: Bool
    /// The alert as idb-shaped JSON, one root; nil when none is up.
    public let alert: Data?

    public init(appInFront: Bool, active: [String]?, hosted: String? = nil, locked: Bool = false, alert: Data?) {
        self.appInFront = appInFront
        self.active = active
        self.hosted = hosted
        self.locked = locked
        self.alert = alert
    }
}

/// What `GET /screen` reports.
public struct RunnerScreen: Equatable, Sendable {
    public let on: Bool
    public let locked: Bool

    public init(on: Bool, locked: Bool) {
        self.on = on
        self.locked = locked
    }
}

/// What a reuse ping found: an answer, a runner that accepted the connection but is still busy, or nothing usable.
public enum RunnerProbe: Equatable, Sendable {
    case answered(RunnerPing)
    case busy
    case unreachable
}

/// The runner's routes, each a fresh connection through `transport`.
public struct RunnerClient: Sendable {
    public static let protocolVersion = "5"
    public static let timeout: TimeInterval = 5

    public let udid: String
    public let token: String
    /// An agent may answer a test device's prompts itself, so a refusal gives it the commands rather than a request for a person.
    public var testDevice = false
    let transport: any RunnerTransport

    public init(udid: String, token: String, transport: any RunnerTransport) {
        self.udid = udid
        self.token = token
        self.transport = transport
    }

    public func ping(timeout: TimeInterval = RunnerClient.timeout) async throws -> RunnerPing {
        try parsePing(try await call("GET", "/ping", nil, timeout: timeout))
    }

    /// `/ping` without mapping failures; only a timeout after the connection was made reads as busy.
    public func probe(timeout: TimeInterval) async -> RunnerProbe {
        let transport = transport
        let token = token
        let response: UsbmuxHTTPResponse
        do {
            response = try await Task.detached {
                try transport.exchange(method: "GET", path: "/ping", token: token, body: nil, timeout: timeout)
            }.value
        } catch UsbmuxError.timedOut {
            return .busy
        } catch {
            return .unreachable
        }
        guard let ping = try? parsePing(try Self.unwrap(response, path: "/ping", udid: udid)) else { return .unreachable }
        return .answered(ping)
    }

    func parsePing(_ payload: Any?) throws -> RunnerPing {
        let data = payload as? [String: Any] ?? [:]
        guard let version = data["version"] as? String, let buildKey = data["buildKey"] as? String else {
            throw malformed("/ping")
        }
        let bounds = data["screenBounds"] as? [String: Any]
        return RunnerPing(
            version: version,
            buildKey: buildKey,
            screenWidth: (bounds?["width"] as? NSNumber)?.doubleValue,
            screenHeight: (bounds?["height"] as? NSNumber)?.doubleValue,
            scale: (data["scale"] as? NSNumber)?.doubleValue,
            orientation: data["orientation"] as? String,
            activeBundleID: data["activeBundleId"] as? String
        )
    }

    /// The tree as idb-shaped JSON, ready for `IOSAccessibilityMapping.roots(fromJSON:)`.
    public func snapshot(app: String?) async throws -> Data {
        let body: [String: Any] = app.map { ["app": $0] } ?? [:]
        let data = try await call("POST", "/snapshot", body, timeout: 15)
        guard let data, JSONSerialization.isValidJSONObject(data) else { throw malformed("/snapshot") }
        return try JSONSerialization.data(withJSONObject: data)
    }

    /// The element with keyboard focus as idb-shaped JSON, nil when none has it. A password field carries no value: the runner leaves it out, and one that arrives anyway is dropped here.
    public func focused(app: String?) async throws -> Data? {
        let body: [String: Any] = app.map { ["app": $0] } ?? [:]
        guard let data = try await call("POST", "/focused", body) as? [String: Any] else { throw malformed("/focused") }
        guard let node = data["focused"] as? [String: Any] else { return nil }
        let safe = Self.withoutSecureValue(node)
        guard JSONSerialization.isValidJSONObject(safe) else { throw malformed("/focused") }
        return try JSONSerialization.data(withJSONObject: [safe])
    }

    /// A secure field, or a text field whose value is only a mask's dots, as a secure field with no value and no children.
    static func withoutSecureValue(_ node: [String: Any]) -> [String: Any] {
        var node = node
        node["children"] = [[String: Any]]()
        guard node["type"] as? String == "SecureTextField" || SecureText.isMaskDots(node["AXValue"] as? String) else { return node }
        node["AXValue"] = nil
        node["type"] = "SecureTextField"
        return node
    }

    public func tapPoint(x: Double, y: Double, app: String?) async throws {
        var body: [String: Any] = ["x": x, "y": y]
        body["app"] = app
        _ = try await call("POST", "/tap-point", body)
    }

    public func type(_ text: String, replace: Bool, app: String?) async throws {
        if InputSecrecy.keysOnly { throw IOSDeviceError.keysOnlyRefusal(text, device: DeviceID(rawValue: udid, platform: .ios)) }
        if InputSecrecy.knownFocus == .secure { throw IOSDeviceError.secureFieldRunnerRefusal(text, replace: replace, udid: udid) }
        var body: [String: Any] = ["text": text, "replace": replace]
        body["app"] = app
        do {
            _ = try await call("POST", "/type", body, timeout: Self.typeTimeout(text, replace: replace), onTimeout: .runnerStillTyping(udid, replace: replace))
        } catch let error as IOSDeviceError where error.kind == .secureFieldRefused {
            throw IOSDeviceError.secureFieldRunnerRefusal(text, replace: replace, udid: udid)
        }
    }

    /// XCTest types a few characters a second, and clearing a field for `replace` takes up to three passes of its own.
    static func typeTimeout(_ text: String, replace: Bool) -> TimeInterval {
        min(60, timeout + Double(text.count) / 5 + (replace ? 10 : 0))
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double, app: String?) async throws {
        var body: [String: Any] = ["fromX": fromX, "fromY": fromY, "toX": toX, "toY": toY, "duration": duration]
        body["app"] = app
        _ = try await call("POST", "/swipe", body, timeout: max(RunnerClient.timeout, duration + 5))
    }

    /// Whether `app` is the app in front, and the bundle id XCTest reports as active (never a remembered one).
    public func foreground(app: String) async throws -> RunnerForeground {
        let data = try await call("POST", "/foreground", ["app": app]) as? [String: Any]
        guard let data, let inFront = data["inFront"] as? Bool else { throw malformed("/foreground") }
        return RunnerForeground(
            inFront: inFront, activeBundleID: data["activeBundleId"] as? String, prompt: data["prompt"] as? String, locked: data["locked"] as? Bool, sheetsVisible: data["sheetsVisible"] as? Bool ?? true
        )
    }

    /// SpringBoard's alert and the state of `app`, without reading `app`, which an alert holds.
    public func alert(app: String) async throws -> RunnerAlert {
        guard let data = try await call("POST", "/alert", ["app": app]) as? [String: Any], let inFront = data["appInFront"] as? Bool else { throw malformed("/alert") }
        var alert: Data?
        if let node = data["alert"] as? [String: Any] {
            guard JSONSerialization.isValidJSONObject([node]) else { throw malformed("/alert") }
            alert = try JSONSerialization.data(withJSONObject: [node])
        }
        return RunnerAlert(appInFront: inFront, active: data["active"] as? [String], hosted: data["hosted"] as? String, locked: data["locked"] as? Bool ?? false, alert: alert)
    }

    /// Taps the alert's button `label`, which the runner first checks still has `frame` in an alert titled `title` over `app`.
    public func tapAlert(app: String, title: String, label: String, frame: UIFrame) async throws {
        let body: [String: Any] = [
            "app": app, "title": title, "label": label,
            "frame": ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height],
        ]
        _ = try await call("POST", "/alert-tap", body)
    }

    public func screen() async throws -> RunnerScreen {
        let data = try await call("GET", "/screen", nil) as? [String: Any]
        guard let on = data?["on"] as? Bool, let locked = data?["locked"] as? Bool else { throw malformed("/screen") }
        return RunnerScreen(on: on, locked: locked)
    }

    public func pressLock() async throws {
        _ = try await call("POST", "/lock", [:])
    }

    public func home() async throws {
        _ = try await call("POST", "/home", [:])
    }

    public func stop(timeout: TimeInterval = 2) async throws {
        _ = try await call("POST", "/stop", [:], timeout: timeout)
    }

    /// The envelope's `data`, or the runner's error as an `IOSDeviceError`; `onTimeout` names what a request the runner took but did not finish may have done.
    func call(_ method: String, _ path: String, _ body: [String: Any]?, timeout: TimeInterval = RunnerClient.timeout, onTimeout: IOSDeviceError? = nil) async throws -> Any? {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let transport = transport
        let token = token
        let udid = udid
        let response: UsbmuxHTTPResponse
        do {
            response = try await Task.detached {
                try transport.exchange(method: method, path: path, token: token, body: payload, timeout: timeout)
            }.value
        } catch UsbmuxError.timedOut {
            throw onTimeout ?? (testDevice ? IOSDeviceError.runnerTimedOutOnTestDevice(udid) : transport.error(for: .timedOut, udid: udid))
        } catch let error as UsbmuxError {
            throw transport.error(for: error, udid: udid)
        }
        return try Self.unwrap(response, path: path, udid: udid, testDevice: testDevice, app: body?["app"] as? String)
    }

    static func unwrap(_ response: UsbmuxHTTPResponse, path: String, udid: String, testDevice: Bool = false, app: String? = nil) throws -> Any? {
        if response.status == 401 {
            throw IOSDeviceError(.runnerUnavailable, "The runner on \(udid) refused Offsider's session token, so nothing was sent. Run `offsider runner stop --device \(udid)` and retry.")
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let ok = envelope["ok"] as? Bool else {
            throw IOSDeviceError(.runnerUnavailable, "The runner on \(udid) sent a reply Offsider could not read for \(path). Run `offsider runner stop --device \(udid)` and retry.")
        }
        if ok { return envelope["data"] }
        let error = envelope["error"] as? [String: Any]
        let code = error?["code"] as? String ?? "unknown"
        let message = error?["message"] as? String ?? "no detail"
        switch code {
        case "no_focus":
            throw IOSDeviceError(.noFocusedField, "No field on \(udid) has keyboard focus. Tap a text field first, then retry.")
        case "secure_field":
            throw IOSDeviceError(.secureFieldRefused, "The field with focus on \(udid) is a password field, so nothing was typed.")
        case "system_prompt":
            throw IOSDeviceError.systemPromptInFront(message, udid: udid, testDevice: testDevice, app: app)
        case "alert_changed":
            throw IOSDeviceError(.promptChanged, "The prompt on \(udid) changed before Offsider answered it (\(TerminalText.line(message, cap: 120))), so nothing was sent.")
        case "queued_too_long":
            throw IOSDeviceError(.runnerUnavailable, "The runner on \(udid) was busy for too long, so nothing was read or sent. Retry; if it persists, run `offsider doctor --device \(udid)`.")
        case "screen_locked":
            throw IOSDeviceError.screenLocked(udid)
        case "app_not_in_front":
            throw IOSDeviceError(.otherAppInFront, "The app this command may drive is not in front on \(udid), so Offsider did not read or touch it. \(ErrorAudience.current == .person ? "Open it" : "Ask the user to open it"), then retry.")
        default:
            throw IOSDeviceError(.runnerFailed, "The runner on \(udid) could not complete \(path): \(message) (\(code)). Retry; if it persists, run `offsider runner stop --device \(udid)`.")
        }
    }

    private func malformed(_ path: String) -> IOSDeviceError {
        IOSDeviceError(.runnerUnavailable, "The runner on \(udid) sent a reply Offsider could not read for \(path). Run `offsider runner stop --device \(udid)` and retry.")
    }
}
