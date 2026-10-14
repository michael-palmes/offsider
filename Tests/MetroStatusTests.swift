import Foundation
import Testing
@testable import Offsider

@Suite("Metro status")
struct MetroStatusTests {
    @Test("running is HTTP 200 with Metro's own body; anything else, or no answer, is a problem")
    func answers() async {
        let running = MetroStatus(fetch: { _, _ in (200, Data("packager-status:running".utf8)) })
        #expect(await running.problem(port: 8742) == nil)
        let other = MetroStatus(fetch: { _, _ in (200, Data("<html>".utf8)) })
        #expect(await other.problem(port: 8742) == "something else answered on that port")
        let refused = MetroStatus(fetch: { _, _ in throw URLError(.cannotConnectToHost) })
        #expect(await refused.problem(port: 8743) == "nothing answered within 2 s")
    }

    @Test("the request always goes to loopback, with a 2 s timeout")
    func loopbackOnly() async {
        let seen = Recorder()
        _ = await MetroStatus(fetch: { url, timeout in
            await seen.record(url, timeout)
            return (200, Data("packager-status:running".utf8))
        }).problem(port: 19000)
        let (url, timeout) = await seen.value
        #expect(url?.absoluteString == "http://127.0.0.1:19000/status")
        #expect(timeout == 2)
    }

    @Test("a redirect is never followed, even to loopback, and reads as something other than Metro")
    func redirectNotFollowed() async throws {
        let target = try LoopbackListener { _ in "HTTP/1.1 200 OK\r\nContent-Length: 23\r\nConnection: close\r\n\r\npackager-status:running" }
        let redirecting = try LoopbackListener { _ in
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        defer {
            target.stop()
            redirecting.stop()
        }
        // A generous timeout, so a busy test run cannot turn the redirect into no answer.
        let (status, _) = try await MetroStatus.liveFetch(MetroStatus.url(port: Int(redirecting.port)), 20)
        #expect(status == 302)
        #expect(redirecting.accepted == 1)
        #expect(target.accepted == 0)
        #expect(await MetroStatus(fetch: { _, _ in (302, Data()) }).problem(port: 8742) == "something else answered on that port (it redirected)")
    }

    actor Recorder {
        var value: (URL?, TimeInterval?) = (nil, nil)
        func record(_ url: URL, _ timeout: TimeInterval) { value = (url, timeout) }
    }
}

/// A one-thread HTTP responder on 127.0.0.1 that answers every connection with `reply` and counts them.
final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var count = 0
    private var stopped = false

    var accepted: Int { lock.withLock { count } }

    init(reply: @escaping @Sendable (String) -> String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        let descriptor = fd
        Thread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                lock.withLock { count += 1 }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let read = Darwin.read(client, &buffer, buffer.count)
                let answer = Array(reply(String(decoding: buffer.prefix(max(read, 0)), as: UTF8.self)).utf8)
                _ = Darwin.write(client, answer, answer.count)
                Darwin.close(client)
            }
        }.start()
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }
}
