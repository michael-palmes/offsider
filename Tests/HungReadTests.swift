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

    /// A simulator reads a tree to place coordinates, so a hung one never maps them.
    override func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    override func displays(of id: DeviceID) async throws -> DisplayList {
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

    @Test("a screenshot during a hold stops waiting on a read that never returns, and lifts the finger first")
    func holdLiftsBeforeFiring() async throws {
        let fired = Fired()
        let backend = WedgedBackend(trees: [])
        let route = DeviceRouter.Route(backend: backend, device: Self.simulator)
        let swipe = try Swipe.parse(["--start-x", "200", "--start-y", "800", "--end-x", "200", "--end-y", "400", "--screenshot-at", "0", "--device", Self.simulator.rawValue])
        let lift = InputEvent.touch(direction: .up, x: 200, y: 400)
        let liftedFirst = Fired()
        let watchdog = DeviceWatchdog(grace: 0.05, readBound: 0) { message in
            fired.record(message)
        }
        backend.session.onPerform = { if $0 == lift { liftedFirst.record(fired.all.isEmpty ? "before" : "after") } }

        try await firesWhile(fired) {
            try await swipe.holdShots.perform(press: .touch(direction: .down, x: 200, y: 800), lift: lift, holdEnd: 0, on: route, details: InputDetails(), watchdog: watchdog)
        }

        #expect(liftedFirst.all == ["before"])
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

    @Test("displays stops waiting on a display read that never returns")
    func displays() async throws {
        let fired = Fired()
        let watchdog = watchdog(fired)
        try await firesWhile(fired) {
            _ = try await Displays.list(on: Self.simulator, backend: WedgedBackend(trees: []), deviceName: Self.simulator.rawValue, watchdog: watchdog)
        }
    }

    @Test("coordinate input stops waiting on the read that places its points, before anything is sent", arguments: [
        ["tap", "-x", "100", "-y", "200"],
        ["swipe", "--start-x", "200", "--start-y", "800", "--end-x", "200", "--end-y", "400"],
        ["drag", "--start-x", "200", "--start-y", "300", "--end-x", "200", "--end-y", "600"],
        ["touch", "-x", "100", "-y", "200", "--down", "--up"],
        ["touch", "-x", "200", "-y", "400", "--fingers", "2", "--hold", "500"],
        ["gesture", "long-press-drag", "--x", "200", "--y", "300", "--to-x", "200", "--to-y", "600"],
        ["gesture", "scroll-up"],
    ])
    func coordinateInput(arguments: [String]) async throws {
        let fired = Fired()
        let backend = WedgedBackend(trees: [])
        let route = DeviceRouter.Route(backend: backend, device: Self.simulator)
        let watchdog = watchdog(fired)
        let command = try OffsiderCommand.parseAsRoot(arguments + ["--device", Self.simulator.rawValue])
        try await firesWhile(fired) {
            let logger = OffsiderLogger()
            switch command {
            case let tap as Tap: try await tap.execute(on: route, progress: nil, logger: logger, watchdog: watchdog)
            case let swipe as Swipe: try await swipe.swipe(on: route, details: InputDetails(), logger: logger, watchdog: watchdog)
            case let drag as Drag: try await drag.drag(on: route, details: InputDetails(), logger: logger, watchdog: watchdog)
            case let touch as Touch: try await touch.touch(on: route, logger: logger, watchdog: watchdog)
            case let gesture as Gesture: try await gesture.send(on: route, logger: logger, watchdog: watchdog)
            default: Issue.record("\(arguments[0]) is not an input command here")
            }
        }
        #expect(backend.session.calls.isEmpty)
    }

    /// Runs `body` with every read that makes its own watchdog bound to `fired`'s tiny one.
    private func withTinyWatchdogs<T>(_ fired: Fired, _ body: () async throws -> T) async rethrows -> T {
        try await DeviceWatchdog.$make.withValue({ DeviceWatchdog(grace: 0.05, readBound: 0) { fired.record($0) } }, operation: body)
    }

    @Test("plain type and a key-sequence that spells text stop waiting on the focus read, before anything is sent")
    func focusReads() async throws {
        let typing = Fired()
        let backend = WedgedBackend(trees: [])
        let type = try Type.parse(["hello", "--device", Self.simulator.rawValue])
        try await firesWhile(typing) {
            try await withTinyWatchdogs(typing) {
                _ = try await type.ensureFocus(backend: backend, device: Self.simulator, logger: OffsiderLogger()) { _ in Issue.record("tapped") }
            }
        }

        let pressing = Fired()
        let keys = try KeySequence.parse(["--keycodes", "11,8", "--device", Self.simulator.rawValue])
        try await firesWhile(pressing) {
            try await withTinyWatchdogs(pressing) {
                try await keys.perform(on: DeviceRouter.Route(backend: backend, device: Self.simulator), logger: OffsiderLogger())
            }
        }
        #expect(backend.session.calls.isEmpty)
    }

    @Test("rn devmenu and rn tools off stop waiting on a tree read that never returns")
    func devMenuReads() async throws {
        let listing = Fired()
        let route = route()
        let menu = try RNDevMenu.parse(["--device", Self.simulator.rawValue])
        let menuWatchdog = watchdog(listing)
        try await firesWhile(listing) { _ = try await menu.perform(on: route, clock: ScriptedClock().poll, watchdog: menuWatchdog) }

        let tools = Fired()
        let off = try RNToolsOff.parse(["--device", Self.simulator.rawValue])
        let toolsWatchdog = watchdog(tools)
        try await firesWhile(tools) { _ = try await off.turnOff(on: route, clock: ScriptedClock().poll, watchdog: toolsWatchdog) }
    }

    @Test("rn open ends on a tree read that never returns rather than waiting out --timeout")
    func rnOpenRead() async throws {
        let fired = Fired()
        let backend = WedgedBackend(trees: [])
        let command = try RNOpen.parse(["--port", "8742", "--bundle-id", "com.mpalmes.offsider.playground.rn", "--wait-id", "home-screen", "--timeout", "900", "--device", Self.simulator.rawValue])
        let metro = MetroStatus(fetch: { _, _ in (200, Data("packager-status:running".utf8)) })
        let watchdog = watchdog(fired)
        try await firesWhile(fired) {
            _ = try await command.open(on: DeviceRouter.Route(backend: backend, device: Self.simulator), metro: metro, clock: ScriptedClock().poll, watchdog: watchdog)
        }
        #expect(backend.openedURLs.count == 1, "the link went before the read hung")
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
