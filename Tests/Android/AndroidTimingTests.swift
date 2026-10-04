import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var phases: [String] { lock.withLock { recorded } }

    var timing: AndroidTiming {
        AndroidTiming(isEnabled: true) { phase, _ in self.lock.withLock { self.recorded.append(phase) } }
    }
}

@Suite("Android timing phases")
@MainActor
struct AndroidTimingTests {
    nonisolated static let helperPhases: Set<String> = ["helper-launch", "dex-push", "helper-hello", "helper-dump", "tree-map", "helper-close"]

    static func read(on device: FakeHelperDevice) async throws -> [String] {
        let recorder = PhaseRecorder()
        device.other = { service in
            if service.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            return FakeAdbServer.shell()
        }
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: device.server(), helperDex: FakeHelperDevice.dex)
        host.timing = recorder.timing
        let backend = AndroidBackend(host: host, log: { _, _ in })
        _ = try await backend.accessibilityTree(for: HelperRig.device, point: nil)
        await backend.close()
        return recorder.phases
    }

    @Test("a helper read emits helper-launch, helper-hello, helper-dump, tree-map and helper-close in order")
    func helperReadOrder() async throws {
        let phases = try await Self.read(on: FakeHelperDevice())

        #expect(phases.first == "prepare")
        #expect(phases.filter(Self.helperPhases.contains) == ["helper-launch", "helper-hello", "helper-dump", "tree-map", "helper-close"])
    }

    @Test("dex-push appears only when the dex is missing, between the two launch attempts")
    func dexPushOnlyWhenMissing() async throws {
        let present = try await Self.read(on: FakeHelperDevice())
        let missing = try await Self.read(on: FakeHelperDevice(dexOnDevice: false))

        #expect(!present.contains("dex-push"))
        #expect(missing.filter(Self.helperPhases.contains).prefix(4) == ["helper-launch", "dex-push", "helper-launch", "helper-hello"])
    }

    @Test("disabled timing never reads the clock or emits")
    func disabledNeverReadsClock() async throws {
        let timing = AndroidTiming(
            isEnabled: false,
            now: { Issue.record("the clock was read"); return 0 },
            emit: { phase, _ in Issue.record("emitted \(phase)") }
        )
        let value = await timing.measure(.helperDump) { 7 }
        let sync = timing.measure(.treeMap) { 8 }
        #expect(value + sync == 15)
    }

    @Test("Android phase lines use the iOS line format")
    func lineFormat() async throws {
        let lines = PhaseLines()
        let timing = AndroidTiming.printing { lines.append($0) }
        await timing.measure(.helperLaunch) {}
        let line = try #require(lines.all.first)
        #expect(line.hasPrefix("\(PhaseTimings.linePrefix) helper-launch "))
        #expect(line.hasSuffix(" ms"))
    }

    @Test("an enabled phase is measured with the injected clock")
    func measuredWithClock() async throws {
        let recorder = Durations()
        let ticks = Durations()
        ticks.append("start", 1_000_000)
        ticks.append("end", 43_000_000)
        let timing = AndroidTiming(
            isEnabled: true,
            now: { ticks.takeFirst() },
            emit: { phase, nanoseconds in recorder.append(phase, nanoseconds) }
        )
        await timing.measure(.grpcCall) {}
        #expect(recorder.all.map(\.0) == ["grpc-call"])
        #expect(recorder.all.map(\.1) == [42_000_000])
    }
}

final class PhaseLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

final class Durations: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, UInt64)] = []
    var all: [(String, UInt64)] { lock.withLock { entries } }
    func append(_ phase: String, _ nanoseconds: UInt64) { lock.withLock { entries.append((phase, nanoseconds)) } }
    func takeFirst() -> UInt64 { lock.withLock { entries.removeFirst().1 } }
}
