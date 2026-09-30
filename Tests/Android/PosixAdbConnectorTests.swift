import Darwin
import Foundation
import Testing
@testable import OffsiderAndroid

/// A one-shot listener on a socket this test owns, so the real connector is exercised without any adb server.
private final class OneShotListener: @unchecked Sendable {
    let fd: Int32
    let endpoint: LoopbackEndpoint

    init(unixPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(unixPath.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        self.fd = fd
        endpoint = .unix(path: unixPath)
    }

    init(ipv4Loopback: Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(fd, pointer, length) == 0 else { return -1 }
                return getsockname(fd, pointer, &length)
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        self.fd = fd
        endpoint = .tcp(.ipv4, port: UInt16(bigEndian: address.sin_port))
    }

    /// Accepts one client, reads one request, writes `reply`, then closes.
    func serveOnce(reply: String) {
        Thread.detachNewThread { [fd] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(client, &buffer, buffer.count)
            _ = Array(reply.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }

    deinit {
        close(fd)
        if case .unix(let path) = endpoint { unlink(path) }
    }
}

/// Generous timeouts: these use real threads and sockets, and a busy Mac can starve them for seconds.
@Suite("POSIX adb connector")
struct PosixAdbConnectorTests {
    @Test("host:version round-trips over a Unix socket")
    func unixSocket() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oa-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock").path
        let listener = try OneShotListener(unixPath: path)
        listener.serveOnce(reply: "OKAY00040029")

        let version = try await AdbClient(endpoint: listener.endpoint, connector: PosixAdbConnector(), connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
        #expect(version == 41)
        withExtendedLifetime(listener) {}
    }

    @Test("host:version round-trips over IPv4 loopback")
    func ipv4Loopback() async throws {
        let listener = try OneShotListener(ipv4Loopback: ())
        listener.serveOnce(reply: "OKAY00040029")

        let version = try await AdbClient(endpoint: listener.endpoint, connector: PosixAdbConnector(), connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
        #expect(version == 41)
        withExtendedLifetime(listener) {}
    }

    @Test("a missing Unix socket reads as no server running")
    func missingUnixSocket() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oa-missing-\(UUID().uuidString.prefix(8)).sock").path
        let error = await #expect(throws: AndroidError.self) {
            try await AdbClient(endpoint: .unix(path: path), connector: PosixAdbConnector(), connectTimeout: .seconds(60)).serverVersion()
        }
        #expect(error?.kind == .adbServerNotRunning)
    }

    @Test("a closed loopback port reads as no server running")
    func closedPort() async throws {
        let port: UInt16
        do {
            let listener = try OneShotListener(ipv4Loopback: ())
            guard case .tcp(_, let bound) = listener.endpoint else { return }
            port = bound
        }
        let error = await #expect(throws: AndroidError.self) {
            try await AdbClient(endpoint: .tcp(.ipv4, port: port), connector: PosixAdbConnector(), connectTimeout: .seconds(60)).serverVersion()
        }
        #expect(error?.kind == .adbServerNotRunning, "\(String(describing: error))")
    }
}
