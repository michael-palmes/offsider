import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Loopback owner: accepting process", .serialized)
struct LoopbackOwnerAcceptTests {
    /// A listener on 127.0.0.1 in this process, a client connected to it and the accepted end, all closed by `close`.
    struct Connection {
        let listener: Int32
        let client: Int32
        let accepted: Int32

        init() throws {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let listening = withUnsafeMutablePointer(to: &address) { pointer -> Bool in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
            }
            guard listening, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            let client = socket(AF_INET, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            self.listener = listener
            self.client = client
            accepted = accept(listener, nil, nil)
        }

        func close() {
            for descriptor in [accepted, client, listener] { Darwin.close(descriptor) }
        }
    }

    @Test("the process that accepted a loopback connection is found, a hint first or by a scan when the hint is wrong")
    func findsAcceptingProcess() throws {
        let connection = try Connection()
        defer { connection.close() }
        #expect(LoopbackOwner.acceptingProcess(of: connection.client) == getpid())
        #expect(LoopbackOwner.acceptingProcess(of: connection.client, preferring: getpid()) == getpid())
        #expect(LoopbackOwner.acceptingProcess(of: connection.client, preferring: 1) == getpid())
    }

    @Test("a hint never makes another user's port pass: the hinted process must run as that user and hold the socket")
    func hintCannotVouch() throws {
        let connection = try Connection()
        defer { connection.close() }
        #expect(LoopbackOwner.acceptingProcess(of: connection.client, uid: getuid() + 1, wait: .milliseconds(100), preferring: getpid()) == nil)
    }
}
