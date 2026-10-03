import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Device watchdog")
struct DeviceWatchdogTests {
    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        private var firedAt: ContinuousClock.Instant?
        func record(_ message: String) {
            lock.withLock {
                messages.append(message)
                firedAt = firedAt ?? .now
            }
        }
        var all: [String] { lock.withLock { messages } }
        var firstFiredAt: ContinuousClock.Instant? { lock.withLock { firedAt } }
    }

    /// Generous because a loaded machine can delay the timer; it returns as soon as `done` holds.
    private func waitBriefly(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("a hung command past its bound fires once with an actionable message")
    func firesAfterBound() async throws {
        let fired = Fired()
        let watchdog = DeviceWatchdog(grace: 0.05) { fired.record($0) }
        watchdog.arm(bound: 0, device: "SIM-1")
        try await waitBriefly { !fired.all.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fired.all.count == 1)
        #expect(fired.all.first?.contains("run `offsider doctor --device SIM-1`, or restart the device") == true)
        #expect(!watchdog.isArmed)
    }

    @Test("a command that finishes in time disarms the watchdog")
    func guardingDisarmsOnReturn() async throws {
        let fired = Fired()
        let watchdog = DeviceWatchdog(grace: 0.1) { fired.record($0) }
        let value = await watchdog.guarding(bound: 0, device: "SIM-1") { 7 }
        #expect(value == 7)
        #expect(!watchdog.isArmed)
        try await Task.sleep(for: .milliseconds(250))
        #expect(fired.all.isEmpty)
    }

    @Test("a command that throws still disarms the watchdog")
    func guardingDisarmsOnThrow() async throws {
        struct Boom: Error {}
        let fired = Fired()
        let watchdog = DeviceWatchdog(grace: 0.1) { fired.record($0) }
        await #expect(throws: Boom.self) {
            try await watchdog.guarding(bound: 0, device: "SIM-1") { throw Boom() }
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(fired.all.isEmpty)
    }

    @Test("the watchdog waits out the command's own bound before its grace")
    func boundDelaysFiring() async throws {
        let fired = Fired()
        let watchdog = DeviceWatchdog(grace: 0.2) { fired.record($0) }
        let armedAt = ContinuousClock.now
        watchdog.arm(bound: 0.3, device: "SIM-1")
        try await waitBriefly { !fired.all.isEmpty }
        #expect(fired.all.count == 1)
        let firedAt = try #require(fired.firstFiredAt)
        #expect(armedAt.duration(to: firedAt) >= .seconds(0.5))
    }

    @Test("slow setup is covered by the setup bound, not the condition's bound of 0")
    func setupHasItsOwnBound() async throws {
        let fired = Fired()
        let watchdog = DeviceWatchdog(grace: 0.1, setupBound: 10) { fired.record($0) }
        let value = await watchdog.guarding(setupThen: 0, device: "SIM-1") { ready in
            try? await Task.sleep(for: .milliseconds(200))
            #expect(fired.all.isEmpty)
            ready()
            return 7
        }
        #expect(value == 7)
        #expect(!watchdog.isArmed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fired.all.isEmpty)
    }

    @Test("after setup the watchdog re-arms for the condition's own bound")
    func readyRearmsForBound() async throws {
        let fired = Fired()
        let watchdog = DeviceWatchdog(grace: 0.05, setupBound: 10) { fired.record($0) }
        await watchdog.guarding(setupThen: 0, device: "SIM-1") { ready in
            ready()
            try? await waitBriefly { !fired.all.isEmpty }
        }
        #expect(fired.all.count == 1)
        #expect(fired.all.first?.hasPrefix("Error: the device did not answer within 0 s.") == true)
    }

    @Test("wait and assert end their setup phase after prepare and before the first tree read")
    @MainActor
    func evaluateSignalsReadyBeforeReading() async throws {
        let tree = FakeUI.tree([FakeUI.node(.button, id: "go", label: "Go", frame: FakeUI.frame(20, 100, 350, 44))])
        let backend = FakeDeviceBackend(trees: [tree], screen: UIScreenInfo(width: 402, height: 874, scale: 1, rotation: .portrait))
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "fake-device", platform: .ios))
        let readied = Fired()
        var readyBeforeRead: [Bool] = []
        backend.onTreeRead = { readyBeforeRead.append(!readied.all.isEmpty) }

        _ = try await Wait.parse(["--id", "go", "--device", "x"]).evaluate(on: route, logger: OffsiderLogger(), onPrepared: { readied.record("wait") })
        _ = try await Assert.parse(["--id", "go", "--device", "x"]).evaluate(on: route, logger: OffsiderLogger(), onPrepared: { readied.record("assert") })

        #expect(readied.all == ["wait", "assert"])
        #expect(readyBeforeRead == [true, true])
    }

    @Test("the message names the whole limit in seconds")
    func messageNamesLimit() {
        #expect(DeviceWatchdog.message(seconds: 25, device: "emulator-5554").hasPrefix("Error: the device did not answer within 25 s."))
    }

    @Test("a long wait arms the watchdog past its own duration")
    func longWaitBound() throws {
        #expect(try Wait.parse(["--seconds", "300", "--device", "x"]).watchdogBound == 300)
        #expect(try Wait.parse(["--id", "go", "--timeout", "300", "--device", "x"]).watchdogBound == 300)
        #expect(DeviceWatchdog.grace >= 10)
    }
}
