import Foundation
import OffsiderCore

/// Android phases for `OFFSIDER_TIMINGS=1`, printed in the iOS `offsider timing: <phase> <n> ms` format.
enum AndroidPhase: String, CaseIterable, Sendable {
    case prepare
    case adbDevices = "adb-devices"
    case adbShell = "adb-shell"
    case displayProbe = "display-probe"
    case helperLaunch = "helper-launch"
    case dexPush = "dex-push"
    case helperHello = "helper-hello"
    case helperDump = "helper-dump"
    case treeMap = "tree-map"
    case helperClose = "helper-close"
    case helperInject = "helper-inject"
    case grpcConnect = "grpc-connect"
    case grpcCall = "grpc-call"
    case input
    case capture
}

/// Off by default: then `measure` is one `Bool` check and a plain call, with no clock read.
public struct AndroidTiming: Sendable {
    public let isEnabled: Bool
    private let now: PhaseTimings.Clock
    private let emit: @Sendable (_ phase: String, _ nanoseconds: UInt64) -> Void

    init(
        isEnabled: Bool,
        now: @escaping PhaseTimings.Clock = PhaseTimings.monotonicNanoseconds,
        emit: @escaping @Sendable (_ phase: String, _ nanoseconds: UInt64) -> Void
    ) {
        self.isEnabled = isEnabled
        self.now = now
        self.emit = emit
    }

    public static let disabled = AndroidTiming(isEnabled: false, emit: { _, _ in })

    /// One finished line per phase, without a trailing newline.
    public static func printing(to sink: @escaping @Sendable (String) -> Void) -> AndroidTiming {
        AndroidTiming(isEnabled: true) { phase, nanoseconds in
            sink(PhaseTimings.Phase(name: phase, nanoseconds: nanoseconds).line)
        }
    }

    func measure<T>(
        _ phase: AndroidPhase,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else {
            return try await body()
        }
        let start = now()
        defer { finish(phase, since: start) }
        return try await body()
    }

    func measure<T>(_ phase: AndroidPhase, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else {
            return try body()
        }
        let start = now()
        defer { finish(phase, since: start) }
        return try body()
    }

    private func finish(_ phase: AndroidPhase, since start: UInt64) {
        let end = now()
        emit(phase.rawValue, end >= start ? end - start : 0)
    }
}
