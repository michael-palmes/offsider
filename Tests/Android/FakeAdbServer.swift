import Foundation
@testable import OffsiderAndroid

/// An in-memory adb server: each request gets the reply the handler scripts for it.
final class FakeAdbServer: AdbConnecting, @unchecked Sendable {
    enum Reply {
        case bytes(Data, thenClose: Bool)
        case hang
    }

    enum ConnectBehaviour {
        case accept
        case refuse
        case timeOut
    }

    struct Request: Equatable {
        let serial: String?
        let service: String
    }

    private let lock = NSLock()
    private var refusalsLeft: Int
    private var connectBehaviour: ConnectBehaviour
    private var recorded: [Request] = []
    private var opened = 0
    private var closed = 0
    let maxReadChunk: Int
    let handler: @Sendable (Request) -> Reply

    init(
        refusingFirst refusals: Int = 0,
        connect: ConnectBehaviour = .accept,
        maxReadChunk: Int = .max,
        handler: @escaping @Sendable (Request) -> Reply
    ) {
        refusalsLeft = refusals
        connectBehaviour = connect
        self.maxReadChunk = maxReadChunk
        self.handler = handler
    }

    var requests: [Request] { lock.withLock { recorded } }
    var connectionAttempts: Int { lock.withLock { opened } }
    var closedStreams: Int { lock.withLock { closed } }
    var services: [String] { requests.map(\.service) }

    func connect(to endpoint: LoopbackEndpoint, timeout: Duration) async throws -> any AdbByteStream {
        try lock.withLock {
            opened += 1
            if refusalsLeft > 0 {
                refusalsLeft -= 1
                throw AdbConnectError.refused
            }
            switch connectBehaviour {
            case .accept: break
            case .refuse: throw AdbConnectError.refused
            case .timeOut: throw AdbConnectError.timedOut
            }
        }
        return FakeAdbStream(server: self)
    }

    fileprivate func record(_ request: Request) -> Reply {
        lock.withLock { recorded.append(request) }
        return handler(request)
    }

    fileprivate func noteClosed() {
        lock.withLock { closed += 1 }
    }

    // MARK: Reply builders

    static func okay(payload: String) -> Reply {
        let body = Data(payload.utf8)
        return .bytes(Data("OKAY".utf8) + Data(String(format: "%04x", body.count).utf8) + body, thenClose: true)
    }

    static let okay = Reply.bytes(Data("OKAY".utf8), thenClose: false)

    static func fail(_ message: String) -> Reply {
        let body = Data(message.utf8)
        return .bytes(Data("FAIL".utf8) + Data(String(format: "%04x", body.count).utf8) + body, thenClose: true)
    }

    static func shell(stdout: String = "", stderr: String = "", status: UInt8 = 0) -> Reply {
        var bytes = Data("OKAY".utf8)
        if !stdout.isEmpty { bytes += packet(1, Data(stdout.utf8)) }
        if !stderr.isEmpty { bytes += packet(2, Data(stderr.utf8)) }
        bytes += packet(3, Data([status]))
        return .bytes(bytes, thenClose: true)
    }

    static func exec(_ output: Data) -> Reply {
        .bytes(Data("OKAY".utf8) + output, thenClose: true)
    }

    static func packet(_ id: UInt8, _ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([id, UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)]) + payload
    }

    /// Replies OKAY to transports for `serials` and FAIL "device 'x' not found" for others; `device` answers the rest.
    static func devices(
        _ serials: Set<String>,
        host: @escaping @Sendable (String) -> Reply = { _ in .hang },
        device: @escaping @Sendable (_ serial: String, _ service: String) -> Reply
    ) -> @Sendable (Request) -> Reply {
        { request in
            if request.service.hasPrefix("host:transport:") {
                let serial = String(request.service.dropFirst("host:transport:".count))
                return serials.contains(serial) ? okay : fail("device '\(serial)' not found")
            }
            guard let serial = request.serial else { return host(request.service) }
            return device(serial, request.service)
        }
    }
}

final class FakeAdbStream: AdbByteStream, @unchecked Sendable {
    private let server: FakeAdbServer
    private let lock = NSLock()
    private var inbound = Data()
    private var outbound = Data()
    private var endOfStream = false
    private var transportSerial: String?

    init(server: FakeAdbServer) {
        self.server = server
    }

    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        var requests: [FakeAdbServer.Request] = []
        lock.withLock {
            inbound.append(data)
            while inbound.count >= 4,
                  let length = Int(String(decoding: inbound.prefix(4), as: UTF8.self), radix: 16),
                  inbound.count >= 4 + length {
                let service = String(decoding: inbound.dropFirst(4).prefix(length), as: UTF8.self)
                inbound = Data(inbound.dropFirst(4 + length))
                requests.append(FakeAdbServer.Request(serial: transportSerial, service: service))
                if service.hasPrefix("host:transport:") {
                    transportSerial = String(service.dropFirst("host:transport:".count))
                }
            }
        }
        for request in requests {
            let reply = server.record(request)
            lock.withLock {
                switch reply {
                case .bytes(let bytes, let thenClose):
                    outbound.append(bytes)
                    endOfStream = endOfStream || thenClose
                case .hang:
                    break
                }
            }
        }
    }

    func read(upTo count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        try lock.withLock {
            if !outbound.isEmpty {
                let chunk = Data(outbound.prefix(min(count, server.maxReadChunk)))
                outbound = Data(outbound.dropFirst(chunk.count))
                return chunk
            }
            if endOfStream { return Data() }
            throw AdbConnectError.timedOut
        }
    }

    func close() async {
        server.noteClosed()
    }
}
