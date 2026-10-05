import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

/// Hands the backend clients over fake links, or a failure; counts connections.
@MainActor
final class FakeSessionConnector: DeviceSessionConnecting {
    let link: FakeSessionLink?
    let failure: IOSDeviceError?
    let live: Bool
    private(set) var connections = 0

    init(link: FakeSessionLink?, failure: IOSDeviceError? = nil, live: Bool = false) {
        self.link = link
        self.failure = failure
        self.live = live
    }

    func connect(udid: String) async throws -> DeviceSessionClient {
        connections += 1
        if let failure { throw failure }
        guard let link else { throw IOSDeviceError(.sessionFailed, "No link.") }
        let client = DeviceSessionClient(udid: udid, link: link)
        try await client.ping()
        return client
    }

    func existing(udid: String) async -> DeviceSessionClient? {
        guard live, let link else { return nil }
        let client = DeviceSessionClient(udid: udid, link: link)
        _ = try? await client.ping()
        return client
    }
}

/// Records each runner input event; refuses separate touches as the runner does.
@MainActor
final class RecordingRunnerSession: InputSession {
    let device: DeviceID
    private(set) var events: [InputEvent] = []
    private(set) var physicalTaps = 0

    init(device: DeviceID) { self.device = device }

    func perform(_ event: InputEvent) async throws { events.append(event) }

    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        physicalTaps += 1
    }

    func close() async {}
}

@MainActor
final class RecordingRunnerText: RunnerTextTyping {
    private(set) var calls: [String] = []

    func typeText(_ text: String, on device: DeviceID) async throws { calls.append("type \(text.count)") }
    func replaceText(_ text: String, on device: DeviceID) async throws { calls.append("replace \(text.count)") }
}

@Suite("iOS device input routing")
@MainActor
struct IOSDeviceInputRoutingTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    static func backend(version: String?, connector: FakeSessionConnector?, runner: RecordingRunnerSession?) throws -> IOSDeviceBackend {
        var host = IOSDeviceHost.fake(try FakeDevicectl.listing("devicectl-list-xcode26.json"))
        host.sessionConnector = connector
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        backend.input.coreDeviceVersion = { version.flatMap(CoreDeviceVersion.init) }
        backend.input.fallbackInputSession = runner.map { session in { _ in session } }
        return backend
    }

    @Test("on an Xcode 27 host the broker sends taps, swipes, buttons and keys, and the runner is never opened")
    func brokerFirst() async throws {
        let link = FakeSessionLink.broker(udid: IOSDeviceFixtures.phone)
        let runner = RecordingRunnerSession(device: Self.phone)
        let session = try await Self.backend(version: "651.13.4", connector: FakeSessionConnector(link: link), runner: runner).openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 10, y: 20))
        try await session.perform(.shortButtonPress(.home))
        try await session.perform(.shortKeyPress(4))
        #expect(link.requests.dropFirst().map(\.op) == ["touch", "press", "keys"])
        #expect(runner.events.isEmpty)
    }

    @Test("a broker without touch input leaves touches to the runner and keeps buttons")
    func runnerTouches() async throws {
        let link = FakeSessionLink.broker(udid: IOSDeviceFixtures.phone, touch: false)
        let runner = RecordingRunnerSession(device: Self.phone)
        let session = try await Self.backend(version: "651.13.4", connector: FakeSessionConnector(link: link), runner: runner).openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 10, y: 20))
        try await session.perform(.shortButtonPress(.lock))
        #expect(runner.events == [.tapAt(x: 10, y: 20)])
        #expect(link.requests.map(\.op) == ["ping", "press"])
        let keys = await #expect(throws: IOSDeviceError.self) { try await session.perform(.shortKeyPress(4)) }
        #expect(keys?.reason == .notSupported)
    }

    @Test("when the broker cannot start, the runner takes touches and Home; other buttons report the broker's failure")
    func brokerDown() async throws {
        let failure = IOSDeviceError(.sessionFailed, "The device session did not start.")
        let runner = RecordingRunnerSession(device: Self.phone)
        let session = try await Self.backend(version: "651.13.4", connector: FakeSessionConnector(link: nil, failure: failure), runner: runner).openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 1, y: 1))
        try await session.perform(.shortButtonPress(.home))
        let lock = await #expect(throws: IOSDeviceError.self) { try await session.perform(.shortButtonPress(.lock)) }
        #expect(lock == failure)
        #expect(runner.events == [.tapAt(x: 1, y: 1), .shortButtonPress(.home)])
    }

    @Test("below CoreDevice 636 the runner serves input; with no runner it is xcode_too_old, and no broker is asked")
    func belowFloor() async throws {
        let connector = FakeSessionConnector(link: FakeSessionLink.broker(udid: IOSDeviceFixtures.phone))
        let runner = RecordingRunnerSession(device: Self.phone)
        let session = try await Self.backend(version: "518.24", connector: connector, runner: runner).openInputSession(for: Self.phone)
        #expect(session === runner)
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await Self.backend(version: "518.24", connector: connector, runner: nil).openInputSession(for: Self.phone)
        }
        #expect(error?.reason == .xcodeTooOld)
        #expect(connector.connections == 0)
    }

    @Test("a whole detached touch reaches the broker as one request with its hold inside")
    func detachedTouch() async throws {
        let link = FakeSessionLink.broker(udid: IOSDeviceFixtures.phone)
        let backend = try Self.backend(version: "651.13.4", connector: FakeSessionConnector(link: link), runner: nil)
        try await backend.sendDetachedTouch([.down(x: 5, y: 6), .hold(0.2), .up(x: 5, y: 6)], to: Self.phone)
        #expect(link.requests.last == .touch([.touch(.down, x: 5, y: 6), .wait(0.2), .touch(.up, x: 5, y: 6)]))
    }

    @Test("key and button holds reach the broker as one request each, timed inside it")
    func holds() async throws {
        let link = FakeSessionLink.broker(udid: IOSDeviceFixtures.phone)
        let session = try await Self.backend(version: "651.13.4", connector: FakeSessionConnector(link: link), runner: nil).openInputSession(for: Self.phone)
        try await session.perform(.composite([.keyboard(direction: .down, keyCode: 4), .delay(1), .keyboard(direction: .up, keyCode: 4)]))
        try await session.perform(.composite([.button(direction: .down, button: .home), .delay(2), .button(direction: .up, button: .home)]))
        #expect(Array(link.requests.dropFirst()) == [
            .keys([.key(4, down: true), .wait(1), .key(4, down: false)]),
            .press(usagePage: DTUHIDMessage.consumerUsagePage, usageCode: 0x40, hold: 2),
        ])
    }

    @Test("US text types through broker keys; other text and --replace go to the runner")
    func text() async throws {
        let link = FakeSessionLink.broker(udid: IOSDeviceFixtures.phone)
        let backend = try Self.backend(version: "651.13.4", connector: FakeSessionConnector(link: link), runner: RecordingRunnerSession(device: Self.phone))
        let runnerText = RecordingRunnerText()
        backend.input.runnerText = runnerText
        let session = try #require(try await backend.openInputSession(for: Self.phone) as? any TextInputSession)
        try await session.typeText("hi")
        try await session.typeText("café")
        try await session.replaceText("ab")
        #expect(link.requests.last == .keys([.key(11, down: true), .key(11, down: false), .key(12, down: true), .key(12, down: false)]))
        #expect(runnerText.calls == ["type 4", "replace 2"])
    }

    @Test("an element in a Stage Manager window cannot be tapped from its frames; a full-screen app can")
    func stageManager() {
        func tree(_ width: Double, _ height: Double) -> UITree {
            UITree(platform: .ios, device: "U", roots: [UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: width, height: height), native: .ios(IOSNativeAttributes()))])
        }
        #expect(IOSDeviceBackend.isWindowed(tree(704, 864.5), screenWidth: 1376, screenHeight: 1032))
        #expect(!IOSDeviceBackend.isWindowed(tree(1376, 1032), screenWidth: 1376, screenHeight: 1032))
        #expect(!IOSDeviceBackend.isWindowed(tree(1032, 1376), screenWidth: 1376, screenHeight: 1032))
    }
}

@Suite("iOS device screenshot through the session")
@MainActor
struct IOSDeviceSessionScreenshotTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    @Test("the broker's frame is the screenshot, and devicectl never captures")
    func fromStream() async throws {
        let devicectl = try IOSDeviceScreenTests.devicectl(capture: IOSDeviceScreenTests.png)
        var host = IOSDeviceHost.fake(devicectl)
        host.sessionConnector = FakeSessionConnector(link: FakeSessionLink.broker(udid: IOSDeviceFixtures.phone, frame: Data([0x89, 0x50])))
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        backend.input.coreDeviceVersion = { CoreDeviceVersion("651.13.4") }
        #expect(try await backend.screenshotPNG(for: Self.phone) == Data([0x89, 0x50]))
        #expect(!devicectl.calls.contains { $0.contains("capture") })
    }

    @Test("when the stream cannot serve a frame, devicectl captures it, with one notice per command")
    func fallback() async throws {
        let devicectl = try IOSDeviceScreenTests.devicectl(capture: IOSDeviceScreenTests.png)
        var host = IOSDeviceHost.fake(devicectl)
        let noGUI = IOSDeviceError(.streamNeedsGUISession, "No desktop session.")
        let link = FakeSessionLink { request in
            if case .frame = request { return (.failure(id: 1, noGUI), nil) }
            var reply = DeviceSessionReply(id: 1)
            reply.protocol = DeviceSessionWire.protocolVersion
            reply.udid = IOSDeviceFixtures.phone
            return (reply, nil)
        }
        host.sessionConnector = FakeSessionConnector(link: link)
        let notices = LineSink()
        let backend = IOSDeviceBackend(host: host) { level, message in if level == .notice { notices.append(message) } }
        backend.input.coreDeviceVersion = { CoreDeviceVersion("651.13.4") }
        #expect(try await backend.screenshotPNG(for: Self.phone) == IOSDeviceScreenTests.png)
        #expect(try await backend.screenshotPNG(for: Self.phone) == IOSDeviceScreenTests.png)
        #expect(notices.values.count == 1)
        #expect(notices.values.first?.contains("No desktop session.") == true)
    }
}
