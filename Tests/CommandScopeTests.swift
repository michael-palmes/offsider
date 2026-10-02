import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@MainActor
private final class CloseLog {
    var entries: [String] = []
}

/// Holds a close open until the test lets it finish.
@MainActor
private final class CloseGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ClosingBackend: DeviceBackend {
    let name: String
    let log: CloseLog
    let gate: CloseGate?

    init(_ name: String, log: CloseLog, gate: CloseGate? = nil) {
        self.name = name
        self.log = log
        self.gate = gate
    }

    var platform: DevicePlatform { .ios }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: name) }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree { UITree(platform: platform, device: id.rawValue, roots: []) }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
    func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] { points }
    func openInputSession(for id: DeviceID) async throws -> any InputSession { throw CLIError(errorDescription: "no input") }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { ScreenBands(top: 0, bottom: 0) }

    func close() async {
        await gate?.wait()
        log.entries.append("close \(name)")
    }
}

private struct CommandFailure: Error, Equatable {}

@Suite("Command scope")
@MainActor
struct CommandScopeTests {
    @Test("run closes adopted backends after the command succeeds, in reverse adoption order")
    func closesAfterSuccess() async throws {
        let log = CloseLog()
        let scope = CommandScope()
        scope.adopt(ClosingBackend("ios", log: log))
        scope.adopt(ClosingBackend("android", log: log))

        try await scope.run { log.entries.append("command") }

        #expect(log.entries == ["command", "close android", "close ios"])
    }

    @Test("run closes adopted backends after the command throws, then rethrows the original error")
    func closesAfterThrow() async {
        let log = CloseLog()
        let scope = CommandScope()
        scope.adopt(ClosingBackend("first", log: log))
        scope.adopt(ClosingBackend("second", log: log))

        await #expect(throws: CommandFailure()) {
            try await scope.run { throw CommandFailure() }
        }
        #expect(log.entries == ["close second", "close first"])
    }

    @Test("a verify failure's exit code reaches ArgumentParser unchanged after the close")
    func exitCodePassesThrough() async {
        let log = CloseLog()
        let scope = CommandScope()
        scope.adopt(ClosingBackend("android", log: log))

        let error = await #expect(throws: ExitCode.self) {
            try await scope.run { throw ExitCode(5) }
        }
        #expect(error?.rawValue == 5)
        #expect(log.entries == ["close android"])
    }

    @Test("a backend adopted while the command runs is closed too")
    func adoptedDuringRun() async throws {
        let log = CloseLog()
        let scope = CommandScope()

        try await scope.run { scope.adopt(ClosingBackend("late", log: log)) }

        #expect(log.entries == ["close late"])
    }

    @Test("closeAll twice, or a backend adopted twice, closes each backend once")
    func closesOnce() async {
        let log = CloseLog()
        let scope = CommandScope()
        let backend = ClosingBackend("android", log: log)
        scope.adopt(backend)
        scope.adopt(backend)

        await scope.closeAll()
        await scope.closeAll()

        #expect(log.entries == ["close android"])
        #expect(scope.adopted.isEmpty)
    }

    @Test("a slow close neither skips nor repeats the others")
    func slowClose() async {
        let log = CloseLog()
        let gate = CloseGate()
        let scope = CommandScope()
        scope.adopt(ClosingBackend("first", log: log))
        scope.adopt(ClosingBackend("slow", log: log, gate: gate))
        scope.adopt(ClosingBackend("last", log: log))

        let closing = Task { await scope.closeAll() }
        while !gate.entered { await Task.yield() }
        await scope.closeAll()
        #expect(log.entries == ["close last", "close first"])

        gate.open()
        await closing.value
        #expect(log.entries == ["close last", "close first", "close slow"])
    }
}
