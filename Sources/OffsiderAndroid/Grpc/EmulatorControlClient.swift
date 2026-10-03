import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

/// Plaintext HTTP/2 over Network.framework to the emulator's loopback gRPC port, with per-call credentials.
actor EmulatorControlClient: EmulatorControlling {
    typealias Stub = Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.TransportServices>

    enum Address: Sendable {
        case ipv4
        case ipv6
    }

    nonisolated let endpoint: String
    private let discovery: EmulatorDiscovery
    private let auth: EmulatorAuth
    private nonisolated let grpc: GRPCClient<HTTP2ClientTransport.TransportServices>

    init(address: Address, port: Int, discovery: EmulatorDiscovery, auth: EmulatorAuth) throws {
        let transport: HTTP2ClientTransport.TransportServices
        switch address {
        case .ipv4:
            transport = try HTTP2ClientTransport.TransportServices(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: .plaintext)
            endpoint = "127.0.0.1:\(port)"
        case .ipv6:
            transport = try HTTP2ClientTransport.TransportServices(target: .ipv6(address: "::1", port: port), transportSecurity: .plaintext)
            endpoint = "[::1]:\(port)"
        }
        let grpc = GRPCClient(transport: transport)
        Task { try? await grpc.runConnections() }
        self.grpc = grpc
        self.discovery = discovery
        self.auth = auth
    }

    /// `waitForReady` off, so a dead endpoint fails at once; 64 MiB both ways, since a full RGBA frame is about 10 MB.
    static func options(timeout: Duration?) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        options.maxRequestMessageBytes = 64 << 20
        options.maxResponseMessageBytes = 64 << 20
        return options
    }

    func status() async throws -> EmulatorStatusSummary {
        let status = try await call(.getStatus, timeout: .seconds(2)) { stub, metadata, options in
            try await stub.getStatus(Google_Protobuf_Empty(), metadata: metadata, options: options)
        }
        return EmulatorStatusSummary(version: status.version, booted: status.booted, uptimeMilliseconds: status.uptime)
    }

    func sendTouch(_ touch: PanelTouch) async throws {
        let event = Self.touchEvent(touch)
        _ = try await call(.sendTouch, timeout: .seconds(2)) { stub, metadata, options in
            try await stub.sendTouch(event, metadata: metadata, options: options)
        }
    }

    func sendKey(_ event: EmulatorKeyEvent) async throws {
        let message = Self.keyboardEvent(event)
        _ = try await call(.sendKey, timeout: .seconds(2)) { stub, metadata, options in
            try await stub.sendKey(message, metadata: metadata, options: options)
        }
    }

    func screenshot(_ format: EmulatorImageFormat, fitting box: FrameBox?) async throws -> EmulatorFrame {
        let request = Self.imageFormat(format, fitting: box)
        let image = try await call(.getScreenshot, timeout: .seconds(5)) { stub, metadata, options in
            try await stub.getScreenshot(request, metadata: metadata, options: options)
        }
        guard let frame = Self.frame(from: image) else {
            throw AndroidError.grpcFailed(endpoint: endpoint, method: EmulatorMethod.getScreenshot.rawValue, detail: "the emulator sent an empty image; its display may be off")
        }
        return frame
    }

    /// Empty frames (a display that is off or not yet drawn) are skipped, not sent on.
    nonisolated func screenshotStream(_ format: EmulatorImageFormat, fitting box: FrameBox?) -> AsyncThrowingStream<EmulatorFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamFrames(format, fitting: box) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func clipboard() async throws -> String {
        try await call(.getClipboard, timeout: .seconds(2)) { stub, metadata, options in
            try await stub.getClipboard(Google_Protobuf_Empty(), metadata: metadata, options: options)
        }.text
    }

    func setClipboard(_ text: String) async throws {
        var clip = Android_Emulation_Control_ClipData()
        clip.text = text
        _ = try await call(.setClipboard, timeout: .seconds(2)) { stub, metadata, options in
            try await stub.setClipboard(clip, metadata: metadata, options: options)
        }
    }

    func setPosture(_ posture: EmulatorPosture) async throws {
        let message = Self.postureMessage(posture)
        _ = try await call(.setPosture, timeout: .seconds(2)) { stub, metadata, options in
            try await stub.setPosture(message, metadata: metadata, options: options)
        }
    }

    func currentPosture(timeout: Duration) async throws -> EmulatorPosture? {
        do {
            return try await call(.streamNotification, timeout: timeout) { stub, metadata, options in
                try await stub.streamNotification(Google_Protobuf_Empty(), metadata: metadata, options: options) { response in
                    for try await notification in response.messages {
                        if case .posture(let posture) = notification.type {
                            return EmulatorControlClient.posture(from: posture)
                        }
                    }
                    return nil
                }
            }
        } catch let error as AndroidError where error.kind == .grpcDeadlineExceeded {
            return nil
        }
    }

    func close() async {
        shutdown()
        auth.close()
    }

    /// Stops the connection but keeps the signing key, for a probe that moves on to the other address.
    nonisolated func shutdown() {
        grpc.beginGracefulShutdown()
    }

    private func streamFrames(_ format: EmulatorImageFormat, fitting box: FrameBox?, _ yield: @escaping @Sendable (EmulatorFrame) -> Void) async throws {
        let request = Self.imageFormat(format, fitting: box)
        try await call(.streamScreenshot, timeout: nil) { stub, metadata, options in
            try await stub.streamScreenshot(request, metadata: metadata, options: options) { response in
                for try await image in response.messages {
                    if let frame = EmulatorControlClient.frame(from: image) {
                        yield(frame)
                    }
                }
            }
        }
    }

    private func call<Result: Sendable>(
        _ method: EmulatorMethod,
        timeout: Duration?,
        _ body: (Stub, Metadata, CallOptions) async throws -> Result
    ) async throws -> Result {
        let metadata = try auth.metadata(for: method, now: Date())
        do {
            return try await body(Stub(wrapping: grpc), metadata, Self.options(timeout: timeout))
        } catch let error as RPCError {
            throw EmulatorRPCErrors.map(error, method: method, endpoint: endpoint, discovery: discovery, issuer: auth.issuer, timeout: timeout ?? .seconds(0))
        } catch let error as AndroidError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AndroidError.grpcFailed(endpoint: endpoint, method: method.rawValue, detail: EmulatorRPCErrors.redacted(String(describing: error), discovery: discovery))
        }
    }
}
