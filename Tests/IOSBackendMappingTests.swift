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
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Stub") }
    func accessibilityJSON(for id: DeviceID, point: AccessibilityPoint?) async throws -> Data { Data("[]".utf8) }
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        roots: [AccessibilityElement]?,
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

    @Test("every device ID routes to the iOS backend unchanged")
    func everyDeviceIDRoutesToIOSUnchanged() async throws {
        let route = try await DeviceRouter.route(" SIM-UDID ", logger: OffsiderLogger())

        #expect(route.backend is IOSBackend)
        #expect(route.backend.platform == .ios)
        #expect(route.device == DeviceID(rawValue: " SIM-UDID ", platform: .ios))
    }
}
