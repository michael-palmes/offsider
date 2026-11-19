import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A session that stays valid until the test ends it, recording each invalidate.
private final class FakeSession: HeldAccessibilitySession, @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private(set) var invalidations = 0

    var isValid: Bool { lock.withLock { alive } }

    func die() { lock.withLock { alive = false } }

    func invalidate() {
        lock.withLock {
            alive = false
            invalidations += 1
        }
    }
}

/// Hands out the next fake session for each open, counting opens.
private final class Opener: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [FakeSession] = []
    var fails = false

    func open() -> (any HeldAccessibilitySession)? {
        lock.withLock {
            guard !fails else { return nil }
            let session = FakeSession()
            opened.append(session)
            return session
        }
    }

    var count: Int { lock.withLock { opened.count } }
}

private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite("Accessibility hold")
struct AccessibilityHoldTests {
    @Test("the broker opens one session in the background, and answers yes only while it is valid")
    func heldWhileValid() async {
        let opener = Opener()
        let hold = BrokerAccessibilityHold(open: { opener.open() }, log: { _ in })
        #expect(!hold.isHeld(reopening: false))
        hold.start()
        hold.start()
        await waitUntil { hold.isHeld(reopening: false) }
        #expect(hold.isHeld())
        #expect(opener.count == 1)
        hold.close()
    }

    @Test("a session that dies is dropped and answers no, then is opened again, no sooner than the wait")
    func deadSessionIsReopened() async throws {
        let opener = Opener()
        let hold = BrokerAccessibilityHold(open: { opener.open() }, reopenAfter: .milliseconds(200), log: { _ in })
        hold.start()
        await waitUntil { hold.isHeld(reopening: false) }
        let first = try #require(opener.opened.first)
        first.die()
        #expect(!hold.isHeld())
        #expect(first.invalidations == 1)
        #expect(opener.count == 1)
        await waitUntil { hold.isHeld() }
        #expect(opener.count == 2)
        hold.close()
    }

    @Test("a simulator that refuses a session is tried once per wait, and nothing is held")
    func refusedSessionIsNotRetriedAtOnce() async {
        let opener = Opener()
        opener.fails = true
        let hold = BrokerAccessibilityHold(open: { opener.open() }, log: { _ in })
        hold.start()
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<5 { #expect(!hold.isHeld()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!hold.isHeld(reopening: false))
        hold.close()
    }

    @Test("closing ends the session, a session still opening is ended as it arrives, and nothing opens after")
    func closeReleasesEverything() async throws {
        let opener = Opener()
        let gate = DispatchSemaphore(value: 0)
        let hold = BrokerAccessibilityHold(open: {
            gate.wait()
            return opener.open()
        }, reopenAfter: .zero, log: { _ in })
        hold.start()
        let closing = Task.detached { hold.close() }
        try await Task.sleep(for: .milliseconds(50))
        await closing.value
        gate.signal()
        await waitUntil { opener.opened.first?.invalidations == 1 }
        let late = try #require(opener.opened.first)
        #expect(late.invalidations == 1)
        hold.start()
        #expect(!hold.isHeld())
        try await Task.sleep(for: .milliseconds(50))
        #expect(opener.count == 1)
    }

    @Test("an empty read after trusting the hold makes every later read in the command bootstrap again")
    @MainActor
    func emptyReadEndsTrust() {
        let udid = "00000000-0000-0000-0000-000000000001"
        defer { FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: udid) }
        AccessibilityHold.trust(udid: udid, token: "a")
        #expect(FBSimulatorControlFrameworkLoader.isAccessibilityHeld(forSimulatorUDID: udid))
        AccessibilityHold.readCameBackEmpty(udid: udid)
        #expect(!FBSimulatorControlFrameworkLoader.isAccessibilityHeld(forSimulatorUDID: udid))
        #expect(!AccessibilityHold.isTrusted(udid: udid))
    }

    @Test("a read made while trusting the hold is kept only when the broker still names the same live session afterwards")
    @MainActor
    func readIsConfirmedAfterwards() async throws {
        let udid = "00000000-0000-0000-0000-000000000001"
        defer { FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: udid) }
        var reads: [Bool] = []
        let read = { () async throws -> Bool in
            let held = FBSimulatorControlFrameworkLoader.isAccessibilityHeld(forSimulatorUDID: udid)
            reads.append(held)
            return held
        }

        AccessibilityHold.trust(udid: udid, token: "a")
        #expect(try await AccessibilityHold.reading(udid: udid, confirm: { _ in "a" }, read) == true)
        #expect(reads == [true])

        reads = []
        #expect(try await AccessibilityHold.reading(udid: udid, confirm: { _ in "b" }, read) == false)
        #expect(reads == [true, false])
        #expect(!AccessibilityHold.isTrusted(udid: udid))

        reads = []
        AccessibilityHold.trust(udid: udid, token: "a")
        #expect(try await AccessibilityHold.reading(udid: udid, confirm: { _ in nil }, read) == false)
        #expect(reads == [true, false])

        reads = []
        var confirmed = 0
        _ = try await AccessibilityHold.reading(udid: udid, confirm: { _ in confirmed += 1; return "a" }, read)
        #expect(reads == [false] && confirmed == 0)
    }

    @Test("a read that stopped trusting the hold on an empty answer keeps its own result, with no second read and no ask")
    @MainActor
    func emptyReadInsideIsReadAgain() async throws {
        let udid = "00000000-0000-0000-0000-000000000001"
        defer { FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: udid) }
        AccessibilityHold.trust(udid: udid, token: "a")
        var reads = 0
        var confirmed = 0
        _ = try await AccessibilityHold.reading(udid: udid, confirm: { _ in confirmed += 1; return "a" }) {
            reads += 1
            if reads == 1 { AccessibilityHold.readCameBackEmpty(udid: udid) }
        }
        #expect(reads == 1 && confirmed == 0)
    }

    @Test("a read that finds no accessibility service while trusting the hold tries again with its own session")
    @MainActor
    func startupFailureEndsTrust() async throws {
        let udid = "00000000-0000-0000-0000-000000000001"
        defer { FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: udid) }
        AccessibilityHold.trust(udid: udid, token: "a")
        var held: [Bool] = []
        let result = try await AccessibilityFetcher.retryingStartupFailure(simulatorUDID: udid, frontmost: true, logger: OffsiderLogger(), sleep: { _ in }) { () async throws -> String in
            held.append(FBSimulatorControlFrameworkLoader.isAccessibilityHeld(forSimulatorUDID: udid))
            if held.count == 1 { throw FBAccessibilityError.noTranslationObject }
            return "tree"
        }
        #expect(result == "tree")
        #expect(held == [true, false])
    }

    @Test("a session opened after one died gets another name, so a command told of the first does not trust the second")
    func reopenedSessionHasAnotherName() async throws {
        let opener = Opener()
        let hold = BrokerAccessibilityHold(open: { opener.open() }, reopenAfter: .zero, log: { _ in })
        hold.start()
        await waitUntil { hold.isHeld(reopening: false) }
        let first = try #require(hold.heldToken(reopening: false))
        #expect(hold.heldToken() == first)
        opener.opened.first?.die()
        #expect(hold.heldToken() == nil)
        await waitUntil { hold.isHeld(reopening: false) }
        let second = try #require(hold.heldToken(reopening: false))
        #expect(second != first)
        hold.close()
        #expect(hold.heldToken(reopening: false) == nil)
    }

    @Test("an empty whole-screen read is reported before the next try, and a full one is not")
    @MainActor
    func emptyFrontmostReadIsReported() async throws {
        let empty = Data(#"[{"type": "Application", "AXLabel": "App", "children": []}]"#.utf8)
        let full = Data(#"[{"type": "Application", "AXLabel": "App", "children": [{"type": "Button", "AXLabel": "Home"}]}]"#.utf8)
        var responses = [empty, full]
        var reported = 0
        let data = try await AccessibilityFetcher.readingFrontmostTree(onEmpty: { reported += 1 }, fetch: { _ in responses.removeFirst() }, wait: { _ in })
        #expect(data == full)
        #expect(reported == 1)
    }

    @Test("an empty screen-sized point answer is reported before the next try")
    @MainActor
    func emptyPointReadIsReported() async throws {
        let fallback = try JSONSerialization.data(withJSONObject: ["type": "Group", "role": "AXGroup", "frame": ["x": 0, "y": 0, "width": 402, "height": 874]])
        let button = try JSONSerialization.data(withJSONObject: ["type": "Button", "role": "AXButton", "frame": ["x": 16, "y": 62, "width": 44, "height": 44]])
        var responses = [fallback, button]
        var reported = 0
        let data = try await AccessibilityFetcher.retryingTransientPointFallback(
            at: AccessibilityPoint(x: 38, y: 84), onEmpty: { reported += 1 }, fetch: { responses.removeFirst() }, wait: { _ in }
        )
        #expect(data == button)
        #expect(reported == 1)
    }
}

@Suite("Accessibility hold through the broker", .serialized)
@MainActor
struct AccessibilityHoldBrokerTests {
    private func serve(_ accessibility: BrokerAccessibilityHold?) throws -> (server: HIDBrokerServer, task: Task<String, Never>, endpoint: String) {
        let endpoint = FileManager.default.temporaryDirectory.appendingPathComponent("ah-\(UUID().uuidString.prefix(8)).sock").path
        let listener = try HIDBroker.makeListener(at: endpoint)
        let server = HIDBrokerServer(
            udid: "SIM-A", listener: listener, endpoint: endpoint, sink: HIDBrokerSink(send: { _ in }, sendPaced: { _ in }),
            accessibility: accessibility, isCurrentBoot: { true }, admits: { _ in true }, idleSeconds: 60, log: { _ in }
        )
        return (server, Task { await server.run() }, endpoint)
    }

    nonisolated private static func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }

    @Test("a command is told yes while the broker holds a live session, and status says so")
    func brokerAnswersHeld() async throws {
        let opener = Opener()
        let hold = BrokerAccessibilityHold(open: { opener.open() }, log: { _ in })
        hold.start()
        await waitUntil { hold.isHeld(reopening: false) }
        let running = try serve(hold)
        let endpoint = running.endpoint
        let token = await Self.offMain { AccessibilityHold.ask(endpoint: endpoint) }
        #expect(token != nil && token == hold.heldToken(reopening: false))
        let status = await Self.offMain { HIDBroker.control(.status, at: endpoint)?.status }
        #expect(status?.accessibilityHeld == true)
        opener.opened.first?.die()
        #expect(await Self.offMain { AccessibilityHold.ask(endpoint: endpoint) } == nil)
        running.server.requestStop("test over")
        _ = await running.task.value
        hold.close()
    }

    @Test("a broker with no session, or none at all, is a no, so the command bootstraps as before")
    func noHoldIsNo() async throws {
        let running = try serve(nil)
        let endpoint = running.endpoint
        #expect(await Self.offMain { AccessibilityHold.ask(endpoint: endpoint) } == nil)
        let status = await Self.offMain { HIDBroker.control(.status, at: endpoint)?.status }
        #expect(status?.accessibilityHeld == nil)
        running.server.requestStop("test over")
        _ = await running.task.value
        #expect(await Self.offMain { AccessibilityHold.ask(endpoint: endpoint) } == nil)
    }

    @Test("a broker that is stopping answers no")
    func stoppingBrokerIsNo() async throws {
        let opener = Opener()
        let hold = BrokerAccessibilityHold(open: { opener.open() }, log: { _ in })
        hold.start()
        await waitUntil { hold.isHeld(reopening: false) }
        let running = try serve(hold)
        let endpoint = running.endpoint
        let descriptor = try await Self.offMain { try? HIDBroker.connectAndAwaitHandshake(endpoint: endpoint, connector: HIDBroker.connect(to:), timeoutMilliseconds: 15_000) } ?? -1
        #expect(descriptor >= 0)
        running.server.requestStop("test over", cutOff: false)
        var request = try JSONEncoder().encode(HIDBrokerRequest(op: .accessibility))
        request.append(0x0A)
        let copied = request
        let reply = await Self.offMain { try? HIDBroker.exchange(copied, on: descriptor, timeoutMilliseconds: 5_000) }
        #expect(reply?.accessibilityHeld != true)
        Darwin.close(descriptor)
        _ = await running.task.value
        hold.close()
    }
}
