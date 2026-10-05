import Darwin
import Foundation

/// usbmuxd over its Unix socket: lists devices and opens raw TCP streams to a port on a USB-connected device.
public struct UsbmuxClient: Sendable {
    public static let defaultSocketPath = "/var/run/usbmuxd"

    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String = UsbmuxClient.defaultSocketPath, timeout: TimeInterval = 5) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func listDevices() throws -> [UsbmuxDevice] {
        let descriptor = try open()
        defer { Darwin.close(descriptor) }
        let reply = try exchange(.listDevices, tag: 1, on: descriptor)
        return try UsbmuxReply.devices(reply)
    }

    /// A descriptor streaming to `port` on the device; only a `USB` row is ever connected. The caller closes it.
    public func connect(udid: String, port: UInt16) throws -> Int32 {
        let rows = try listDevices().filter { $0.matches(udid) }
        guard let row = rows.first(where: { $0.connectionType == "USB" }) else {
            throw rows.isEmpty ? UsbmuxError.notAttached : UsbmuxError.notOnUSB
        }
        let descriptor = try open()
        do {
            let number = try UsbmuxReply.result(try exchange(.connect(deviceID: row.deviceID, port: port), tag: 2, on: descriptor))
            guard number == 0 else { throw UsbmuxError.result(number) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func exchange(_ request: UsbmuxRequest, tag: UInt32, on descriptor: Int32) throws -> Data {
        try UsbmuxSocket.writeAll(UsbmuxFrame(tag: tag, payload: try request.payload()).encoded(), to: descriptor)
        let headerBytes = try UsbmuxSocket.read(exactly: UsbmuxFrame.headerSize, from: descriptor)
        let header = try UsbmuxFrame.header(headerBytes)
        let payload = try UsbmuxSocket.read(exactly: Int(header.length) - UsbmuxFrame.headerSize, from: descriptor)
        return try UsbmuxFrame.decode(headerBytes + payload).payload
    }

    func open() throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { throw UsbmuxError.socketUnavailable("\(socketPath) is too long for a socket path") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UsbmuxError.socketUnavailable(String(cString: strerror(errno))) }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        UsbmuxSocket.setTimeouts(descriptor, seconds: timeout)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw UsbmuxError.socketUnavailable("\(socketPath): \(detail)")
        }
        return descriptor
    }
}

/// Blocking reads and writes with the socket's own send and receive timeouts.
enum UsbmuxSocket {
    static func setTimeouts(_ descriptor: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var value = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw (errno == EAGAIN || errno == EWOULDBLOCK) ? UsbmuxError.timedOut : UsbmuxError.closed
                }
            }
        }
    }

    /// Up to `limit` bytes, or nil at end of stream.
    static func readSome(from descriptor: Int32, limit: Int) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            let count = Darwin.read(descriptor, &buffer, limit)
            if count > 0 { return Data(buffer.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            throw (errno == EAGAIN || errno == EWOULDBLOCK) ? UsbmuxError.timedOut : UsbmuxError.closed
        }
    }

    static func read(exactly count: Int, from descriptor: Int32) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try readSome(from: descriptor, limit: count - data.count) else { throw UsbmuxError.closed }
            data.append(chunk)
        }
        return data
    }
}
