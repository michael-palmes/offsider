import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OffsiderCore
import XPC

/// One decoded screen frame, encoded on request.
public struct IOSDeviceScreenFrame: Sendable {
    public enum Format: Sendable {
        case jpeg
        case png
        /// Tightly packed 8-bit BGRA rows, `width * 4` bytes each.
        case bgra
    }

    public let data: Data
    public let width: Int
    public let height: Int
    public let format: Format
}

/// A live CoreDevice screen stream from one wired device, decoded in this process as Xcode's screen sharing does.
/// While it runs, the device treats this client's HID services as authenticated.
@MainActor
public final class IOSDeviceScreenStream {
    nonisolated static let replyTimeoutSeconds: Double = 15
    nonisolated static let rtpTimeoutSeconds = 8
    nonisolated static let stopTimeoutSeconds: Double = 2
    /// `dtremotedisplayd`'s error when a foreground app holds the camera or microphone.
    nonisolated static let mediaInUseCode = 9022

    public let width: Int
    public let height: Int
    private let answer: MediaStreamAnswer
    private let socket: CoreDeviceServiceSocket
    private let video: MediaVideoStream
    private let rtp: Int32
    private let frames: FrameStore
    private let answeredAt: ContinuousClock.Instant
    private let target: Target
    private let timing: IOSDeviceTiming
    private var closed = false

    private struct Target {
        let deviceIdentifier: String
        let version: CoreDeviceVersion
        let name: String
        let udid: String
    }

    private init(
        answer: MediaStreamAnswer, socket: CoreDeviceServiceSocket, video: MediaVideoStream, rtp: Int32,
        frames: FrameStore, answeredAt: ContinuousClock.Instant, target: Target, timing: IOSDeviceTiming
    ) {
        self.answer = answer
        width = answer.width
        height = answer.height
        self.socket = socket
        self.video = video
        self.rtp = rtp
        self.frames = frames
        self.answeredAt = answeredAt
        self.target = target
        self.timing = timing
    }

    /// Opens the stream to `tunnelAddress`, the device's CoreDevice tunnel address from `devicectl`.
    public static func open(
        deviceIdentifier: String, version: CoreDeviceVersion, name: String, udid: String, tunnelAddress: String,
        timing: IOSDeviceTiming = .disabled
    ) async throws -> IOSDeviceScreenStream {
        let target = Target(deviceIdentifier: deviceIdentifier, version: version, name: name, udid: udid)
        return try await timing.measure("stream-open") {
            try await open(target, tunnelAddress: tunnelAddress, timing: timing)
        }
    }

    private static func open(_ target: Target, tunnelAddress: String, timing: IOSDeviceTiming) async throws -> IOSDeviceScreenStream {
        guard hasDisplay() else { throw IOSDeviceError.streamNeedsGUISession(target.name) }
        guard let host = TunnelEndpoint.host(forDevice: tunnelAddress, among: TunnelEndpoint.interfaces()) else {
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "this Mac has no CoreDevice tunnel interface for it")
        }
        let negotiator: MediaStreamNegotiator
        let offer: Data
        do {
            negotiator = try MediaStreamNegotiator()
            offer = try negotiator.offer()
        } catch let error as MediaStreamRuntimeError {
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: error.description)
        }
        let socket = try await openSocket(target, feature: MediaStreamAction.startFeature)
        let rtp: Int32
        let port: UInt16
        do {
            (rtp, port) = try bindReceiver(host)
        } catch {
            socket.cancel()
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "\(error)")
        }

        let session = UUID()
        let input = MediaStreamAction.startInput(receiverIP: host.address, receiverPort: port, senderIP: tunnelAddress, offer: offer, session: session)
        let reply = await request(socket, action: MediaStreamAction.start, input: input, target: target)
        let answeredAt = ContinuousClock.now
        let answer: MediaStreamAnswer
        do {
            answer = try startAnswer(reply, target: target)
        } catch {
            socket.cancel()
            Darwin.close(rtp)
            throw error
        }

        let frames = FrameStore()
        let delegate = MediaStreamDelegate(
            onFrame: { buffer in frames.offer(buffer) },
            onFailure: { detail in frames.fail(detail) }
        )
        do {
            let (configuration, options) = try negotiator.accept(answer.negotiatorAnswer)
            try await connectToFirstPacket(rtp)
            let video = try MediaVideoStream(socket: rtp, options: options, session: session, delegate: delegate)
            try video.configure(configuration)
            try video.start()
            return IOSDeviceScreenStream(
                answer: answer, socket: socket, video: video, rtp: rtp, frames: frames, answeredAt: answeredAt, target: target, timing: timing
            )
        } catch {
            socket.cancel()
            Darwin.close(rtp)
            await stop(answer.identifier, target: target)
            let detail = (error as? MediaStreamRuntimeError)?.description ?? "\(error)"
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: detail)
        }
    }

    /// True once the device has had the 0.3 s it needs to treat this client's input as authenticated.
    public var isAuthenticated: Bool {
        !closed && frames.failure == nil && MediaStreamReadiness.remaining(answeredAt: answeredAt, now: .now) == .zero
    }

    /// Returns once `isAuthenticated` holds; throws if the stream has failed.
    public func awaitReady() async throws {
        try checkLive()
        let remaining = MediaStreamReadiness.remaining(answeredAt: answeredAt, now: .now)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        try checkLive()
    }

    /// The newest decoded frame, waiting up to `timeout` for the first one.
    public func latestFrame(_ format: IOSDeviceScreenFrame.Format = .jpeg, timeout: Duration = .seconds(5)) async throws -> IOSDeviceScreenFrame {
        try await timing.measure("stream-frame") {
            let deadline = ContinuousClock.now + timeout
            while true {
                try checkLive()
                if let buffer = frames.latest, let pixels = CMSampleBufferGetImageBuffer(buffer) {
                    guard let frame = Self.encode(pixels, as: format) else {
                        throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "a frame could not be encoded")
                    }
                    return frame
                }
                guard ContinuousClock.now < deadline else {
                    throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "no frame arrived within \(timeout)")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Frames decoded so far; a still screen keeps sending them.
    public var framesReceived: Int { frames.received }

    /// Stops decoding, then ends this session on the device with a stop on a fresh connection, its only request.
    public func close() async {
        guard !closed else { return }
        closed = true
        video.stop()
        socket.cancel()
        Darwin.close(rtp)
        await Self.stop(answer.identifier, target: target)
    }

    private func checkLive() throws {
        if closed { throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "the stream is closed") }
        if let failure = frames.failure { throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: failure) }
    }

    private static func hasDisplay() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    private static func openSocket(_ target: Target, feature: String) async throws -> CoreDeviceServiceSocket {
        do {
            return try await CoreDeviceServiceSocket.open(deviceIdentifier: target.deviceIdentifier, feature: feature, version: target.version)
        } catch let failure as CoreDeviceServiceSocket.Failure {
            switch failure {
            case .refused(let error):
                throw IOSDeviceError.streamRefused(error, name: target.name, udid: target.udid)
            case .symbolsUnavailable:
                throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "this macOS has no RemoteXPC client")
            case .noDescriptor, .connectionFailed:
                throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "CoreDevice opened \(feature) without a usable socket")
            }
        }
    }

    /// Nil when the device did not answer in time.
    private static func request(_ socket: CoreDeviceServiceSocket, action: String, input: MediaStreamValue, target: Target, timeout: Double = replyTimeoutSeconds) async -> xpc_object_t? {
        let message = CoreDeviceServiceSocket.envelope(action: action, deviceIdentifier: target.deviceIdentifier, version: target.version, input: input.xpcObject)
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<xpc_object_t?, Never>) in
            socket.send(message) { reply in
                if once.claim() { continuation.resume(returning: reply) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private static func startAnswer(_ reply: xpc_object_t?, target: Target) throws -> MediaStreamAnswer {
        guard let reply else {
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "the device did not answer the stream start within \(Int(replyTimeoutSeconds)) s")
        }
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "the connection closed"
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: description)
        }
        if let error = xpc_dictionary_get_value(reply, "CoreDevice.error").flatMap(CoreDeviceErrorInfo.init(xpc:)) {
            throw IOSDeviceError.streamRefused(error, name: target.name, udid: target.udid)
        }
        guard let output = xpc_dictionary_get_value(reply, "CoreDevice.output").flatMap(MediaStreamValue.init(xpc:)) else {
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "the device sent no stream answer")
        }
        do {
            return try MediaStreamAnswer.parse(output)
        } catch let error as MediaStreamAnswer.ParseError {
            throw IOSDeviceError.streamFailed(target.name, udid: target.udid, detail: "the stream answer had \(error.detail)")
        }
    }

    private static func stop(_ identifier: UInt32, target: Target) async {
        guard let socket = try? await CoreDeviceServiceSocket.open(deviceIdentifier: target.deviceIdentifier, feature: MediaStreamAction.stopFeature, version: target.version) else { return }
        _ = await request(socket, action: MediaStreamAction.stop, input: MediaStreamAction.stopInput(identifier: identifier), target: target, timeout: stopTimeoutSeconds)
        socket.cancel()
    }

    private struct SocketError: Error, CustomStringConvertible {
        let description: String
    }

    /// A UDP socket on the Mac's tunnel address only, scoped to its `utun` interface.
    private static func bindReceiver(_ host: TunnelEndpoint.Interface) throws -> (Int32, UInt16) {
        let descriptor = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw SocketError(description: "no UDP socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_scope_id = if_nametoindex(host.name)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = inet_pton(AF_INET6, host.address, &address.sin6_addr) == 1 && withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
        }
        guard bound, address.sin6_port != 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw SocketError(description: "the tunnel address on \(host.name) could not be bound: \(detail)")
        }
        return (descriptor, UInt16(bigEndian: address.sin6_port))
    }

    /// Waits for the device's first RTP packet without consuming it, then connects the socket to its sender.
    private static func connectToFirstPacket(_ descriptor: Int32) async throws {
        let result: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var timeout = timeval(tv_sec: rtpTimeoutSeconds, tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var peer = sockaddr_in6()
                var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                var probe = [UInt8](repeating: 0, count: 4)
                let connected = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        recvfrom(descriptor, &probe, probe.count, MSG_PEEK, address, &length) > 0 && connect(descriptor, address, length) == 0
                    }
                }
                var none = timeval()
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
                continuation.resume(returning: connected ? 0 : errno)
            }
        }
        guard result == 0 else {
            throw SocketError(description: "no video packet arrived within \(rtpTimeoutSeconds) s (\(String(cString: strerror(result))))")
        }
    }

    private static let images = CIContext(options: [.cacheIntermediates: false])

    private static func encode(_ pixels: CVPixelBuffer, as format: IOSDeviceScreenFrame.Format) -> IOSDeviceScreenFrame? {
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let image = CIImage(cvImageBuffer: pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data: Data?
        switch format {
        case .jpeg:
            data = images.jpegRepresentation(of: image, colorSpace: space, options: [:])
        case .png:
            data = images.pngRepresentation(of: image, format: .RGBA8, colorSpace: space, options: [:])
        case .bgra:
            var bytes = Data(count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                images.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4, bounds: image.extent, format: .BGRA8, colorSpace: space)
            }
            data = bytes
        }
        return data.map { IOSDeviceScreenFrame(data: $0, width: width, height: height, format: format) }
    }
}

/// The newest sample buffer and any failure, written on the stream's delegate queue and read on the main actor.
private final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var slot = LatestFrameSlot<CMSampleBuffer>()
    private var failed: String?

    func offer(_ buffer: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard time.isNumeric else { return }
        lock.withLock { _ = slot.offer(buffer, timestamp: time.seconds) }
    }

    func fail(_ detail: String) {
        lock.withLock { if failed == nil { failed = detail } }
    }

    var latest: CMSampleBuffer? { lock.withLock { slot.frame } }
    var received: Int { lock.withLock { slot.received } }
    var failure: String? { lock.withLock { failed } }
}

extension IOSDeviceError {
    static func streamFailed(_ name: String, udid: String, detail: String) -> IOSDeviceError {
        IOSDeviceError(.streamFailed, "The screen stream from \(name) failed: \(detail). Retry; if it persists, run `offsider doctor --device \(udid)`.")
    }

    static func streamNeedsGUISession(_ name: String) -> IOSDeviceError {
        IOSDeviceError(
            .streamNeedsGUISession,
            "Streaming the screen of \(name) needs a logged-in macOS desktop session with a display, and this process has none (for example over ssh). Run Offsider from a terminal on the Mac's desktop, then retry."
        )
    }

    /// CoreDevice or the device refused to start or reach the stream.
    static func streamRefused(_ error: CoreDeviceErrorInfo, name: String, udid: String) -> IOSDeviceError {
        if error.isLocked { return locked(name, udid: udid, sent: false) }
        if error.chain.contains(where: { $0.code == IOSDeviceScreenStream.mediaInUseCode }) {
            return streamFailed(name, udid: udid, detail: "an app on it is using the camera or microphone, which blocks screen sharing; quit that app on the device")
        }
        if error.isTunnelDown { return streamFailed(name, udid: udid, detail: "the CoreDevice tunnel is down; reconnect its cable and unlock it") }
        return streamFailed(name, udid: udid, detail: error.summary)
    }
}
