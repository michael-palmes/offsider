import Darwin
import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

enum SessionTestPaths {
    /// Short enough for a Unix socket path under it.
    static func root() -> String {
        "/private/tmp/ods-\(UUID().uuidString.prefix(8))"
    }
}

/// Answers each request from a script; records what it was asked. A lost reply breaks it, as it does a socket link.
final class FakeSessionLink: DeviceSessionLink, @unchecked Sendable {
    typealias Script = @Sendable (DeviceSessionRequest) throws -> (DeviceSessionReply, Data?)

    private let lock = NSLock()
    private var asked: [DeviceSessionRequest] = []
    private var isClosed = false
    private var broken = false
    private let script: Script

    init(script: @escaping Script) {
        self.script = script
    }

    /// A broker for `udid` that answers ping with `touch`, frames with `frame`, everything else with ok, and loses the reply to what `lose` picks.
    static func broker(
        udid: String, touch: Bool = true, protocolVersion: Int = DeviceSessionWire.protocolVersion, frame: Data = Data([1, 2, 3]),
        lose: @escaping @Sendable (DeviceSessionRequest) -> Bool = { _ in false }
    ) -> FakeSessionLink {
        FakeSessionLink { request in
            if lose(request) { throw DeviceSessionLinkError.lost("the broker closed the connection") }
            var reply = DeviceSessionReply(id: 1)
            switch request {
            case .ping:
                reply.protocol = protocolVersion
                reply.udid = udid
                reply.label = "Apple iPad Pro"
                reply.touch = touch
                reply.stream = DeviceSessionStreamStatus(state: .live, width: 4, height: 3, framesReceived: 9)
                return (reply, nil)
            case .frame:
                reply.bytes = frame.count
                reply.width = 4
                reply.height = 3
                return (reply, frame)
            default:
                return (reply, nil)
            }
        }
    }

    var requests: [DeviceSessionRequest] { lock.withLock { asked } }
    var closed: Bool { lock.withLock { isClosed } }
    var isBroken: Bool { lock.withLock { broken } }

    func exchange(_ request: DeviceSessionRequest, timeout: Duration) async throws -> (DeviceSessionReply, Data?) {
        if isBroken { throw DeviceSessionLinkError.notSent("its connection broke on an earlier request") }
        lock.withLock { asked.append(request) }
        do {
            return try script(request)
        } catch let error as DeviceSessionLinkError {
            if case .lost = error { lock.withLock { broken = true } }
            throw error
        }
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}

@Suite("Device session wire")
struct DeviceSessionWireTests {
    @Test("every request survives encoding and decoding with its id", arguments: [
        DeviceSessionRequest.ping,
        .frame(.png),
        .frame(.bgra),
        .press(usagePage: 0x0C, usageCode: 0x30, hold: 0.4),
        .touch([.touch(.down, x: 10, y: 20), .wait(0.06), .touch(.up, x: 10, y: 20)]),
        .keys([.key(4, down: true), .key(4, down: false)]),
        .text("hi there"),
        .displayChanged,
        .stop,
    ])
    func roundTrip(request: DeviceSessionRequest) throws {
        let framed = try DeviceSessionWire.encode(request, id: 42)
        let length = Int(framed[0]) << 24 | Int(framed[1]) << 16 | Int(framed[2]) << 8 | Int(framed[3])
        #expect(length == framed.count - 4)
        let decoded = try DeviceSessionWire.decodeRequest(framed.dropFirst(4))
        #expect(decoded.id == 42)
        #expect(decoded.request == request)
    }

    @Test("an unknown op or a request missing its fields is refused")
    func refused() {
        #expect(throws: DeviceSessionWireError.self) { try DeviceSessionWire.decodeRequest(Data(#"{"id":1,"op":"reboot"}"#.utf8)) }
        #expect(throws: DeviceSessionWireError.self) { try DeviceSessionWire.decodeRequest(Data(#"{"id":1,"op":"press","usagePage":12}"#.utf8)) }
    }

    @Test("a reply that announces bytes is followed by exactly that binary frame, split across writes")
    func binaryFrame() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let server = DeviceSessionChannel(descriptor: pair[1])
        let image = Data((0..<200_000).map { UInt8($0 % 251) })
        let thread = Thread {
            guard let payload = try? server.readFrame(limit: DeviceSessionWire.maxJSONBytes, timeout: .seconds(5)),
                  let (id, request) = try? DeviceSessionWire.decodeRequest(payload), request == .frame(.png) else { return }
            var reply = DeviceSessionReply(id: id)
            reply.bytes = image.count
            reply.width = 10
            reply.height = 20
            let framed = DeviceSessionWire.frame(try! DeviceSessionWire.encoder.encode(reply)) + DeviceSessionWire.frame(image)
            try? server.write(framed.prefix(7))
            try? server.write(framed.dropFirst(7))
        }
        thread.start()
        let link = SocketSessionLink(channel: DeviceSessionChannel(descriptor: pair[0]))
        let (reply, payload) = try await link.exchange(.frame(.png), timeout: .seconds(5))
        #expect(reply.bytes == image.count)
        #expect(payload == image)
        link.close()
        server.close()
    }

    @Test("a broker failure arrives as the IOSDeviceError it was, with its reason")
    func failureRoundTrip() throws {
        let locked = IOSDeviceError(.locked, "iPad is locked.")
        let reply = DeviceSessionReply.failure(id: 3, locked)
        let decoded = try JSONDecoder().decode(DeviceSessionReply.self, from: try DeviceSessionWire.encoder.encode(reply))
        #expect(decoded.ok == false)
        #expect(decoded.error?.error == locked)
        #expect(decoded.error?.error.reason == .deviceLocked)
    }
}

@Suite("Device session client")
@MainActor
struct DeviceSessionClientTests {
    @Test("a request that never left is session_failed; input whose reply was lost is input_outcome_unknown")
    func lostRequests() async throws {
        let notSent = DeviceSessionClient(udid: "U", link: FakeSessionLink { _ in throw DeviceSessionLinkError.notSent("closed") })
        let refused = await #expect(throws: IOSDeviceError.self) { try await notSent.press(usagePage: 12, usageCode: 64, hold: 0.1) }
        #expect(refused?.reason == .hidBrokerFailed)
        #expect(refused?.message.contains("nothing was sent") == true)

        let lost = DeviceSessionClient(udid: "U", link: FakeSessionLink { _ in throw DeviceSessionLinkError.lost("closed") })
        let input = await #expect(throws: IOSDeviceError.self) { try await lost.touch([.touch(.down, x: 1, y: 1)]) }
        #expect(input?.reason == .inputOutcomeUnknown)
        let lostFrame = DeviceSessionClient(udid: "U", link: FakeSessionLink { _ in throw DeviceSessionLinkError.lost("closed") })
        let frame = await #expect(throws: IOSDeviceError.self) { _ = try await lostFrame.frame(.png) }
        #expect(frame?.reason == .hidBrokerFailed)
    }

    @Test("a lost reply breaks the socket link, so the command knows to reconnect")
    func lostReplyBreaksLink() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let server = DeviceSessionChannel(descriptor: pair[1])
        let link = SocketSessionLink(channel: DeviceSessionChannel(descriptor: pair[0]))
        let thread = Thread {
            _ = try? server.readFrame(limit: DeviceSessionWire.maxJSONBytes, timeout: .seconds(5))
            server.close()
        }
        thread.start()
        #expect(!link.isBroken)
        let error = await #expect(throws: DeviceSessionLinkError.self) { _ = try await link.exchange(.touch([.touch(.down, x: 1, y: 1)]), timeout: .seconds(5)) }
        #expect({ if case .lost? = error { return true } else { return false } }())
        #expect(link.isBroken)
    }
}

@Suite("Device session manager", .serialized)
@MainActor
struct DeviceSessionManagerTests {
    static let udid = IOSDeviceFixtures.phone

    static func manager(_ processes: FakeRunnerProcesses, root: String, links: @escaping @Sendable (String) throws -> any DeviceSessionLink) -> DeviceSessionManager {
        DeviceSessionManager(
            store: DeviceSessionStore(root: root), processes: processes, environment: ["A": "1"], connector: links, log: { _, _ in },
            startTimeout: .milliseconds(300), lockTimeout: 2
        )
    }

    static func record(pid: Int32, root: String, state: DeviceSessionRecord.State = .running) throws -> DeviceSessionRecord {
        DeviceSessionRecord(
            udid: udid, pid: pid, process: FakeRunnerProcesses.identity, socket: try DeviceSessionStore(root: root).socketPath(udid: udid),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: DeviceSessionWire.protocolVersion, state: state
        )
    }

    @Test("with no broker, one is spawned as device-session serve, recorded while starting and kept once it answers")
    func startsBroker() async throws {
        let root = SessionTestPaths.root()
        let processes = FakeRunnerProcesses()
        let manager = Self.manager(processes, root: root) { _ in
            guard !processes.launches.isEmpty else { throw DeviceSessionConnectError(code: ECONNREFUSED) }
            return FakeSessionLink.broker(udid: Self.udid)
        }
        let client = try await manager.connect(udid: Self.udid)
        #expect(client.supportsTouch)
        #expect(processes.launches.map(\.arguments) == [["device-session", "serve", "--device", Self.udid]])
        #expect(processes.launches.first?.environment["A"] == "1")
        let record = try #require(try DeviceSessionStore(root: root).read(udid: Self.udid))
        #expect(record.pid == 5151)
        #expect(record.state == .running)
        #expect(record.socket.utf8.count < 104)
    }

    @Test("a live broker that answers is reused without spawning")
    func reusesBroker() async throws {
        let root = SessionTestPaths.root()
        try DeviceSessionStore(root: root).write(Self.record(pid: 700, root: root))
        let processes = FakeRunnerProcesses(alive: [700])
        let client = try await Self.manager(processes, root: root) { _ in FakeSessionLink.broker(udid: Self.udid) }.connect(udid: Self.udid)
        #expect(client.status?.label == "Apple iPad Pro")
        #expect(processes.launches.isEmpty)
        #expect(processes.terminations.isEmpty)
    }

    @Test("a recorded pid now running another process is forgotten, never signalled, and a new broker starts", arguments: [
        Set<Int32>(), Set<Int32>([700]),
    ])
    func recycledPID(alive: Set<Int32>) async throws {
        let root = SessionTestPaths.root()
        try DeviceSessionStore(root: root).write(Self.record(pid: 700, root: root))
        let processes = FakeRunnerProcesses(alive: alive, startTimes: [700: 42])
        _ = try await Self.manager(processes, root: root) { _ in FakeSessionLink.broker(udid: Self.udid) }.connect(udid: Self.udid)
        #expect(processes.terminations.isEmpty)
        #expect(processes.launches.count == 1)
        #expect(try DeviceSessionStore(root: root).read(udid: Self.udid)?.pid == 5151)
    }

    @Test("a live broker of another protocol is stopped and replaced")
    func staleProtocol() async throws {
        let root = SessionTestPaths.root()
        try DeviceSessionStore(root: root).write(Self.record(pid: 700, root: root))
        let processes = FakeRunnerProcesses(alive: [700])
        let manager = Self.manager(processes, root: root) { _ in
            FakeSessionLink.broker(udid: Self.udid, protocolVersion: processes.launches.isEmpty ? 0 : DeviceSessionWire.protocolVersion)
        }
        _ = try await manager.connect(udid: Self.udid)
        #expect(processes.terminations == [700])
        #expect(processes.launches.count == 1)
    }

    @Test("a broker that exits before answering is session_failed and leaves no record")
    func failedStart() async throws {
        let root = SessionTestPaths.root()
        let processes = FakeRunnerProcesses()
        let manager = Self.manager(processes, root: root) { _ in
            processes.exit(5151)
            throw DeviceSessionConnectError(code: ECONNREFUSED)
        }
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(udid: Self.udid) }
        #expect(error?.reason == .hidBrokerFailed)
        #expect(try DeviceSessionStore(root: root).read(udid: Self.udid) == nil)
    }

    @Test("while another command holds the start lock, even one whose owner line names an exited process, no second broker starts")
    func startLockHeld() async throws {
        let root = SessionTestPaths.root()
        let processes = FakeRunnerProcesses()
        let manager = DeviceSessionManager(
            store: DeviceSessionStore(root: root), processes: processes, environment: [:], connector: { _ in throw DeviceSessionConnectError(code: ECONNREFUSED) },
            log: { _, _ in }, lockTimeout: 0.3
        )
        let held = try await manager.acquireStartLock(udid: Self.udid)
        try StartLockTests.claimForExitedProcess(held.path)
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(udid: Self.udid) }
        #expect(error?.reason == .hidBrokerFailed)
        #expect(error?.message.contains("still starting the device session") == true)
        #expect(processes.launches.isEmpty)
        held.release()
    }

    @Test("existing never starts a broker")
    func existingNeverStarts() async throws {
        let processes = FakeRunnerProcesses()
        let client = await Self.manager(processes, root: SessionTestPaths.root()) { _ in FakeSessionLink.broker(udid: Self.udid) }.existing(udid: Self.udid)
        #expect(client == nil)
        #expect(processes.launches.isEmpty)
    }

    @Test("stop asks the broker to stop, signals one that lingers, and forgets it")
    func stop() async throws {
        let root = SessionTestPaths.root()
        let record = try Self.record(pid: 700, root: root)
        try DeviceSessionStore(root: root).write(record)
        let processes = FakeRunnerProcesses(alive: [700])
        let link = FakeSessionLink.broker(udid: Self.udid)
        await Self.manager(processes, root: root) { _ in link }.stop(record)
        #expect(link.requests == [.stop])
        #expect(processes.terminations == [700])
        #expect(try DeviceSessionStore(root: root).read(udid: Self.udid) == nil)
    }
}

/// A broker's hardware that records requests and serves a fixed frame.
@MainActor
final class FakeSessionHardware: DeviceSessionHardware {
    var streamStatus = DeviceSessionStreamStatus(state: .opening)
    var supportsTouch = true
    var label: String? = "Apple iPad Pro"
    var geometry: IOSDeviceGeometry?
    private(set) var displayChanges = 0
    var healthy = true
    var healthDelay: Duration = .zero
    private(set) var touches: [[DeviceSessionStep]] = []
    private(set) var closed = false
    /// Set when a touch with a long wait saw its client leave before the wait ended.
    private(set) var sawClientLeave = false

    func start() async { streamStatus = DeviceSessionStreamStatus(state: .live, width: 2, height: 1, framesReceived: 1) }
    func frame(_ format: IOSDeviceScreenFrame.Format) async throws -> IOSDeviceScreenFrame {
        IOSDeviceScreenFrame(data: Data([9, 8, 7, 6]), width: 2, height: 1, format: format)
    }
    func press(usagePage: UInt64, usageCode: UInt64, hold: Double, abandoned: @Sendable () -> Bool) async throws {
        throw IOSDeviceError(.locked, "iPad is locked.")
    }
    func touch(_ steps: [DeviceSessionStep], abandoned: @Sendable () -> Bool) async throws {
        touches.append(steps)
        let wait = DeviceSessionClient.waited(steps)
        guard wait > 0 else { return }
        sawClientLeave = !(await CoreDeviceSessionHardware.pause(until: .now + .seconds(wait), abandoned: abandoned))
    }
    func keys(_ steps: [DeviceSessionStep], abandoned: @Sendable () -> Bool) async throws {}
    func freshGeometry() -> IOSDeviceGeometry? { geometry }
    func displayChanged() { displayChanges += 1 }
    func checkHealth() async -> Bool {
        if healthDelay > .zero { try? await Task.sleep(for: healthDelay) }
        return healthy
    }
    func close() async { closed = true }
}

@Suite("Device session server", .serialized)
@MainActor
struct DeviceSessionServerTests {
    @Test("over its 0600 socket the broker answers ping, frames, input and refusals, and stop ends it and removes the socket")
    func serves() async throws {
        let socket = NSTemporaryDirectory() + "ods-\(UUID().uuidString.prefix(8)).sock"
        let hardware = FakeSessionHardware()
        let server = DeviceSessionServer(udid: "U", socketPath: socket, hardware: hardware, store: nil, idleTimeout: .seconds(30), log: { _, _ in })
        let running = Task { try await server.run() }
        var link: (any DeviceSessionLink)?
        for _ in 0..<100 where link == nil {
            link = try? SocketSessionLink.connect(socket)
            if link == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let client = DeviceSessionClient(udid: "U", link: try #require(link))
        var info = stat()
        #expect(lstat(socket, &info) == 0 && info.st_mode & 0o777 == 0o600)

        let ping = try await client.ping()
        #expect(ping.protocol == DeviceSessionWire.protocolVersion)
        #expect(ping.udid == "U")
        #expect(ping.pid == getpid())
        #expect(ping.touch == true)
        let frame = try await client.frame(.png)
        #expect(frame.data == Data([9, 8, 7, 6]))
        try await client.displayChanged()
        #expect(hardware.displayChanges == 1)
        try await client.touch([.touch(.down, x: 1, y: 2), .touch(.up, x: 1, y: 2)])
        #expect(hardware.touches.count == 1)
        let refused = await #expect(throws: IOSDeviceError.self) { try await client.press(usagePage: 12, usageCode: 64, hold: 0.1) }
        #expect(refused?.reason == .deviceLocked)
        let tooLong = await #expect(throws: IOSDeviceError.self) { try await client.touch([.wait(60)]) }
        #expect(tooLong?.reason == .hidBrokerFailed)

        try await client.stop()
        try await running.value
        #expect(hardware.closed)
        #expect(lstat(socket, &info) != 0)
    }

    @Test("a client that disconnects while its touch is held ends the hold early")
    func clientLeaves() async throws {
        let socket = NSTemporaryDirectory() + "ods-\(UUID().uuidString.prefix(8)).sock"
        let hardware = FakeSessionHardware()
        let server = DeviceSessionServer(udid: "U", socketPath: socket, hardware: hardware, store: nil, idleTimeout: .seconds(30), log: { _, _ in })
        let running = Task { try await server.run() }
        var channel: DeviceSessionChannel?
        for _ in 0..<100 where channel == nil {
            channel = try? DeviceSessionChannel.connect(to: socket)
            if channel == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let held = try #require(channel)
        try held.write(try DeviceSessionWire.encode(.touch([.touch(.down, x: 1, y: 1), .wait(20), .touch(.up, x: 1, y: 1)]), id: 1))
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        held.close()
        while !hardware.sawClientLeave, ContinuousClock.now - started < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hardware.sawClientLeave)
        #expect(ContinuousClock.now - started < .seconds(5))

        let client = DeviceSessionClient(udid: "U", link: try SocketSessionLink.connect(socket))
        try await client.stop()
        try await running.value
    }

    @Test("a slow health check, such as a stream re-opening, never holds up input")
    func healthOutsideInput() async throws {
        let socket = NSTemporaryDirectory() + "ods-\(UUID().uuidString.prefix(8)).sock"
        let hardware = FakeSessionHardware()
        hardware.healthDelay = .seconds(3)
        let server = DeviceSessionServer(
            udid: "U", socketPath: socket, hardware: hardware, store: nil, idleTimeout: .seconds(30), healthInterval: .milliseconds(10), log: { _, _ in }
        )
        let running = Task { try await server.run() }
        var link: (any DeviceSessionLink)?
        for _ in 0..<100 where link == nil {
            link = try? SocketSessionLink.connect(socket)
            if link == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let client = DeviceSessionClient(udid: "U", link: try #require(link))
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        try await client.touch([.touch(.down, x: 1, y: 2), .touch(.up, x: 1, y: 2)])
        #expect(ContinuousClock.now - started < .seconds(1))
        try await client.stop()
        try await running.value
    }

    @Test("queued input is dropped unsent once its client has gone or would no longer wait for the reply")
    func staleInput() {
        let now = ContinuousClock.now
        #expect(DeviceSessionServer.unsent(DeviceSessionOrigin(receivedAt: now, isGone: { false }), now: now + .seconds(1)) == nil)
        #expect(DeviceSessionServer.unsent(DeviceSessionOrigin(receivedAt: now, isGone: { true }), now: now)?.reason == .hidBrokerFailed)
        #expect(DeviceSessionServer.unsent(DeviceSessionOrigin(receivedAt: now, isGone: { false }), now: now + DeviceSessionClient.inputTimeout) != nil)
    }

    @Test("a failed stream is retried with a doubling back-off that stops at a minute")
    func reopenBackOff() {
        let delays = (1...8).map { CoreDeviceSessionHardware.reopenDelay(afterFailures: $0) }
        #expect(delays == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60), .seconds(60)])
    }

    @Test("the broker stops by itself once idle, and when its device goes")
    func stopsByItself() async throws {
        for healthy in [true, false] {
            let socket = NSTemporaryDirectory() + "ods-\(UUID().uuidString.prefix(8)).sock"
            let hardware = FakeSessionHardware()
            hardware.healthy = healthy
            let server = DeviceSessionServer(
                udid: "U", socketPath: socket, hardware: hardware, store: nil,
                idleTimeout: healthy ? .milliseconds(200) : .seconds(30), healthInterval: .milliseconds(100), log: { _, _ in }
            )
            try await server.run()
            #expect(hardware.closed)
        }
    }

    @Test("OFFSIDER_IOS_SESSION_IDLE sets the idle timeout; anything but a positive number keeps 300 s", arguments: [
        ("60", 60), ("0", 300), ("soon", 300),
    ])
    func idle(value: String, seconds: Int) {
        #expect(DeviceSessionServer.idleSeconds(["OFFSIDER_IOS_SESSION_IDLE": value]) == seconds)
        #expect(DeviceSessionServer.idleSeconds([:]) == 300)
    }
}

@Suite("Device session reports")
struct DeviceSessionReportsTests {
    static let phone = IOSDevicePanel(width: 430, height: 932, scale: 3, orientation: .portrait)

    @Test("a tap is a contact then a release at the touchscreen point")
    func tap() throws {
        let reports = try DeviceSessionReports.touch([.touch(.down, x: 215, y: 466), .touch(.up, x: 215, y: 466)], panel: Self.phone)
        #expect(reports == [.touch(x: 32768, y: 32768, state: .contact), .touch(x: 32768, y: 32768, state: .release)])
    }

    @Test("a held contact is sent again through each pause, keeping the pause's total time")
    func hold() throws {
        let reports = try DeviceSessionReports.touch([.touch(.down, x: 0, y: 0), .wait(0.05), .touch(.up, x: 0, y: 0)], panel: Self.phone)
        let sleeps = reports.compactMap { if case .sleep(let seconds) = $0 { return seconds } else { return nil } }
        #expect(abs(sleeps.reduce(0, +) - 0.05) < 1e-9)
        #expect(sleeps.allSatisfy { $0 <= DeviceSessionReports.holdInterval + 1e-9 })
        #expect(reports.filter { $0 == .touch(x: 0, y: 0, state: .contact) }.count == sleeps.count + 1)
        #expect(reports.last == .touch(x: 0, y: 0, state: .release))
    }

    @Test("a contact left down is released, and a pause with nothing held is one sleep")
    func releasesAndIdlePauses() throws {
        let reports = try DeviceSessionReports.touch([.wait(1), .touch(.down, x: 430, y: 932)], panel: Self.phone)
        #expect(reports == [.sleep(1), .touch(x: 65535, y: 65535, state: .contact), .touch(x: 65535, y: 65535, state: .release)])
    }

    @Test("keys set and clear their usage in the held set; keys still held are released")
    func keys() throws {
        let reports = try DeviceSessionReports.keys([.key(225, down: true), .key(11, down: true), .key(11, down: false), .wait(0.01)])
        #expect(reports == [.keyboard([225]), .keyboard([225, 11]), .keyboard([225]), .sleep(0.01), .keyboard([])])
    }

    @Test("a step of the wrong kind or a usage past the bitmap is refused before anything is sent")
    func refusals() {
        #expect(throws: IOSDeviceError.self) { try DeviceSessionReports.keys([.touch(.down, x: 1, y: 1)]) }
        #expect(throws: IOSDeviceError.self) { try DeviceSessionReports.keys([.key(240, down: true)]) }
        #expect(throws: IOSDeviceError.self) { try DeviceSessionReports.touch([.key(4, down: true)], panel: Self.phone) }
    }

    @Test("a held key, touch or button goes out as one request with its hold and release")
    func holdsInOneRequest() throws {
        var lowering = DeviceSessionLowering(brokerTouches: true)
        #expect(try lowering.actions(for: .composite([.keyboard(direction: .down, keyCode: 225), .delay(2), .keyboard(direction: .up, keyCode: 225)])) == [
            .keys([.key(225, down: true), .wait(2), .key(225, down: false)]),
        ])
        #expect(try lowering.actions(for: .composite([.button(direction: .down, button: .home), .delay(1.5), .button(direction: .up, button: .home)])) == [
            .press(.home, hold: 1.5),
        ])
        #expect(try lowering.actions(for: .composite([.shortKeyPress(4), .delay(0.5), .tapAt(x: 1, y: 2)])) == [
            .keys([.key(4, down: true), .key(4, down: false)]), .wait(0.5),
            .touch([.touch(.down, x: 1, y: 2), .wait(DeviceSessionLowering.tapHold), .touch(.up, x: 1, y: 2)]),
        ])
    }

    @Test("input left down at the end of an event, or held while other input is sent, is refused before anything is sent", arguments: [
        InputEvent.touch(direction: .down, x: 1, y: 1),
        .touch(direction: .up, x: 1, y: 1),
        .keyboard(direction: .down, keyCode: 4),
        .button(direction: .down, button: .home),
        .button(direction: .up, button: .home),
        .composite([.keyboard(direction: .down, keyCode: 225), .tapAt(x: 1, y: 1), .keyboard(direction: .up, keyCode: 225)]),
        .composite([.button(direction: .down, button: .home), .tapAt(x: 1, y: 1), .button(direction: .up, button: .home)]),
    ])
    func heldAcrossRequests(event: InputEvent) {
        var lowering = DeviceSessionLowering(brokerTouches: true)
        let error = #expect(throws: IOSDeviceError.self) { try lowering.actions(for: event) }
        #expect(error?.reason == .notSupported)
    }

    @Test("lowering merges a gesture into one touch request and US text into key steps")
    func lowering() throws {
        var lowering = DeviceSessionLowering(brokerTouches: true)
        let actions = try lowering.actions(for: .composite([.touch(direction: .down, x: 1, y: 2), .delay(0.5), .touch(direction: .up, x: 1, y: 2)]))
        #expect(actions == [.touch([.touch(.down, x: 1, y: 2), .wait(0.5), .touch(.up, x: 1, y: 2)])])
        #expect(try DeviceSessionLowering.keySteps(typing: "hI") == [
            .key(11, down: true), .key(11, down: false), .key(225, down: true), .key(12, down: true), .key(12, down: false), .key(225, down: false),
        ])
        var runner = DeviceSessionLowering(brokerTouches: false)
        #expect(try runner.actions(for: .tapAt(x: 3, y: 4)) == [.runner(.tapAt(x: 3, y: 4))])
    }
}
