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
