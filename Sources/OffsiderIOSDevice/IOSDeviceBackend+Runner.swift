import Foundation
import OffsiderCore

/// Returns a runner client that has answered `/ping`; `RunnerSessionManager` in production, a fake in tests.
@MainActor
public protocol RunnerConnecting: AnyObject, Sendable {
    func connect(_ destination: RunnerDestination, deviceName: String) async throws -> RunnerClient
}

extension RunnerSessionManager: RunnerConnecting {}

extension IOSDeviceBackend {
    /// The app `--app` named; the runner reads it instead of the frontmost app and remembers it.
    public var targetApp: String? {
        get { state.targetApp }
        set { state.targetApp = newValue }
    }

    /// One connection per device per command, started or reused through the session file.
    func runner(for id: DeviceID) async throws -> RunnerClient {
        let udid = id.rawValue
        if let client = state.runners[udid] { return client }
        let booted = try await requireBootedDevice(id)
        let connector = try await runnerConnector()
        let client = try await host.timing.measure("runner") {
            try await connector.connect(.device(udid: udid), deviceName: DeviceName.display(udid, label: booted.name))
        }
        state.runners[udid] = client
        return client
    }

    func runnerConnector() async throws -> any RunnerConnecting {
        if let connector = state.connector ?? host.runnerConnector { return connector }
        guard let source = host.runnerSource else {
            throw IOSDeviceError(.runnerBuildFailed, "The Offsider runner source is missing from this installation. Reinstall Offsider.")
        }
        let xcode = try await host.devicectl.locateXcode()
        let log = log
        let builder = XcodeRunnerBuilder(
            source: source,
            cacheRoot: XcodeRunnerBuilder.defaultCacheRoot(home: host.homeDirectory),
            xcode: xcode,
            environment: host.environment,
            signedInTeams: IOSDeviceDoctorProbe.signedInTeams,
            notice: { log(.notice, $0) }
        )
        let manager = RunnerSessionManager(
            store: RunnerSessionStore(root: host.privateRoot),
            builder: builder,
            environment: host.environment,
            developerDirectory: xcode.developerDirectory,
            log: log,
            usbmux: host.usbmux
        )
        state.connector = manager
        return manager
    }

    func runnerInputSession(for id: DeviceID) async throws -> any InputSession {
        RunnerInputSession(device: id, client: try await runner(for: id)) { [weak self] in self?.targetApp }
    }

    /// The runner serves hosts below the HID floor, and the text the HID keyboard cannot type.
    func installRunnerHooks() {
        input.fallbackInputSession = { [unowned self] id in try await self.runnerInputSession(for: id) }
        input.runnerText = RunnerTextTypist(backend: self)
    }
}

/// Unicode and `--replace` text for the HID session, through the runner.
@MainActor
final class RunnerTextTypist: RunnerTextTyping {
    private unowned let backend: IOSDeviceBackend

    init(backend: IOSDeviceBackend) {
        self.backend = backend
    }

    func typeText(_ text: String, on device: DeviceID) async throws {
        try await backend.runner(for: device).type(text, replace: false, app: backend.targetApp)
    }

    func replaceText(_ text: String, on device: DeviceID) async throws {
        try await backend.runner(for: device).type(text, replace: true, app: backend.targetApp)
    }
}

/// Input through the runner's XCUITest calls, for hosts without CoreDevice HID: taps, swipes, Home and text the keyboard cannot send.
@MainActor
final class RunnerInputSession: TextInputSession {
    static let hidHint = "install Xcode 27 for HID input"

    let device: DeviceID
    let client: RunnerClient
    private let targetApp: @MainActor () -> String?

    /// `targetApp` is read at each call, so a batch step's `--app` reaches a session opened before it.
    init(device: DeviceID, client: RunnerClient, targetApp: @escaping @MainActor () -> String?) {
        self.device = device
        self.client = client
        self.targetApp = targetApp
    }

    var app: String? { targetApp() }

    func perform(_ event: InputEvent) async throws {
        switch event {
        case .tapAt(let x, let y):
            try await client.tapPoint(x: x, y: y, app: app)
        case .swipe(let x, let yStart, let xEnd, let yEnd, _, let duration):
            try await client.swipe(fromX: x, fromY: yStart, toX: xEnd, toY: yEnd, duration: duration, app: app)
        case .shortButtonPress(.home), .button(.up, .home):
            try await client.home()
        case .button(.down, .home):
            break
        case .delay(let seconds):
            try await Task.sleep(for: .seconds(seconds))
        case .composite(let events):
            for event in events { try await perform(event) }
        case .touch:
            throw refusal("Separate touch down and up events")
        case .twoFingerTouch:
            throw DeviceSessionLowering.twoFingers
        case .keyboard, .shortKeyPress:
            throw refusal("Key presses")
        case .button(_, let button), .shortButtonPress(let button):
            throw refusal("The \(button.rawValue) button")
        }
    }

    /// One XCUITest tap; the runner cannot hold a touch down between calls.
    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        if let preDelay, preDelay > 0 { try await Task.sleep(for: .seconds(preDelay)) }
        try await client.tapPoint(x: point.x, y: point.y, app: app)
        if let postDelay, postDelay > 0 { try await Task.sleep(for: .seconds(postDelay)) }
    }

    /// Text the HID keyboard would send (plain ASCII) is refused here; anything else goes through XCUITest.
    func typeText(_ text: String) async throws {
        if text.allSatisfy(\.isASCII) {
            throw refusal("Typing plain ASCII text")
        }
        try await client.type(text, replace: false, app: app)
    }

    func replaceText(_ text: String) async throws {
        try await client.type(text, replace: true, app: app)
    }

    func close() async {}

    private func refusal(_ feature: String) -> IOSDeviceError {
        IOSDeviceError(
            .xcodeTooOld,
            "\(feature) on \(device.rawValue) needs CoreDevice HID input, which this Xcode does not provide. Taps, swipes, the Home button, `type --replace` and non-ASCII text work through the runner.",
            hint: Self.hidHint
        )
    }
}
