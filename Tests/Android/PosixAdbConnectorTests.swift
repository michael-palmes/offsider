import Darwin
import Foundation
import OffsiderCore
import Synchronization
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

    init(ipv6Loopback: Void) throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(fd, pointer, length) == 0 else { return -1 }
                return getsockname(fd, pointer, &length)
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        self.fd = fd
        endpoint = .tcp(.ipv6, port: UInt16(bigEndian: address.sin6_port))
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

/// Serialised, because a closed test port can be handed to the next listener; generous timeouts for a busy Mac.
@Suite("POSIX adb connector", .serialized)
struct PosixAdbConnectorTests {
    @Test("host:version round-trips over a Unix socket")
    func unixSocket() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oa-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock").path
        let listener = try OneShotListener(unixPath: path)
        listener.serveOnce(reply: "OKAY00040029")

        let version = try await AdbClient(endpoint: listener.endpoint, connector: PosixAdbConnector(ownerProbe: AdbServerOwnership.plainProbe), connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
        #expect(version == 41)
        withExtendedLifetime(listener) {}
    }

    @Test("a Unix socket whose server runs as another user is refused before any request")
    func foreignUnixSocket() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oa-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock").path
        let listener = try OneShotListener(unixPath: path)

        let connector = PosixAdbConnector(ownerUID: getuid() + 1)
        let error = await #expect(throws: AndroidError.self) {
            try await AdbClient(endpoint: listener.endpoint, connector: connector, connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
        }
        #expect(error?.kind == .foreignAdbServer)
        #expect(error?.reason == .adbServerMisconfigured)
        #expect(error?.message == "The adb server socket \(listener.endpoint) belongs to another user (uid \(getuid())), so Offsider did not use it. Point ADB_SERVER_SOCKET at a server you started, or unset it.")
        withExtendedLifetime(listener) {}
    }

    @Test("host:version round-trips over IPv4 loopback")
    func ipv4Loopback() async throws {
        let listener = try OneShotListener(ipv4Loopback: ())
        listener.serveOnce(reply: "OKAY00040029")

        let version = try await AdbClient(endpoint: listener.endpoint, connector: PosixAdbConnector(ownerProbe: AdbServerOwnership.plainProbe), connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
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

    @Test("host:version round-trips over IPv6 loopback, the accepting process checked as this user's")
    func ipv6Loopback() async throws {
        let listener = try OneShotListener(ipv6Loopback: ())
        listener.serveOnce(reply: "OKAY00040029")

        let version = try await AdbClient(endpoint: listener.endpoint, connector: PosixAdbConnector(ownerProbe: AdbServerOwnership.plainProbe), connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
        #expect(version == 41)
        #expect(AdbServerOwnership.server(for: listener.endpoint) == getpid())
        withExtendedLifetime(listener) {}
    }

    @Test("a TCP port whose connection no process of this user accepted is refused as another user's server, before any request")
    func foreignTCPListener() async throws {
        let listener = try OneShotListener(ipv4Loopback: ())
        listener.serveOnce(reply: "OKAY00040029")

        let connector = PosixAdbConnector(ownerUID: getuid() + 1, ownerProbe: AdbServerOwnership.plainProbe)
        let error = await #expect(throws: AndroidError.self) {
            try await AdbClient(endpoint: listener.endpoint, connector: connector, connectTimeout: .seconds(60), hostTimeout: .seconds(60)).serverVersion()
        }
        #expect(error?.kind == .foreignAdbServer)
        #expect(error?.reason == .adbServerMisconfigured)
        #expect(error?.message.hasPrefix("Another user's process answers on \(listener.endpoint), or your adb server did not accept within 2 s, so Offsider did not use it.") == true)
        withExtendedLifetime(listener) {}
    }

    @Test("the server's owner is checked on the first connection only, then remembered for the process")
    func ownerCheckedOncePerProcess() async throws {
        let first = try OneShotListener(ipv4Loopback: ())
        let calls = Mutex(0)
        let connector = PosixAdbConnector(ownerProbe: { descriptor, uid, wait in
            calls.withLock { $0 += 1 }
            return LoopbackOwner.acceptingProcess(of: descriptor, uid: uid, wait: wait)
        })
        let client = AdbClient(endpoint: first.endpoint, connector: connector, connectTimeout: .seconds(60), hostTimeout: .seconds(60))
        first.serveOnce(reply: "OKAY00040029")
        #expect(try await client.serverVersion() == 41)
        first.serveOnce(reply: "OKAY00040029")
        #expect(try await client.serverVersion() == 41)
        #expect(calls.withLock { $0 } == 1)
        withExtendedLifetime(first) {}
    }

    @Test("once the server the process checked has gone, the next connection is checked again")
    func ownerCheckedAgainAfterServerGoes() throws {
        let endpoint = LoopbackEndpoint.tcp(.ipv4, port: UInt16.random(in: 40000...59999))
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/sleep")
        server.arguments = ["30"]
        try server.run()
        let calls = Mutex(0)
        let probe: AdbServerOwnership.Probe = { _, _, _ in
            calls.withLock { $0 += 1 }
            return server.isRunning ? server.processIdentifier : getpid()
        }
        #expect(AdbServerOwnership.verify(-1, endpoint: endpoint, uid: getuid(), wait: .zero, probe: probe) == server.processIdentifier)
        #expect(AdbServerOwnership.verify(-1, endpoint: endpoint, uid: getuid(), wait: .zero, probe: probe) == server.processIdentifier)
        #expect(calls.withLock { $0 } == 1)
        server.terminate()
        server.waitUntilExit()
        #expect(AdbServerOwnership.verify(-1, endpoint: endpoint, uid: getuid(), wait: .zero, probe: probe) == getpid())
        #expect(calls.withLock { $0 } == 2)
    }
}
