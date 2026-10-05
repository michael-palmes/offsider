import Darwin
import Foundation
import OffsiderCore

/// One step of broker-timed input: a contact at a fraction of the panel, a key, or a pause.
public struct DeviceSessionStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case down
        case move
        case up
        case keyDown
        case keyUp
        case wait
    }

    public var kind: Kind
    /// UI points; the broker maps them onto the touchscreen with the panel's current orientation.
    public var x: Double?
    public var y: Double?
    public var usage: UInt32?
    public var seconds: Double?

    public init(kind: Kind, x: Double? = nil, y: Double? = nil, usage: UInt32? = nil, seconds: Double? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.usage = usage
        self.seconds = seconds
    }

    public static func touch(_ kind: Kind, x: Double, y: Double) -> Self { Self(kind: kind, x: x, y: y) }
    public static func key(_ usage: UInt32, down: Bool) -> Self { Self(kind: down ? .keyDown : .keyUp, usage: usage) }
    public static func wait(_ seconds: Double) -> Self { Self(kind: .wait, seconds: seconds) }
}

/// What a command asks of a device's session broker.
public enum DeviceSessionRequest: Equatable, Sendable {
    case ping
    case frame(IOSDeviceScreenFrame.Format)
    /// Down, a hold in the broker, then up; the broker never leaves a button down after a request.
    case press(usagePage: UInt64, usageCode: UInt64, hold: Double)
    case touch([DeviceSessionStep])
    case keys([DeviceSessionStep])
    case text(String)
    case stop

    public var op: String {
        switch self {
        case .ping: return "ping"
        case .frame: return "frame"
        case .press: return "press"
        case .touch: return "touch"
        case .keys: return "keys"
        case .text: return "text"
        case .stop: return "stop"
        }
    }

    /// Input reaches the device, so a lost reply leaves its outcome unknown.
    public var sendsInput: Bool {
        switch self {
        case .press, .touch, .keys, .text: return true
        case .ping, .frame, .stop: return false
        }
    }

    struct Envelope: Codable, Equatable {
        var id: Int
        var op: String
        var format: String?
        var usagePage: UInt64?
        var usageCode: UInt64?
        var hold: Double?
        var steps: [DeviceSessionStep]?
        var text: String?
    }

    func envelope(id: Int) -> Envelope {
        var envelope = Envelope(id: id, op: op)
        switch self {
        case .ping, .stop:
            break
        case .frame(let format):
            envelope.format = format.wireName
        case let .press(page, code, hold):
            envelope.usagePage = page
            envelope.usageCode = code
            envelope.hold = hold
        case .touch(let steps), .keys(let steps):
            envelope.steps = steps
        case .text(let text):
            envelope.text = text
        }
        return envelope
    }

    init(_ envelope: Envelope) throws {
        func need<T>(_ value: T?, _ field: String) throws -> T {
            guard let value else { throw DeviceSessionWireError(detail: "`\(envelope.op)` without `\(field)`") }
            return value
        }
        switch envelope.op {
        case "ping": self = .ping
        case "stop": self = .stop
        case "frame":
            let name = try need(envelope.format, "format")
            guard let format = IOSDeviceScreenFrame.Format(wireName: name) else { throw DeviceSessionWireError(detail: "an unknown frame format `\(name)`") }
            self = .frame(format)
        case "press":
            self = .press(usagePage: try need(envelope.usagePage, "usagePage"), usageCode: try need(envelope.usageCode, "usageCode"), hold: try need(envelope.hold, "hold"))
        case "touch": self = .touch(try need(envelope.steps, "steps"))
        case "keys": self = .keys(try need(envelope.steps, "steps"))
        case "text": self = .text(try need(envelope.text, "text"))
        default: throw DeviceSessionWireError(detail: "an unknown op `\(envelope.op)`")
        }
    }
}

extension IOSDeviceScreenFrame.Format {
    var wireName: String {
        switch self {
        case .jpeg: return "jpeg"
        case .png: return "png"
        case .bgra: return "bgra"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "jpeg": self = .jpeg
        case "png": self = .png
        case "bgra": self = .bgra
        default: return nil
        }
    }
}

/// The broker's stream as `ping` reports it.
public struct DeviceSessionStreamStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case opening
        case live
        case failed
        case closed
    }

    public var state: State
    public var detail: String?
    public var width: Int?
    public var height: Int?
    public var framesReceived: Int?

    public init(state: State, detail: String? = nil, width: Int? = nil, height: Int? = nil, framesReceived: Int? = nil) {
        self.state = state
        self.detail = detail
        self.width = width
        self.height = height
        self.framesReceived = framesReceived
    }
}

/// A refusal from the broker, rebuilt as the `IOSDeviceError` it was.
public struct DeviceSessionFailure: Codable, Equatable, Sendable {
    public var kind: String
    public var message: String
    public var hint: String?

    public init(_ error: Error) {
        if let error = error as? IOSDeviceError {
            kind = error.kind.rawValue
            message = error.message
            hint = error.explicitHint
        } else {
            kind = IOSDeviceError.Kind.sessionFailed.rawValue
            message = "The device session failed: \(error.localizedDescription)."
            hint = nil
        }
    }

    public var error: IOSDeviceError {
        IOSDeviceError(IOSDeviceError.Kind(rawValue: kind) ?? .sessionFailed, message, hint: hint)
    }
}

/// Every reply; `bytes` announces one binary frame that follows it.
public struct DeviceSessionReply: Codable, Equatable, Sendable {
    public var id: Int
    public var ok: Bool
    public var error: DeviceSessionFailure?
    public var bytes: Int?
    public var width: Int?
    public var height: Int?
    public var format: String?
    public var `protocol`: Int?
    public var pid: Int32?
    public var udid: String?
    /// The device's model label, so a command with a live broker skips listing devices.
    public var label: String?
    /// The main display as the broker last read it, at most a couple of seconds old while it is in use.
    public var geometry: IOSDeviceGeometry?
    public var stream: DeviceSessionStreamStatus?
    /// True when the broker sends touches and keys itself.
    public var touch: Bool?
    public var idleSeconds: Int?

    public init(id: Int, ok: Bool = true) {
        self.id = id
        self.ok = ok
    }

    public static func failure(id: Int, _ error: Error) -> Self {
        var reply = Self(id: id, ok: false)
        reply.error = DeviceSessionFailure(error)
        return reply
    }
}

struct DeviceSessionWireError: Error, Equatable, Sendable {
    let detail: String
}

/// The broker's framing, as the Android helper's: a 4-byte big-endian length, then that many bytes.
enum DeviceSessionWire {
    static let protocolVersion = 1
    static let maxJSONBytes = 1 << 20
    static let maxPayloadBytes = 128 << 20

    static func frame(_ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + payload
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encode(_ request: DeviceSessionRequest, id: Int) throws -> Data {
        frame(try encoder.encode(request.envelope(id: id)))
    }

    static func decodeRequest(_ payload: Data) throws -> (id: Int, request: DeviceSessionRequest) {
        let envelope: DeviceSessionRequest.Envelope
        do {
            envelope = try JSONDecoder().decode(DeviceSessionRequest.Envelope.self, from: payload)
        } catch {
            throw DeviceSessionWireError(detail: "an unreadable request")
        }
        return (envelope.id, try DeviceSessionRequest(envelope))
    }
}

/// A connected stream socket carrying length-prefixed frames; reads and writes block up to a deadline.
final class DeviceSessionChannel: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }

    /// True once the peer has closed its end; peeks without consuming or blocking.
    func peerClosed() -> Bool {
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)
    }

    func write(_ data: Data, timeout: Duration? = .seconds(5)) throws {
        setTimeout(SO_SNDTIMEO, timeout)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw DeviceSessionWireError(detail: errno == EAGAIN ? "the write timed out" : "the write failed: \(String(cString: strerror(errno)))")
                }
                offset += count
            }
        }
    }

    /// One frame's payload; nil when the peer closed cleanly before a new frame began.
    func readFrame(limit: Int, timeout: Duration?) throws -> Data? {
        setTimeout(SO_RCVTIMEO, timeout)
        guard let header = try readExactly(4, allowEOF: true) else { return nil }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length <= limit else { throw DeviceSessionWireError(detail: "a frame of \(length) bytes, more than \(limit)") }
        return try readExactly(length, allowEOF: false) ?? Data()
    }

    private func readExactly(_ count: Int, allowEOF: Bool) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let read = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if read < 0 {
                if errno == EINTR { continue }
                throw DeviceSessionWireError(detail: errno == EAGAIN ? "the reply timed out" : "the read failed: \(String(cString: strerror(errno)))")
            }
            if read == 0 {
                if offset == 0, allowEOF { return nil }
                throw DeviceSessionWireError(detail: "the connection closed mid-frame")
            }
            offset += read
        }
        return data
    }

    private func setTimeout(_ option: Int32, _ timeout: Duration?) {
        var value = timeval()
        if let timeout {
            let (seconds, attoseconds) = timeout.components
            value = timeval(tv_sec: Int(max(seconds, 0)), tv_usec: Int32(max(attoseconds / 1_000_000_000_000, seconds == 0 ? 1000 : 0)))
        }
        setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// A connected Unix stream socket to `path`.
    static func connect(to path: String) throws -> DeviceSessionChannel {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DeviceSessionWireError(detail: "no socket: \(String(cString: strerror(errno)))") }
        var address = try unixAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw DeviceSessionConnectError(code: code)
        }
        return DeviceSessionChannel(descriptor: descriptor)
    }

    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw DeviceSessionWireError(detail: "the socket path \(path) is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}

/// Nothing accepted the connection: no broker is listening there.
struct DeviceSessionConnectError: Error, Equatable, Sendable {
    let code: Int32
}
