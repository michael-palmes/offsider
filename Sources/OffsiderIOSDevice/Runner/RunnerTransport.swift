import Darwin
import Foundation

/// One HTTP exchange with the runner on a fresh connection; blocking, bounded by `timeout`.
public protocol RunnerTransport: Sendable {
    func exchange(method: String, path: String, token: String, body: Data?, timeout: TimeInterval) throws -> UsbmuxHTTPResponse
    /// Maps a transport failure to what the user sees.
    func error(for failure: UsbmuxError, udid: String) -> IOSDeviceError
}

/// A phone: usbmuxd opens a stream to the runner's loopback port on the device.
public struct UsbmuxRunnerTransport: RunnerTransport {
    let udid: String
    let port: UInt16
    let client: UsbmuxClient

    public init(udid: String, port: UInt16, client: UsbmuxClient = UsbmuxClient()) {
        self.udid = udid
        self.port = port
        self.client = client
    }

    public func exchange(method: String, path: String, token: String, body: Data?, timeout: TimeInterval) throws -> UsbmuxHTTPResponse {
        let descriptor = try client.connect(udid: udid, port: port)
        defer { Darwin.close(descriptor) }
        UsbmuxHTTP.setTimeout(descriptor, seconds: timeout)
        return try UsbmuxHTTP.exchange(on: descriptor, method: method, path: path, token: token, body: body)
    }

    public func error(for failure: UsbmuxError, udid: String) -> IOSDeviceError {
        .runner(failure, udid: udid)
    }
}

/// A simulator shares the Mac's loopback, so the runner is plain TCP on 127.0.0.1.
public struct LoopbackRunnerTransport: RunnerTransport {
    let port: UInt16

    public init(port: UInt16) {
        self.port = port
    }

    public func exchange(method: String, path: String, token: String, body: Data?, timeout: TimeInterval) throws -> UsbmuxHTTPResponse {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UsbmuxError.socketUnavailable(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        UsbmuxHTTP.setTimeout(descriptor, seconds: timeout)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard status == 0 else { throw UsbmuxError.result(3) }
        return try UsbmuxHTTP.exchange(on: descriptor, method: method, path: path, token: token, body: body)
    }

    public func error(for failure: UsbmuxError, udid: String) -> IOSDeviceError {
        switch failure {
        case .result, .socketUnavailable: return IOSDeviceError.runnerNotListening(udid)
        default: return .runner(failure, udid: udid)
        }
    }
}
