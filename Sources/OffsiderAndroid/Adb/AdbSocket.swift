import Darwin
import Foundation

/// Why a connection to the adb server failed; `refused` and `noSuchSocket` mean no server is listening.
enum AdbConnectError: Error, Equatable, Sendable {
    case refused
    case noSuchSocket
    case timedOut
    case failed(errno: Int32)
}

protocol AdbByteStream: Sendable {
    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws
    /// Up to `count` bytes; empty at end of stream.
    func read(upTo count: Int, deadline: ContinuousClock.Instant) async throws -> Data
    func close() async
}

protocol AdbConnecting: Sendable {
    func connect(to endpoint: LoopbackEndpoint, timeout: Duration) async throws -> any AdbByteStream
}

/// BSD sockets on numeric loopback addresses or a Unix path; there is no code path that resolves a name.
struct PosixAdbConnector: AdbConnecting {
    func connect(to endpoint: LoopbackEndpoint, timeout: Duration) async throws -> any AdbByteStream {
        let deadline = ContinuousClock.now + timeout
        return try await PosixAdbStream.onQueue(DispatchQueue(label: "offsider.adb.connect")) {
            try PosixAdbStream.open(endpoint, deadline: deadline)
        }
    }
}

final class PosixAdbStream: AdbByteStream, @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "offsider.adb.socket")
    private var isClosed = false

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        if !isClosed {
            Darwin.close(fd)
        }
    }

    static func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    static func open(_ endpoint: LoopbackEndpoint, deadline: ContinuousClock.Instant) throws -> PosixAdbStream {
        let family: Int32
        switch endpoint {
        case .tcp(.ipv4, _): family = AF_INET
        case .tcp(.ipv6, _): family = AF_INET6
        case .unix: family = AF_UNIX
        }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbConnectError.failed(errno: errno) }
        let stream = PosixAdbStream(fd: fd)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let result = try withSocketAddress(endpoint) { address, length in Darwin.connect(fd, address, length) }
        if result != 0 {
            let code = errno
            guard code == EINPROGRESS else { throw mapConnectError(code) }
            guard try stream.wait(for: Int16(POLLOUT), until: deadline) else { throw AdbConnectError.timedOut }
            var pending: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length)
            if pending != 0 { throw mapConnectError(pending) }
        }
        return stream
    }

    private static func mapConnectError(_ code: Int32) -> AdbConnectError {
        switch code {
        case ECONNREFUSED: return .refused
        case ENOENT: return .noSuchSocket
        case ETIMEDOUT: return .timedOut
        default: return .failed(errno: code)
        }
    }

    private static func withSocketAddress<R>(
        _ endpoint: LoopbackEndpoint,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) throws -> R {
        switch endpoint {
        case .tcp(let host, let port):
            if host == .ipv4 {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                guard inet_pton(AF_INET, host.rawValue, &address.sin_addr) == 1 else { throw AdbConnectError.failed(errno: EINVAL) }
                return withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, host.rawValue, &address.sin6_addr) == 1 else { throw AdbConnectError.failed(errno: EINVAL) }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        case .unix(let path):
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw AdbConnectError.failed(errno: ENAMETOOLONG) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
    }

    /// True when the socket is ready, false when the deadline passed first.
    private func wait(for events: Int16, until deadline: ContinuousClock.Instant) throws -> Bool {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            let (seconds, attoseconds) = remaining.components
            let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000 + 1)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { throw AdbConnectError.failed(errno: errno) }
        }
    }

    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        try await Self.onQueue(queue) { [self] in
            var offset = 0
            while offset < data.count {
                guard !isClosed else { throw AdbConnectError.failed(errno: EBADF) }
                guard try wait(for: Int16(POLLOUT), until: deadline) else { throw AdbConnectError.timedOut }
                let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
                if written > 0 {
                    offset += written
                } else if written < 0, errno != EAGAIN, errno != EINTR {
                    throw AdbConnectError.failed(errno: errno)
                }
            }
        }
    }

    func read(upTo count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        try await Self.onQueue(queue) { [self] in
            var buffer = [UInt8](repeating: 0, count: max(1, count))
            while true {
                guard !isClosed else { throw AdbConnectError.failed(errno: EBADF) }
                guard try wait(for: Int16(POLLIN), until: deadline) else { throw AdbConnectError.timedOut }
                let received = Darwin.read(fd, &buffer, buffer.count)
                if received >= 0 { return Data(buffer.prefix(received)) }
                if errno != EAGAIN, errno != EINTR { throw AdbConnectError.failed(errno: errno) }
            }
        }
    }

    func close() async {
        _ = try? await Self.onQueue(queue) { [self] in
            if !isClosed {
                isClosed = true
                Darwin.close(fd)
            }
        }
    }
}
