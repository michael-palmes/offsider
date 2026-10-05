import Darwin
import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing

/// A usbmuxd stand-in on a Unix socket in a temp directory: answers each request with `reply`, then plays the runner after a `Connect`.
final class FakeUsbmuxd: @unchecked Sendable {
    enum Reply {
        case plist([String: Any])
        case silent
        case raw(Data)
    }

    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var requests: [[String: Any]] = []
    private var httpRequests: [Data] = []
    private let reply: @Sendable ([String: Any]) -> Reply
    private let httpReply: Data?

    init(reply: @escaping @Sendable ([String: Any]) -> Reply, httpReply: Data? = nil) throws {
        path = NSTemporaryDirectory() + "um-\(UUID().uuidString.prefix(8)).sock"
        self.reply = reply
        self.httpReply = httpReply
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = self.path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw UsbmuxError.socketUnavailable("bind \(path)") }
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    deinit {
        close(listener)
        unlink(path)
    }

    var received: [[String: Any]] { lock.withLock { requests } }
    var receivedHTTP: [Data] { lock.withLock { httpRequests } }

    private var stopped = false

    /// Ends the accept loop, which releases the server so its socket file is removed.
    func stop() {
        lock.withLock { stopped = true }
        unlink(path)
    }

    private func serve() {
        while !lock.withLock({ stopped }) {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 50) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            handle(connection)
        }
    }

    private func handle(_ connection: Int32) {
        guard let header = Self.read(connection, count: 16), let frameHeader = try? UsbmuxFrame.header(header),
              let payload = Self.read(connection, count: Int(frameHeader.length) - 16),
              let request = try? UsbmuxReply.dictionary(payload) else {
            close(connection)
            return
        }
        lock.withLock { requests.append(request) }
        let answer = reply(request)
        switch answer {
        case .silent:
            Thread.sleep(forTimeInterval: 1.5)
            close(connection)
            return
        case .raw(let bytes):
            Self.write(connection, bytes)
        case .plist(let dictionary):
            let data = try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            Self.write(connection, UsbmuxFrame(tag: frameHeader.tag, payload: data).encoded())
            if request["MessageType"] as? String == "Connect", dictionary["Number"] as? Int == 0, let httpReply {
                var received = Data()
                while received.range(of: Data("\r\n\r\n".utf8)) == nil, let chunk = Self.read(connection, count: 1) {
                    received.append(chunk)
                }
                if let length = Self.contentLength(received), length > 0, let body = Self.read(connection, count: length) {
                    received.append(body)
                }
                lock.withLock { httpRequests.append(received) }
                Self.write(connection, httpReply)
            }
        }
        close(connection)
    }

    private static func contentLength(_ head: Data) -> Int? {
        String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
    }

    static func read(_ descriptor: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while data.count < count {
            let got = Darwin.read(descriptor, &buffer, count - data.count)
            guard got > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(got))
        }
        return data
    }

    static func write(_ descriptor: Int32, _ data: Data) {
        data.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress!, data.count) }
    }

    static func deviceList(_ rows: [(id: Int, udid: String, type: String)]) -> [String: Any] {
        ["DeviceList": rows.map { row in
            ["DeviceID": row.id, "MessageType": "Attached", "Properties": ["ConnectionType": row.type, "DeviceID": row.id, "SerialNumber": row.udid]]
        }]
    }
}

@Suite("usbmux client", .serialized)
struct UsbmuxTests {
    static let udid = "00008130-0000000000000ABC"

    static func standard(result: Int = 0, rows: [(id: Int, udid: String, type: String)] = [(3, "00008130-0000000000000ABC", "USB")]) -> @Sendable ([String: Any]) -> FakeUsbmuxd.Reply {
        let list = FakeUsbmuxd.deviceList(rows)
        return { request in
            request["MessageType"] as? String == "ListDevices" ? .plist(list) : .plist(["MessageType": "Result", "Number": result])
        }
    }

    @Test("a frame round trips through its 16-byte little-endian header")
    func frameRoundTrip() throws {
        let frame = UsbmuxFrame(tag: 7, payload: Data("<plist/>".utf8))
        let bytes = frame.encoded()
        #expect(Array(bytes.prefix(16)) == [24, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 7, 0, 0, 0])
        #expect(try UsbmuxFrame.decode(bytes) == frame)
    }

    @Test("a header with the wrong version, type or length is malformed", arguments: [
        [UInt8]([24, 0, 0, 0, 2, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0]),
        [24, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0, 1, 0, 0, 0],
        [4, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0],
        [0, 0, 0, 0x10, 1, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0],
        [24, 0, 0],
    ])
    func malformedHeader(bytes: [UInt8]) {
        #expect(throws: UsbmuxError.self) { try UsbmuxFrame.header(Data(bytes)) }
    }

    @Test("Connect sends the port in network byte order and names Offsider")
    func connectMessage() throws {
        let message = UsbmuxRequest.connect(deviceID: 3, port: 28742).dictionary
        #expect(message["PortNumber"] as? Int == 0x4670)
        #expect(message["MessageType"] as? String == "Connect")
        #expect(message["DeviceID"] as? Int == 3)
        #expect(message["ClientVersionString"] as? String == "offsider")
        #expect(message["ProgName"] as? String == "offsider")
        #expect(message["BundleID"] as? String == "com.mpalmes.offsider")
        #expect(message["kLibUSBMuxVersion"] as? Int == 3)
        let payload = String(decoding: try UsbmuxRequest.listDevices.payload(), as: UTF8.self)
        #expect(payload.contains("<string>ListDevices</string>"))
    }

    @Test("ListDevices rows carry the device id, UDID and connection type")
    func listDevices() async throws {
        let server = try FakeUsbmuxd(reply: Self.standard(rows: [(3, Self.udid, "USB"), (9, "00008130-0000000000000DEF", "Network")]))
        defer { server.stop() }
        let rows = try UsbmuxClient(socketPath: server.path, timeout: 1).listDevices()
        #expect(rows == [
            UsbmuxDevice(deviceID: 3, udid: Self.udid, connectionType: "USB"),
            UsbmuxDevice(deviceID: 9, udid: "00008130-0000000000000DEF", connectionType: "Network"),
        ])
        #expect(server.received.first?["MessageType"] as? String == "ListDevices")
    }

    @Test("a UDID listed without its dash still matches")
    func dashlessUDID() {
        #expect(UsbmuxDevice(deviceID: 1, udid: "000081300000000000000ABC", connectionType: "USB").matches(Self.udid))
        #expect(!UsbmuxDevice(deviceID: 1, udid: "000081300000000000000ABD", connectionType: "USB").matches(Self.udid))
    }

    @Test("connect asks for the USB row's device id and port, then the descriptor is a raw stream")
    func connectAndHTTP() async throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8)
        let server = try FakeUsbmuxd(reply: Self.standard(rows: [(9, Self.udid, "Network"), (3, Self.udid, "USB")]), httpReply: response)
        defer { server.stop() }
        let descriptor = try UsbmuxClient(socketPath: server.path, timeout: 1).connect(udid: Self.udid, port: 28742)
        defer { close(descriptor) }
        let reply = try UsbmuxHTTP.exchange(on: descriptor, method: "POST", path: "/snapshot", token: "secret-token", body: Data("{}".utf8))

        #expect(reply.status == 200)
        #expect(reply.body == Data("{\"ok\":true}".utf8))
        let connect = try #require(server.received.last)
        #expect(connect["DeviceID"] as? Int == 3)
        #expect(connect["PortNumber"] as? Int == 0x4670)
        let request = String(decoding: try #require(server.receivedHTTP.first), as: UTF8.self)
        #expect(request.hasPrefix("POST /snapshot HTTP/1.1\r\n"))
        for header in ["Host: 127.0.0.1", "Content-Type: application/json", "X-Offsider-Token: secret-token", "Content-Length: 2", "Connection: close"] {
            #expect(request.contains("\r\n\(header)\r\n"))
        }
        #expect(request.hasSuffix("\r\n\r\n{}"))
    }

    @Test("a device usbmuxd only lists over the network is never connected")
    func networkRowsRefused() async throws {
        let server = try FakeUsbmuxd(reply: Self.standard(rows: [(9, Self.udid, "Network")]))
        defer { server.stop() }
        #expect(throws: UsbmuxError.notOnUSB) {
            _ = try UsbmuxClient(socketPath: server.path, timeout: 1).connect(udid: Self.udid, port: 28742)
        }
        #expect(server.received.allSatisfy { $0["MessageType"] as? String == "ListDevices" })
        #expect(IOSDeviceError.usbmux(.notOnUSB, udid: Self.udid).reason == .deviceNotWired)
    }

    @Test("an unlisted device is not attached")
    func unlisted() async throws {
        let server = try FakeUsbmuxd(reply: Self.standard(rows: []))
        defer { server.stop() }
        #expect(throws: UsbmuxError.notAttached) {
            _ = try UsbmuxClient(socketPath: server.path, timeout: 1).connect(udid: Self.udid, port: 28742)
        }
    }

    @Test("Result numbers map to typed failures", arguments: [
        (2, FailureReason.deviceNotFound),
        (3, .runnerUnavailable),
        (5, .commandFailed),
    ])
    func results(number: Int, reason: FailureReason) async throws {
        let server = try FakeUsbmuxd(reply: Self.standard(result: number))
        defer { server.stop() }
        #expect(throws: UsbmuxError.result(number)) {
            _ = try UsbmuxClient(socketPath: server.path, timeout: 1).connect(udid: Self.udid, port: 28742)
        }
        #expect(IOSDeviceError.usbmux(.result(number), udid: Self.udid).reason == reason)
    }

    @Test("a missing socket is usbmux_unavailable")
    func missingSocket() {
        let path = NSTemporaryDirectory() + "um-missing-\(UUID().uuidString.prefix(8)).sock"
        #expect(throws: UsbmuxError.self) { _ = try UsbmuxClient(socketPath: path, timeout: 1).listDevices() }
        #expect(IOSDeviceError.usbmux(.socketUnavailable(path), udid: Self.udid).reason == .usbmuxUnavailable)
        #expect(IOSDeviceError.usbmux(.socketUnavailable(path), udid: Self.udid).reason.exitCode == .toolMissing)
    }

    @Test("a silent usbmuxd times out instead of hanging")
    func timeout() async throws {
        let server = try FakeUsbmuxd(reply: { _ in .silent })
        defer { server.stop() }
        let started = Date()
        #expect(throws: UsbmuxError.timedOut) { _ = try UsbmuxClient(socketPath: server.path, timeout: 0.3).listDevices() }
        #expect(Date().timeIntervalSince(started) < 1.4)
        #expect(IOSDeviceError.runner(.timedOut, udid: Self.udid).reason == .runnerUnavailable)
    }

    @Test("responses parse by Content-Length and wait for the whole body")
    func responseParsing() throws {
        let full = Data("HTTP/1.1 404 Not Found\r\nCONTENT-LENGTH: 5\r\nX-Extra:  a: b \r\n\r\nhello".utf8)
        let response = try #require(try UsbmuxHTTP.parseResponse(full))
        #expect(response.status == 404)
        #expect(response.headers["x-extra"] == "a: b")
        #expect(response.body == Data("hello".utf8))
        #expect(try UsbmuxHTTP.parseResponse(full.dropLast(2)) == nil)
        #expect(try UsbmuxHTTP.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 1".utf8)) == nil)
    }

    @Test("chunked, length-less and garbled responses are refused", arguments: [
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\nx",
        "HTTP/1.1 200 OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
        "SSH-2.0-OpenSSH\r\n\r\n",
        "HTTP/1.1 200 OK\r\nno colon\r\n\r\n",
    ])
    func refusedResponses(text: String) {
        #expect(throws: UsbmuxError.self) { try UsbmuxHTTP.parseResponse(Data(text.utf8)) }
    }

    @Test("an HTTP request with no body still sends a zero Content-Length")
    func emptyBody() {
        let text = String(decoding: UsbmuxHTTP.request(method: "GET", path: "/ping", token: "t", body: nil), as: UTF8.self)
        #expect(text == "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nX-Offsider-Token: t\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
}
