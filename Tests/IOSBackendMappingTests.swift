import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@MainActor
private final class EventOnlyInputSession: InputSession {
    let device = DeviceID(rawValue: "events", platform: .ios)
    private let failingEvent: InputEvent?
    private(set) var events: [InputEvent] = []

    init(failingOn failingEvent: InputEvent? = nil) {
        self.failingEvent = failingEvent
    }

    func perform(_ event: InputEvent) async throws {
        events.append(event)
        if event == failingEvent {
            throw FakeInputSessionError()
        }
    }

    func close() async {}
}

@MainActor
private final class StubBackend: DeviceBackend {
    let session: RecordingInputSession
    private(set) var openedDevices: [DeviceID] = []

    init(session: RecordingInputSession) {
        self.session = session
    }

    var platform: DevicePlatform { .ios }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Stub") }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree { UITree(platform: platform, device: id.rawValue, roots: []) }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] { points }
    func openInputSession(for id: DeviceID) async throws -> any InputSession {
        openedDevices.append(id)
        return session
    }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
}

@Suite("iOS Backend Mapping Tests")
@MainActor
struct IOSBackendMappingTests {
    @Test("detached touch steps map to broker primitives in order")
    func detachedTouchStepsMapToBrokerPrimitives() {
        let steps: [DetachedTouchStep] = [.down(x: 12.5, y: 42), .hold(0.25), .up(x: 13, y: 43.5)]

        #expect(steps.map(\.brokerPrimitive) == [
            .touch(.down, x: 12.5, y: 42),
            .delay(0.25),
            .touch(.up, x: 13, y: 43.5)
        ])
    }

    @Test("a delayed event is the bare event when neither delay is positive")
    func delayedEventIsBareWithoutPositiveDelays() {
        let tap = InputEvent.tapAt(x: 1, y: 2)

        #expect(InputEvent.delayed(tap, pre: nil, post: nil) == tap)
        #expect(InputEvent.delayed(tap, pre: 0, post: 0) == tap)
        #expect(InputEvent.delayed(tap, pre: nil, post: 0) == tap)
    }

    @Test("a delayed event wraps positive delays around the event")
    func delayedEventWrapsPositiveDelays() {
        let tap = InputEvent.tapAt(x: 1, y: 2)

        #expect(InputEvent.delayed(tap, pre: 0.5, post: 1) == .composite([.delay(0.5), tap, .delay(1)]))
        #expect(InputEvent.delayed(tap, pre: 0.5, post: nil) == .composite([.delay(0.5), tap]))
        #expect(InputEvent.delayed(tap, pre: 0, post: 2) == .composite([tap, .delay(2)]))
    }

    @Test("a composite drag holds, moves in even steps, holds and releases at the end")
    func compositeDragMatchesTheTouchSequence() throws {
        let drag = try InputEvent.compositeDrag(
            from: (x: 0, y: 0),
            to: (x: 100, y: 200),
            duration: 1,
            steps: 2,
            initialHold: 0.05,
            finalHold: 0.2
        )

        #expect(drag == .composite([
            .touch(direction: .down, x: 0, y: 0),
            .delay(0.05),
            .delay(0.5),
            .touch(direction: .down, x: 50, y: 100),
            .delay(0.5),
            .touch(direction: .down, x: 100, y: 200),
            .delay(0.2),
            .touch(direction: .up, x: 100, y: 200)
        ]))
    }

    @Test("a composite drag rejects invalid timing and step counts")
    func compositeDragRejectsInvalidArguments() {
        let start = (x: 0.0, y: 0.0)
        let end = (x: 10.0, y: 10.0)

        let negativeDuration = #expect(throws: CLIError.self) {
            try InputEvent.compositeDrag(from: start, to: end, duration: -1, steps: 1, initialHold: 0, finalHold: 0)
        }
        let noSteps = #expect(throws: CLIError.self) {
            try InputEvent.compositeDrag(from: start, to: end, duration: 1, steps: 0, initialHold: 0, finalHold: 0)
        }
        let negativeHold = #expect(throws: CLIError.self) {
            try InputEvent.compositeDrag(from: start, to: end, duration: 1, steps: 1, initialHold: 0, finalHold: -0.1)
        }

        #expect(negativeDuration?.userFacingDescription == "Drag duration must be non-negative.")
        #expect(noSteps?.userFacingDescription == "Drag steps must be greater than 0.")
        #expect(negativeHold?.userFacingDescription == "Drag hold durations must be non-negative.")
    }

    @Test("the default physical tap sends a touch down then a touch up")
    func defaultPhysicalTapSendsDownThenUp() async throws {
        let session = EventOnlyInputSession()

        try await session.performPhysicalTap(at: (x: 5, y: 6), preDelay: nil, postDelay: nil)

        #expect(session.events == [
            .touch(direction: .down, x: 5, y: 6),
            .touch(direction: .up, x: 5, y: 6)
        ])
    }

    @Test("the default physical tap only retries the touch up after a failure following the down")
    func defaultPhysicalTapNeverReplaysTouchDown() async throws {
        let touchUp = InputEvent.touch(direction: .up, x: 5, y: 6)
        let session = EventOnlyInputSession(failingOn: touchUp)

        await #expect(throws: FakeInputSessionError.self) {
            try await session.performPhysicalTap(at: (x: 5, y: 6), preDelay: nil, postDelay: nil)
        }

        #expect(session.events == [.touch(direction: .down, x: 5, y: 6), touchUp, touchUp])
    }

    @Test("the default physical tap sends no touch up when the down fails")
    func defaultPhysicalTapSkipsTouchUpWhenDownFails() async throws {
        let touchDown = InputEvent.touch(direction: .down, x: 5, y: 6)
        let session = EventOnlyInputSession(failingOn: touchDown)

        await #expect(throws: FakeInputSessionError.self) {
            try await session.performPhysicalTap(at: (x: 5, y: 6), preDelay: nil, postDelay: nil)
        }

        #expect(session.events == [touchDown])
    }

    @Test("performing one event closes its session after success and after failure")
    func performingOneEventClosesItsSession() async throws {
        let device = DeviceID(rawValue: "SIM", platform: .ios)
        let succeeding = StubBackend(session: RecordingInputSession())
        try await succeeding.perform(.shortKeyPress(40), on: device)
        #expect(succeeding.session.calls == [.perform(.shortKeyPress(40))])
        #expect(succeeding.session.isClosed)
        #expect(succeeding.openedDevices == [device])

        let failing = StubBackend(session: RecordingInputSession(failingOn: .shortKeyPress(40)))
        await #expect(throws: FakeInputSessionError.self) {
            try await failing.perform(.shortKeyPress(40), on: device)
        }
        #expect(failing.session.isClosed)
    }

    @Test("a UUID routes to the iOS backend in canonical uppercase")
    func uuidRoutesToIOS() async throws {
        let route = try await DeviceRouter.route(" abcdef00-0000-4000-8000-00000000abcd ", logger: OffsiderLogger())

        #expect(route.backend is IOSBackend)
        #expect(route.backend.platform == .ios)
        #expect(route.device == DeviceID(rawValue: "ABCDEF00-0000-4000-8000-00000000ABCD", platform: .ios))
    }

    @Test("Android serials and AVD names are refused in this build", arguments: ["emulator-5554", "Pixel_9_API_37"])
    func androidIDsAreRefused(id: String) async {
        let error = await #expect(throws: CLIError.self) {
            _ = try await DeviceRouter.route(id, logger: OffsiderLogger())
        }
        let message = error?.userFacingDescription ?? ""

        #expect(message.hasPrefix("Device \(id) "))
        #expect(message.contains("Android emulators are not supported by this build yet."))
        #expect(message.contains("`offsider list-devices`"))
    }

    @Test("empty and unrecognised IDs point to list-devices", arguments: ["", "  ", "192.168.1.5:5555"])
    func unusableIDsPointToListDevices(id: String) async {
        let error = await #expect(throws: CLIError.self) {
            _ = try await DeviceRouter.route(id, logger: OffsiderLogger())
        }
        let message = error?.userFacingDescription ?? ""

        #expect(message.contains("Run `offsider list-devices` to find device IDs."))
        #expect(!message.contains("Android"))
    }
}
