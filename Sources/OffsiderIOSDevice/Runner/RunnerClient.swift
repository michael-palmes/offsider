import Foundation

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

/// The runner's routes, each a fresh connection through `transport`.
public struct RunnerClient: Sendable {
    public static let protocolVersion = "1"
    public static let timeout: TimeInterval = 5

    public let udid: String
    public let token: String
    let transport: any RunnerTransport

    public init(udid: String, token: String, transport: any RunnerTransport) {
        self.udid = udid
        self.token = token
        self.transport = transport
    }

    public func ping(timeout: TimeInterval = RunnerClient.timeout) async throws -> RunnerPing {
        let data = try await call("GET", "/ping", nil, timeout: timeout) as? [String: Any] ?? [:]
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

    public func tapPoint(x: Double, y: Double, app: String?) async throws {
        var body: [String: Any] = ["x": x, "y": y]
        body["app"] = app
        _ = try await call("POST", "/tap-point", body)
    }

    public func type(_ text: String, replace: Bool, app: String?) async throws {
        var body: [String: Any] = ["text": text, "replace": replace]
        body["app"] = app
        _ = try await call("POST", "/type", body)
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double, app: String?) async throws {
        var body: [String: Any] = ["fromX": fromX, "fromY": fromY, "toX": toX, "toY": toY, "duration": duration]
        body["app"] = app
        _ = try await call("POST", "/swipe", body, timeout: max(RunnerClient.timeout, duration + 5))
    }

    public func home() async throws {
        _ = try await call("POST", "/home", [:])
    }

    public func stop(timeout: TimeInterval = 2) async throws {
        _ = try await call("POST", "/stop", [:], timeout: timeout)
    }

    /// The envelope's `data`, or the runner's error as an `IOSDeviceError`.
    func call(_ method: String, _ path: String, _ body: [String: Any]?, timeout: TimeInterval = RunnerClient.timeout) async throws -> Any? {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let transport = transport
        let token = token
        let udid = udid
        let response: UsbmuxHTTPResponse
        do {
            response = try await Task.detached {
                try transport.exchange(method: method, path: path, token: token, body: payload, timeout: timeout)
            }.value
        } catch let error as UsbmuxError {
            throw transport.error(for: error, udid: udid)
        }
        return try Self.unwrap(response, path: path, udid: udid)
    }

    static func unwrap(_ response: UsbmuxHTTPResponse, path: String, udid: String) throws -> Any? {
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
            throw IOSDeviceError(.secureFieldRefused, "The focused field on \(udid) is a secure field, and Offsider does not replace its text. Clear it in the app, or type without --replace.")
        case "app_not_in_front":
            throw IOSDeviceError(.runnerFailed, "The app --app names is not in front on \(udid), so Offsider did not read or touch it. Open the app, or leave out --app to use the app in front.")
        default:
            throw IOSDeviceError(.runnerFailed, "The runner on \(udid) could not complete \(path): \(message) (\(code)). Retry; if it persists, run `offsider runner stop --device \(udid)`.")
        }
    }

    private func malformed(_ path: String) -> IOSDeviceError {
        IOSDeviceError(.runnerUnavailable, "The runner on \(udid) sent a reply Offsider could not read for \(path). Run `offsider runner stop --device \(udid)` and retry.")
    }
}
