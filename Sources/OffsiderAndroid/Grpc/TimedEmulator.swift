import Foundation

/// Adds a `grpc-call` line per unary RPC; `sendTouch` and the streams are left to `input` and their callers.
final class TimedEmulator: EmulatorControlling {
    let inner: any EmulatorControlling
    private let timing: AndroidTiming

    /// Unwrapped when timing is off, so the default path keeps the client itself.
    static func wrapping(_ emulator: any EmulatorControlling, timing: AndroidTiming) -> any EmulatorControlling {
        timing.isEnabled ? TimedEmulator(inner: emulator, timing: timing) : emulator
    }

    private init(inner: any EmulatorControlling, timing: AndroidTiming) {
        self.inner = inner
        self.timing = timing
    }

    var endpoint: String { inner.endpoint }

    func status() async throws -> EmulatorStatusSummary {
        try await timing.measure(.grpcCall) { try await inner.status() }
    }

    func sendTouch(_ touch: PanelTouch) async throws {
        try await inner.sendTouch(touch)
    }

    func sendKey(_ event: EmulatorKeyEvent) async throws {
        try await timing.measure(.grpcCall) { try await inner.sendKey(event) }
    }

    func screenshot(_ format: EmulatorImageFormat, fitting box: FrameBox?) async throws -> EmulatorFrame {
        try await timing.measure(.grpcCall) { try await inner.screenshot(format, fitting: box) }
    }

    func screenshotStream(_ format: EmulatorImageFormat, fitting box: FrameBox?) -> AsyncThrowingStream<EmulatorFrame, any Error> {
        inner.screenshotStream(format, fitting: box)
    }

    func clipboard() async throws -> String {
        try await timing.measure(.grpcCall) { try await inner.clipboard() }
    }

    func setClipboard(_ text: String) async throws {
        try await timing.measure(.grpcCall) { try await inner.setClipboard(text) }
    }

    func setPosture(_ posture: EmulatorPosture) async throws {
        try await timing.measure(.grpcCall) { try await inner.setPosture(posture) }
    }

    func currentPosture(timeout: Duration) async throws -> EmulatorPosture? {
        try await inner.currentPosture(timeout: timeout)
    }

    func close() async {
        await inner.close()
    }
}
