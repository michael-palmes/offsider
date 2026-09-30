import Foundation
@testable import OffsiderAndroid

/// An in-memory gRPC endpoint: records every call in order and fails the calls a test names.
final class FakeEmulator: EmulatorControlling, @unchecked Sendable {
    enum Call: Equatable {
        case touch(PanelTouch)
        case key(EmulatorKeyEvent)
        case screenshot(EmulatorImageFormat, FrameBox?)
        case stream(EmulatorImageFormat, FrameBox?)
        case getClipboard
        case setClipboard(String)
        case close
    }

    let endpoint = "127.0.0.1:8556"
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var clipboardText: String
    private let frames: [EmulatorFrame]
    private let failure: @Sendable (Call) -> AndroidError?

    init(clipboard: String = "", frames: [EmulatorFrame] = [], failing: @escaping @Sendable (Call) -> AndroidError? = { _ in nil }) {
        clipboardText = clipboard
        self.frames = frames
        failure = failing
    }

    var calls: [Call] { lock.withLock { recorded } }
    var clipboardNow: String { lock.withLock { clipboardText } }

    private func record(_ call: Call) throws {
        lock.withLock { recorded.append(call) }
        if let error = failure(call) { throw error }
    }

    func sendTouch(_ touch: PanelTouch) async throws { try record(.touch(touch)) }
    func sendKey(_ event: EmulatorKeyEvent) async throws { try record(.key(event)) }

    func screenshot(_ format: EmulatorImageFormat, fitting box: FrameBox?) async throws -> EmulatorFrame {
        try record(.screenshot(format, box))
        guard let frame = frames.first(where: { $0.format == format }) ?? frames.first else {
            throw AndroidError.grpcFailed(endpoint: endpoint, method: "getScreenshot", detail: "no frame scripted")
        }
        return frame
    }

    func screenshotStream(_ format: EmulatorImageFormat, fitting box: FrameBox?) -> AsyncThrowingStream<EmulatorFrame, any Error> {
        let frames = self.frames
        let error = failure(.stream(format, box))
        lock.withLock { recorded.append(.stream(format, box)) }
        return AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish(throwing: error)
        }
    }

    func clipboard() async throws -> String {
        try record(.getClipboard)
        return clipboardNow
    }

    func setClipboard(_ text: String) async throws {
        try record(.setClipboard(text))
        lock.withLock { clipboardText = text }
    }

    func close() async {
        lock.withLock { recorded.append(.close) }
    }
}

/// Hands out one fake endpoint, or fails every connection with a scripted error.
final class FakeEmulatorConnector: EmulatorConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(port: Int?, issuer: String)] = []
    private let outcome: Result<FakeEmulator, AndroidError>

    init(_ outcome: Result<FakeEmulator, AndroidError>) {
        self.outcome = outcome
    }

    static var refusing: FakeEmulatorConnector { FakeEmulatorConnector(.failure(.grpcUnavailable(port: 8556))) }

    var connections: [(port: Int?, issuer: String)] { lock.withLock { recorded } }

    func connect(discovery: EmulatorDiscovery, auth: EmulatorAuth) async throws -> any EmulatorControlling {
        lock.withLock { recorded.append((discovery.grpcPort, auth.issuer)) }
        return try outcome.get()
    }
}

/// Collects `AndroidLog` lines so tests can assert on warnings.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(AndroidLogLevel, String)] = []

    var log: AndroidLog { { level, message in self.lock.withLock { self.lines.append((level, message)) } } }
    var warnings: [String] { lock.withLock { lines.filter { $0.0 == .warning }.map(\.1) } }
}
