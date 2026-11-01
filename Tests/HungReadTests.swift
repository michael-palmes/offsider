import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A simulator that stopped answering: its tree and screen reads never return, as on a wedged render server.
@MainActor
private final class WedgedBackend: FakeDeviceBackend {
    override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    override func screenshotPNG(for id: DeviceID) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

@Suite("Reads of a hung device")
@MainActor
struct HungReadTests {
    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func record(_ message: String) { lock.withLock { messages.append(message) } }
        var all: [String] { lock.withLock { messages } }
    }

    private static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)

    private func route(_ device: DeviceID = HungReadTests.simulator) -> DeviceRouter.Route {
        DeviceRouter.Route(backend: WedgedBackend(trees: []), device: device)
    }

    private func firesWhile(_ fired: Fired, _ read: @escaping @MainActor () async throws -> Void) async throws {
        let task = Task { @MainActor in try await read() }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while fired.all.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fired.all.count == 1)
        #expect(fired.all.first?.contains(Self.simulator.rawValue) == true, "it names the stuck device")
        #expect(fired.all.first?.contains("offsider doctor --device") == true, "and the next step")
    }

    private func watchdog(_ fired: Fired) -> DeviceWatchdog {
        DeviceWatchdog(grace: 0.05, readBound: 0) { fired.record($0) }
    }

    @Test("describe-ui stops waiting on a tree read that never returns")
    func describeUI() async throws {
        let fired = Fired()
        let command = try DescribeUI.parse(["--device", Self.simulator.rawValue])
        let route = route()
        let watchdog = watchdog(fired)
        try await firesWhile(fired) { _ = try await command.read(on: route, watchdog: watchdog) }
    }

    @Test("screenshot stops waiting on a capture that never returns")
    func screenshot() async throws {
        let fired = Fired()
        let command = try Screenshot.parse(["--device", Self.simulator.rawValue, "--no-mask-secure"])
        let route = route()
        let watchdog = watchdog(fired)
        try await firesWhile(fired) {
            _ = try await watchdog.guardingRead(of: route.device) {
                try await command.take(try command.request(), on: route, masks: .none)
            }
        }
    }

    @Test("rn logbox status stops waiting on a tree read that never returns")
    func logBoxStatus() async throws {
        let fired = Fired()
        let route = route()
        let watchdog = watchdog(fired)
        try await firesWhile(fired) {
            _ = try await RNLogBox.guarding(on: route, watchdog: watchdog) {
                try await route.backend.accessibilityTree(for: route.device)
            }
        }
    }

    @Test("a read that answers in time disarms, and a --wait-lock wait does not count against it")
    func healthyRead() async throws {
        let fired = Fired()
        // Far past any stall of a full parallel run, which has held the main actor for over 15 s.
        let watchdog = DeviceWatchdog(grace: 600, readBound: 0) { fired.record($0) }
        let value = await watchdog.guardingRead(of: Self.simulator) { 7 }
        #expect(value == 7)
        #expect(!watchdog.isArmed)

        let shortGrace = DeviceWatchdog(grace: 0.01, readBound: 0) { fired.record($0) }
        await shortGrace.guardingRead(of: Self.simulator, extra: 600) { try? await Task.sleep(for: .milliseconds(200)) }
        #expect(!shortGrace.isArmed)
        #expect(fired.all.isEmpty, "a --wait-lock wait of up to 600 s is not taken for a hung device")
    }

    @Test("a phone's read runs unarmed: it has limits of its own, and a first iPhone read can build the runner", arguments: [
        DeviceID(rawValue: "R58M123ABC", platform: .android),
        DeviceID(rawValue: "00008110-000000000000001E", platform: .ios),
    ])
    func phonesRunUnarmed(device: DeviceID) async {
        let watchdog = DeviceWatchdog(grace: 600, readBound: 0, fire: { _ in Issue.record("the watchdog fired") })
        var armed = true
        await watchdog.guardingRead(of: device) { armed = watchdog.isArmed }
        #expect(!armed)
    }

    @Test("a phone runs a command's setup and its wait unarmed, past any bound, so a first iPhone read can build the runner", arguments: [
        DeviceID(rawValue: "R58M123ABC", platform: .android),
        DeviceID(rawValue: "00008110-000000000000001E", platform: .ios),
    ])
    func phonesRunSetupThenUnarmed(device: DeviceID) async {
        let watchdog = DeviceWatchdog(grace: 0.01, setupBound: 0, readBound: 0, fire: { _ in Issue.record("the watchdog fired on a phone") })
        var armed = [true, true]
        await watchdog.guarding(setupThen: 0, of: device) { ready in
            armed[0] = watchdog.isArmed
            ready()
            armed[1] = watchdog.isArmed
            try? await Task.sleep(for: .milliseconds(100))
        }
        await watchdog.guarding(bound: 0, of: device) { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(armed == [false, false])
    }

    @Test("a simulator's setup then its wait stay armed, for the bound once ready")
    func simulatorRunsSetupThenArmed() async {
        let watchdog = DeviceWatchdog(grace: 600, fire: { _ in Issue.record("the watchdog fired") })
        var armed = [false, false]
        await watchdog.guarding(setupThen: 0, of: Self.simulator) { ready in
            armed[0] = watchdog.isArmed
            ready()
            armed[1] = watchdog.isArmed
        }
        #expect(armed == [true, true])
        #expect(!watchdog.isArmed)
    }

    /// An emulator's helper start, which takes as long as `started` says.
    private final class StartingBackend: FakeDeviceBackend, MaskTreeReading {
        var starts = 0
        var started: Duration = .zero
        func maskTree(for id: DeviceID) async throws -> UITree { UITree(platform: .android, device: id.rawValue, roots: []) }
        func prepareMaskTree(for id: DeviceID) async throws {
            starts += 1
            try await Task.sleep(for: started)
        }
    }

    @Test("a slow helper start outlasts the read bound, so its uiautomator fallback can run")
    func helperStartOutlastsTheReadBound() async throws {
        let fired = Fired()
        let backend = StartingBackend(trees: [])
        backend.started = .milliseconds(200)
        let watchdog = DeviceWatchdog(grace: 0.01, readBound: 0, treeStartBound: 600) { fired.record($0) }

        try await watchdog.guardingTreeStart(on: DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5556", platform: .android)))

        #expect(backend.starts == 1)
        #expect(fired.all.isEmpty)
        #expect(!watchdog.isArmed)
    }

    @Test("a helper that never starts past that bound, with any --wait-lock wait added, still ends as hung")
    func helperStartHasItsOwnBound() async throws {
        let fired = Fired()
        let backend = StartingBackend(trees: [])
        backend.started = .seconds(3600)
        let watchdog = DeviceWatchdog(grace: 0.01, treeStartBound: 0) { fired.record($0) }

        try await firesWhile(fired) {
            try await watchdog.guardingTreeStart(on: DeviceRouter.Route(backend: backend, device: Self.simulator))
        }
    }

    @Test("a phone starts nothing early: its first read does, unbound")
    func phoneStartsNoHelperEarly() async throws {
        let backend = StartingBackend(trees: [])
        try await DeviceWatchdog().guardingTreeStart(on: DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "R58M123ABC", platform: .android)))
        #expect(backend.starts == 0)
    }

    @Test("a verified input's read and a selector's read of a hung simulator end as hung, naming it")
    func inputReadsEndAsHung() async throws {
        for read in [
            { (watchdog: DeviceWatchdog, backend: FakeDeviceBackend) in
                _ = try await Verifier.Dependencies.live(backend: backend, device: Self.simulator, watchdog: watchdog).tree()
            },
            { (watchdog: DeviceWatchdog, backend: FakeDeviceBackend) in
                _ = try await AccessibilityPoller.resolveWithPolling(
                    query: .id("save"), on: backend, device: Self.simulator, waitTimeout: 0, pollInterval: 0.01, watchdog: watchdog, logger: OffsiderLogger()
                )
            },
        ] as [@MainActor (DeviceWatchdog, FakeDeviceBackend) async throws -> Void] {
            let fired = Fired()
            let watchdog = DeviceWatchdog(grace: 0.01, readBound: 0) { fired.record($0) }
            try await firesWhile(fired) { try await read(watchdog, WedgedBackend(trees: [])) }
            #expect(fired.all.first?.contains(Self.simulator.rawValue) == true)
        }
    }

    @Test("an emulator's input read allows for a helper start; a simulator's does not need to")
    func inputReadOfAnEmulatorOutlastsAHelperStart() async {
        let watchdog = DeviceWatchdog(grace: 0.01, readBound: 0, treeStartBound: 600, fire: { _ in Issue.record("the watchdog fired") })
        await watchdog.guardingInputRead(of: DeviceID(rawValue: "emulator-5556", platform: .android)) { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @Test("an emulator's read is armed like a simulator's")
    func emulatorIsArmed() async {
        let watchdog = DeviceWatchdog(grace: 600, readBound: 0, fire: { _ in Issue.record("the watchdog fired") })
        var armed = false
        await watchdog.guardingRead(of: DeviceID(rawValue: "emulator-5556", platform: .android)) { armed = watchdog.isArmed }
        #expect(armed)
    }

    @Test("run as the CLI runs it, a hung read ends the process with device_unresponsive, naming the device")
    func hungReadEndsTheProcess() async {
        let result = await #expect(processExitsWith: .exitCode(FailureReason.deviceUnresponsive.exitCode.rawValue), observing: [\.standardErrorContent]) { @MainActor in
            let device = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
            let route = DeviceRouter.Route(backend: WedgedBackend(trees: []), device: device)
            let command = try DescribeUI.parse(["--device", device.rawValue])
            let watchdog = await OffsiderCommand.withCLIDefaults { DeviceWatchdog(grace: 0.05, readBound: 0) }
            _ = try await command.read(on: route, watchdog: watchdog)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("00000000-0000-0000-0000-000000000001"))
        #expect(stderr.contains("did not answer"))
    }
}
