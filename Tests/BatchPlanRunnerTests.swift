import Foundation
import OffsiderCore
import Testing
@testable import Offsider

struct FakeInputSessionError: Error, Equatable {}

@MainActor
final class RecordingInputSession: InputSession {
    enum Call: Equatable {
        case perform(InputEvent)
        case physicalTap(x: Double, y: Double, preDelay: Double?, postDelay: Double?)
    }

    let device = DeviceID(rawValue: "recording", platform: .ios)
    private let failingEvent: InputEvent?
    private let failure: any Error
    private(set) var calls: [Call] = []
    private(set) var isClosed = false

    init(failingOn failingEvent: InputEvent? = nil, with failure: any Error = FakeInputSessionError()) {
        self.failingEvent = failingEvent
        self.failure = failure
    }

    func perform(_ event: InputEvent) async throws {
        calls.append(.perform(event))
        if event == failingEvent {
            throw failure
        }
    }

    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        calls.append(.physicalTap(x: point.x, y: point.y, preDelay: preDelay, postDelay: postDelay))
    }

    func close() async {
        isClosed = true
    }
}

@MainActor
final class RecordingTextInputSession: TextInputSession {
    enum Call: Equatable {
        case perform(InputEvent)
        case typeText(String)
        case replaceText(String)
    }

    let device = DeviceID(rawValue: "emulator-5556", platform: .android)
    private(set) var calls: [Call] = []

    func perform(_ event: InputEvent) async throws {
        calls.append(.perform(event))
    }

    func typeText(_ text: String) async throws {
        calls.append(.typeText(text))
    }

    func replaceText(_ text: String) async throws {
        calls.append(.replaceText(text))
    }

    func close() async {}
}

@Suite("Batch Plan Runner Tests")
@MainActor
struct BatchPlanRunnerTests {
    private let first = InputEvent.tapAt(x: 10, y: 20)
    private let second = InputEvent.shortKeyPress(40)
    private let third = InputEvent.delay(0.5)

    private func run(_ primitives: [BatchPrimitive], on session: RecordingInputSession) async throws {
        try await BatchPlanRunner(session: session, logger: OffsiderLogger()).run(BatchPlan(primitives: primitives))
    }

    @Test("a lone mergeable event is sent bare")
    func loneMergeableEventIsSentBare() async throws {
        let session = RecordingInputSession()

        try await run([.hidMergeable(first)], on: session)

        #expect(session.calls == [.perform(first)])
    }

    @Test("consecutive mergeable events are sent as one composite")
    func consecutiveMergeableEventsAreSentAsOneComposite() async throws {
        let session = RecordingInputSession()

        try await run([.hidMergeable(first), .hidMergeable(second), .hidMergeable(third)], on: session)

        #expect(session.calls == [.perform(.composite([first, second, third]))])
    }

    @Test("a barrier flushes pending events before it is sent alone")
    func barrierFlushesPendingEventsFirst() async throws {
        let session = RecordingInputSession()

        try await run([.hidMergeable(first), .hidBarrier(second), .hidMergeable(third)], on: session)

        #expect(session.calls == [.perform(first), .perform(second), .perform(third)])
    }

    @Test("a host sleep flushes pending events")
    func hostSleepFlushesPendingEvents() async throws {
        let session = RecordingInputSession()

        try await run([.hidMergeable(first), .hostSleep(0), .hidMergeable(second)], on: session)

        #expect(session.calls == [.perform(first), .perform(second)])
    }

    @Test("a physical tap flushes pending events and taps once")
    func physicalTapFlushesThenTapsOnce() async throws {
        let session = RecordingInputSession()

        try await run([
            .hidMergeable(first),
            .physicalTap(point: (x: 30, y: 40), preDelay: 0.25, postDelay: nil),
            .hidMergeable(second)
        ], on: session)

        #expect(session.calls == [
            .perform(first),
            .physicalTap(x: 30, y: 40, preDelay: 0.25, postDelay: nil),
            .perform(second)
        ])
    }

    @Test("a failure stops the plan without resending earlier events")
    func failureStopsPlanWithoutResending() async throws {
        let session = RecordingInputSession(failingOn: second)

        await #expect(throws: FakeInputSessionError.self) {
            try await run([.hidBarrier(first), .hidBarrier(second), .hidMergeable(third)], on: session)
        }

        #expect(session.calls == [.perform(first), .perform(second)])
    }

    @Test("a text step flushes pending events, then types the whole string once")
    func textStepFlushesAndTypesOnce() async throws {
        let session = RecordingTextInputSession()

        try await BatchPlanRunner(session: session, logger: OffsiderLogger())
            .run(BatchPlan(primitives: [.hidMergeable(first), .text("héllo world", replace: false), .hidMergeable(second)]))

        #expect(session.calls == [.perform(first), .typeText("héllo world"), .perform(second)])
    }

    @Test("a replacing text step flushes pending events, then replaces the field's text once")
    func replacingTextStepFlushesAndReplacesOnce() async throws {
        let session = RecordingTextInputSession()

        try await BatchPlanRunner(session: session, logger: OffsiderLogger())
            .run(BatchPlan(primitives: [.hidMergeable(first), .text("bye", replace: true), .text("", replace: true)]))

        #expect(session.calls == [.perform(first), .replaceText("bye"), .replaceText("")])
    }

    @Test("a text step on a session that cannot type text fails without sending it as keys")
    func textStepNeedsTextSession() async throws {
        let session = RecordingInputSession()

        await #expect(throws: CLIError.self) {
            try await run([.hidMergeable(first), .text("hello", replace: false)], on: session)
        }
        #expect(session.calls == [.perform(first)])
    }
}
