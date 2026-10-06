import Foundation
import OffsiderCore

/// Input steps as unary `sendTouch` and `sendKey` calls, timed from the host; the panel rule applies here only.
struct GrpcInputDriver: Sendable {
    let emulator: any EmulatorControlling
    let geometry: AndroidDisplayGeometry
    let sleep: @Sendable (Duration) async throws -> Void

    /// Nonzero for a finger on the glass; zero lifts it (the spike measured 1 as enough).
    static let pressure: Int32 = 1

    func run(_ steps: [AndroidInputStep]) async throws {
        for step in steps {
            switch step {
            case .touch(let phase, let point):
                try await touch(point, down: phase != .up)
            case .touches(let phase, let points):
                do {
                    try await touches(points, down: phase != .up)
                } catch {
                    try? await touches(points, down: false)
                    throw error
                }
            case .tap(let point):
                try await touch(point, down: true)
                try await liftingOnFailure(at: point) {
                    try await touch(point, down: false)
                }
            case let .swipe(from, to, duration, count):
                try await touch(from, down: true)
                let moves = max(1, count)
                try await liftingOnFailure(at: to) {
                    for index in 1...moves {
                        try await pause(duration / Double(moves))
                        let fraction = Double(index) / Double(moves)
                        try await touch(AndroidPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction), down: true)
                    }
                    try await touch(to, down: false)
                }
            case let .key(phase, usage):
                guard let code = AndroidKeyTable.usbCode(for: usage) else { throw AndroidError.unsupportedKey(usage) }
                try await emulator.sendKey(.usb(code, phase))
            case let .button(phase, button):
                guard let key = AndroidButtonMap.w3cKey(for: button) else { throw AndroidError.unsupportedButton(button) }
                try await emulator.sendKey(.w3c(key, phase))
            case .pause(let seconds):
                try await pause(seconds)
            }
        }
    }

    func touch(_ point: AndroidPoint, down: Bool) async throws {
        let panel = PanelRotation.panelPoint(point, rotation: geometry.rotation, naturalWidth: geometry.naturalWidth, naturalHeight: geometry.naturalHeight)
        try await emulator.sendTouch(PanelTouch(x: panel.x, y: panel.y, pressure: down ? Self.pressure : 0))
    }

    /// One event carrying every finger, with identifiers 0, 1, … in order.
    func touches(_ points: [AndroidPoint], down: Bool) async throws {
        let fingers = points.enumerated().map { index, point in
            let panel = PanelRotation.panelPoint(point, rotation: geometry.rotation, naturalWidth: geometry.naturalWidth, naturalHeight: geometry.naturalHeight)
            return PanelTouch(x: panel.x, y: panel.y, pressure: down ? Self.pressure : 0, identifier: Int32(index))
        }
        try await emulator.sendTouches(fingers)
    }

    /// A gesture that fails part-way still lifts its finger, best effort, before the error goes on.
    private func liftingOnFailure(at point: AndroidPoint, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            try? await touch(point, down: false)
            throw error
        }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await sleep(.seconds(seconds))
    }
}
