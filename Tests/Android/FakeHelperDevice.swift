import CryptoKit
import Foundation
@testable import OffsiderAndroid

/// emulator-5556 running the helper: scripted start shells, a `sync:` service, the helper's socket, `pidof` and `kill`.
final class FakeHelperDevice: @unchecked Sendable {
    static let serial = "emulator-5556"
    static let dexBytes = Data("dex".utf8)
    static let dex = try! HelperDex(bytes: dexBytes, manifestJSON: manifest(for: dexBytes))

    static func manifest(for bytes: Data, protocol number: Int = 2, sha256: String? = nil) -> Data {
        let hash = sha256 ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Data("""
        {"helper": "offsider-helper", "helperVersion": "1.0.0", "protocol": \(number), "dex": {"file": "offsider-helper.dex", "bytes": \(bytes.count), "sha256": "\(hash)"}}
        """.utf8)
    }

    /// How one start shell behaves.
    enum Start {
        case ready
        /// Prints these stdout lines, each on its own read, then the ready line.
        case readyAfter([String])
        case readyWithProtocol(Int)
        case exit(status: UInt8, stdout: String = "", stderr: String = "")
        /// Never prints anything.
        case silent
    }

    /// How the helper answers one request.
    enum Answer {
        /// `"ok": true` with these fields, a JSON object.
        case ok(String)
        /// An ok reply with these fields, then this binary frame, as `screenshot` answers.
        case okWithPayload(String, Data)
        /// The focused element's class and id ride along, as `setText` errors carry them.
        case error(code: String, message: String, className: String? = nil, resourceId: String? = nil, inputType: Int? = nil)
        /// A `bye` frame instead of a reply, then the helper exits.
        case bye(String)
        /// The socket closes with no reply: the helper died.
        case hangUp
        case silence
    }

    struct Received: Equatable {
        let process: Int
        let op: String
        let json: String
    }

    final class Process: @unchecked Sendable {
        let number: Int
        let pid: Int32
        var exitStatus: UInt8?
        var exitSent = false
        var pending: [Data] = []

        init(number: Int) {
            self.number = number
            pid = 4000 + Int32(number)
        }

        var socket: String { "offsider-fake-\(number)" }
        var token: String { "token-\(number)" }
    }

    private let lock = NSLock()
    private var scripted: [Start]
    private var processes: [Process] = []
    private var recordedFrames: [Received] = []
    private var recordedTimeline: [String] = []
    private var recordedKills: [Int32] = []
    private var pidofCount = 0
    private var syncs: [FakeSyncSession] = []
    private var recordedScripts: [String] = []
    var dexOnDevice: Bool
    /// False: a push succeeds but the file never appears, so the next start exits 90 again.
    var pushLands = true
    var exitOnQuit = true
    var refuseSocket = false
    var syncAnswer: FakeSyncSession.Answer = .okay
    var dump = FakeHelperDevice.tapTestDump
    /// What `hello` lists; nil leaves `ops` out, as a protocol 1 helper did.
    var helloOps: [String]? = ["hello", "ping", "dump", "display", "setProgress", "setText", "paste", "events", "inject", "screenshot", "quit"]
    var answer: @Sendable (_ process: Int, _ op: String, _ json: String) -> Answer? = { _, _, _ in nil }
    var pidof: @Sendable (_ call: Int) -> String = { _ in "" }
    /// Every other device service, such as the display probe.
    var other: @Sendable (_ service: String) -> FakeAdbServer.Reply = { _ in FakeAdbServer.shell(status: 1) }

    init(starts: [Start] = [], dexOnDevice: Bool = true) {
        scripted = starts
        self.dexOnDevice = dexOnDevice
    }

    var frames: [Received] { lock.withLock { recordedFrames } }
    var ops: [String] { frames.map(\.op) }
    /// Starts, pushes, frames, closes, kills, exits and exit packets Offsider read, in the order they happened.
    var timeline: [String] { lock.withLock { recordedTimeline } }
    var kills: [Int32] { lock.withLock { recordedKills } }
    var pidofCalls: Int { lock.withLock { pidofCount } }
    var syncSessions: [FakeSyncSession] { lock.withLock { syncs } }
    var startScripts: [String] { lock.withLock { recordedScripts } }
    var startedProcesses: Int { lock.withLock { processes.count } }

    func note(_ entry: String) {
        lock.withLock { recordedTimeline.append(entry) }
    }

    /// A fake adb server whose emulator-5556 is this device; `host` answers host queries other than `host:version`.
    func server(host: @escaping @Sendable (String) -> FakeAdbServer.Reply = { _ in .hang }) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            [Self.serial],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : host($0) },
            device: { [self] _, service in handle(service) }
        ))
    }

    private func handle(_ service: String) -> FakeAdbServer.Reply {
        if service.hasPrefix("shell,v2,raw:"), service.contains("app_process") {
            return .session(startShell(String(service.dropFirst("shell,v2,raw:".count))))
        }
        if service == "shell,v2,raw:pidof offsider-helper" {
            let call = lock.withLock { pidofCount += 1; return pidofCount }
            let output = pidof(call)
            return FakeAdbServer.shell(stdout: output, status: output.isEmpty ? 1 : 0)
        }
        if service.hasPrefix("shell,v2,raw:kill ") {
            let pid = Int32(service.dropFirst("shell,v2,raw:kill ".count)) ?? -1
            lock.withLock {
                recordedKills.append(pid)
                recordedTimeline.append("kill \(pid)")
                if let process = processes.first(where: { $0.pid == pid }), process.exitStatus == nil {
                    process.exitStatus = 143
                }
            }
            return FakeAdbServer.shell()
        }
        if service == "sync:" {
            let answer = syncAnswer
            let session = FakeSyncSession { [self] target, _ in
                note("push \(target)")
                return answer
            }
            lock.withLock { syncs.append(session) }
            return .session(session)
        }
        if service.hasPrefix("localabstract:") {
            let name = String(service.dropFirst("localabstract:".count))
            let process = lock.withLock { processes.first { $0.socket == name && $0.exitStatus == nil } }
            guard let process, !refuseSocket else { return FakeAdbServer.fail("closed") }
            note("connect \(process.number)")
            return .session(FakeHelperSocket(device: self, process: process))
        }
        return other(service)
    }

    private func startShell(_ script: String) -> FakeHelperShell {
        let renamed = script.contains("mv -f ")
        let pushed = lock.withLock { syncs.last }.map { !$0.file.isEmpty } ?? false
        let process = lock.withLock { () -> Process in
            recordedScripts.append(script)
            if renamed, pushLands, pushed {
                dexOnDevice = true
            }
            let process = Process(number: processes.count + 1)
            processes.append(process)
            recordedTimeline.append("start \(process.number)\(renamed ? " after push" : "")")
            let start = scripted.isEmpty ? .ready : scripted.removeFirst()
            guard dexOnDevice else {
                process.pending = [FakeAdbServer.packet(3, Data([90]))]
                process.exitStatus = 90
                process.exitSent = true
                return process
            }
            switch start {
            case .ready:
                process.pending = [Self.stdout(readyLine(process, protocol: 2))]
            case .readyAfter(let lines):
                process.pending = lines.map { Self.stdout($0 + "\n") } + [Self.stdout(readyLine(process, protocol: 2))]
            case .readyWithProtocol(let number):
                process.pending = [Self.stdout(readyLine(process, protocol: number))]
            case .exit(let status, let stdout, let stderr):
                var bytes = Data()
                if !stdout.isEmpty { bytes += FakeAdbServer.packet(1, Data(stdout.utf8)) }
                if !stderr.isEmpty { bytes += FakeAdbServer.packet(2, Data(stderr.utf8)) }
                process.pending = [bytes + FakeAdbServer.packet(3, Data([status]))]
                process.exitStatus = status
                process.exitSent = true
            case .silent:
                process.pending = []
            }
            return process
        }
        return FakeHelperShell(device: self, process: process)
    }

    private func readyLine(_ process: Process, protocol number: Int) -> String {
        #"{"event":"ready","protocol":\#(number),"helper":"1.0.0","pid":\#(process.pid),"socket":"\#(process.socket)","token":"\#(process.token)","sdkInt":36}"# + "\n"
    }

    static func stdout(_ text: String) -> Data {
        FakeAdbServer.packet(1, Data(text.utf8))
    }

    /// The process's next shell bytes: queued output, then its exit packet once it has exited.
    fileprivate func shellOutput(_ process: Process) -> (bytes: Data, close: Bool)? {
        lock.withLock {
            if !process.pending.isEmpty {
                return (process.pending.removeFirst(), false)
            }
            if let status = process.exitStatus, !process.exitSent {
                process.exitSent = true
                recordedTimeline.append("exit packet \(process.number)")
                return (FakeAdbServer.packet(3, Data([status])), true)
            }
            return nil
        }
    }

    fileprivate func shellClosed(_ process: Process) {
        lock.withLock {
            recordedTimeline.append("shell closed \(process.number)")
            if process.exitStatus == nil {
                process.exitStatus = 0
            }
        }
    }

    fileprivate func exit(_ process: Process, status: UInt8) {
        lock.withLock {
            if process.exitStatus == nil {
                process.exitStatus = status
                recordedTimeline.append("exit \(process.number) \(status)")
            }
        }
    }

    fileprivate func record(_ received: Received) {
        lock.withLock {
            recordedFrames.append(received)
            recordedTimeline.append("\(received.op) \(received.process)")
        }
    }

    fileprivate func reply(to op: String, json: String, process: Process) -> Answer {
        if let scripted = answer(process.number, op, json) {
            return scripted
        }
        switch op {
        case "hello":
            let ops = lock.withLock { helloOps }.map { #","ops":[\#($0.map { "\"\($0)\"" }.joined(separator: ","))]"# } ?? ""
            return .ok(#"{"helper":"1.4.0","protocol":2\#(ops)}"#)
        case "ping", "quit": return .ok("{}")
        case "dump": return .ok(lock.withLock { dump })
        case "display": return .ok(Self.displayReply)
        case "inject": return .ok(Self.injectReply(to: json))
        default: return .error(code: "unknown-op", message: "unknown op '\(op)'")
        }
    }

    /// A raw screenshot reply and its frame: `width` x `height` RGBA pixels, each red = its index.
    static func screenshot(width: Int, height: Int) -> Answer {
        let pixels = Data((0..<(width * height)).flatMap { [UInt8($0 & 0xFF), 0, 0, 255] })
        return .okWithPayload(
            #"{"frame":{"width":\#(width),"height":\#(height),"format":"rgba8888","bytes":\#(pixels.count)},"captureMs":40,"copyMs":5,"encodeMs":3}"#,
            pixels
        )
    }

    /// Every step dispatched in 1 ms.
    static func injectReply(to json: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let count = (object?["steps"] as? [Any])?.count ?? 0
        let steps = Array(repeating: #"{"dispatched":true,"ms":1}"#, count: count).joined(separator: ",")
        return #"{"steps":[\#(steps)],"eventSeqBefore":7,"totalMs":\#(count)}"#
    }

    /// The steps of every `inject` the helper received, in order.
    var injectedSteps: [[String: Any]] {
        frames.filter { $0.op == "inject" }.flatMap { frame -> [[String: Any]] in
            let object = try? JSONSerialization.jsonObject(with: Data(frame.json.utf8)) as? [String: Any]
            return object?["steps"] as? [[String: Any]] ?? []
        }
    }

    /// Each injected step as a short line, such as `key press 66 meta 0` or `touch down 100 200`.
    var injected: [String] {
        injectedSteps.map { step in
            func number(_ key: String) -> String {
                guard let value = step[key] as? NSNumber else { return "?" }
                return value.doubleValue == value.doubleValue.rounded() ? String(value.intValue) : String(value.doubleValue)
            }
            switch step["kind"] as? String {
            case "tap": return "tap \(number("x")) \(number("y"))"
            case "swipe": return "swipe \(number("fromX")) \(number("fromY")) \(number("toX")) \(number("toY")) \(number("durationMs")) ms \(number("moves")) moves"
            case "touch":
                let pointer = (step["pointer"] as? NSNumber)?.intValue ?? 0
                return "touch \(step["phase"] as? String ?? "?")\(pointer == 0 ? "" : " p\(pointer)") \(number("x")) \(number("y"))"
            case "key": return "key \(step["phase"] as? String ?? "?") \(number("code")) meta \(number("meta"))"
            case "text": return "text \(step["text"] as? String ?? "?")"
            case "pause": return "pause \(number("ms"))"
            default: return "unknown"
            }
        }
    }

    static let display = #""display":{"displayId":0,"source":"DisplayManagerGlobal","logicalWidthPx":1080,"logicalHeightPx":2424,"rotation":0,"physicalWidthPx":1080,"physicalHeightPx":2424,"densityDpi":420,"densityStableDpi":420}"#
    static let statusBar = #"{"id":2297,"type":"system","layer":1,"displayId":0,"bounds":[0,0,1080,142],"active":false,"focused":false}"#
    static let displayReply = "{\(display),\"windows\":[\(statusBar)]}"

    /// tap-test as the helper reported it on Offsider_E2E, trimmed to the back button and the tap count.
    static let tapTestDump = """
    {"generation":1,"idle":true,\(display),"windows":[\(statusBar),{"id":2292,"type":"application","layer":0,"title":"OffsiderPlaygroundRN","displayId":0,"bounds":[0,0,1080,2424],"active":true,"focused":true,"root":{"i":0,"class":"android.widget.FrameLayout","package":"com.mpalmes.offsider.playground.rn","bounds":[0,0,1080,2424],"children":[{"i":1,"class":"android.widget.Button","package":"com.mpalmes.offsider.playground.rn","resourceId":"BackButton","contentDescription":"Offsider Playground","bounds":[21,142,137,258],"clickable":true,"focusable":true},{"i":2,"class":"android.widget.TextView","package":"com.mpalmes.offsider.playground.rn","resourceId":"tap-count","contentDescription":"Tap Count: 0","bounds":[413,418,668,479],"focusable":true}]}}],"truncated":false,"source":"getWindows","stats":{"windows":2,"trees":1,"nodes":3},"eventSeq":3}
    """
}

/// One helper's start shell: its output and exit packet, with the exit sent once the process has ended.
final class FakeHelperShell: FakeServiceSession, @unchecked Sendable {
    private let device: FakeHelperDevice
    let process: FakeHelperDevice.Process

    init(device: FakeHelperDevice, process: FakeHelperDevice.Process) {
        self.device = device
        self.process = process
    }

    func opened() -> Data {
        device.shellOutput(process)?.bytes ?? Data()
    }

    func received(_ bytes: Data) -> (reply: Data, close: Bool) {
        (Data(), false)
    }

    func pull() -> (bytes: Data, close: Bool)? {
        device.shellOutput(process)
    }

    func closed() {
        device.shellClosed(process)
    }
}

/// One helper's socket: refuses a first frame without the token, then answers each request as the device scripts.
final class FakeHelperSocket: FakeServiceSession, @unchecked Sendable {
    private struct Incoming: Decodable {
        let id: Int?
        let op: String?
        let token: String?
    }

    private let device: FakeHelperDevice
    private let process: FakeHelperDevice.Process
    private let lock = NSLock()
    private var buffer = Data()
    private var authorised = false

    init(device: FakeHelperDevice, process: FakeHelperDevice.Process) {
        self.device = device
        self.process = process
    }

    func received(_ bytes: Data) -> (reply: Data, close: Bool) {
        var out = Data()
        for payload in lock.withLock({ takeFrames(bytes) }) {
            let text = String(decoding: payload, as: UTF8.self)
            let incoming = try? JSONDecoder().decode(Incoming.self, from: payload)
            let op = incoming?.op ?? "unreadable"
            let id = incoming?.id ?? -1
            if !lock.withLock({ authorised }) {
                guard op == "hello", incoming?.token == process.token else {
                    device.note("refused \(process.number)")
                    return (out, true)
                }
                lock.withLock { authorised = true }
            }
            device.record(FakeHelperDevice.Received(process: process.number, op: op, json: text))
            switch device.reply(to: op, json: text, process: process) {
            case .ok(let fields):
                out += Self.frame(Self.ok(id: id, fields: fields))
                if op == "quit", device.exitOnQuit {
                    out += Self.frame(Self.bye("quit", detail: nil))
                    device.exit(process, status: 0)
                    return (out, true)
                }
            case .okWithPayload(let fields, let payload):
                out += Self.frame(Self.ok(id: id, fields: fields))
                let count = UInt32(payload.count)
                out += Data([UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + payload
            case .error(let code, let message, let className, let resourceId, let inputType):
                let node = [
                    className.map { #","className":"\#($0)""# }, resourceId.map { #","resourceId":"\#($0)""# }, inputType.map { #","inputType":\#($0)"# },
                ].compactMap { $0 }.joined()
                out += Self.frame(#"{"id":\#(id),"ok":false,"error":{"code":"\#(code)","message":"\#(message)","detail":null\#(node)},"eventSeq":7}"#)
            case .bye(let reason):
                out += Self.frame(Self.bye(reason, detail: "no request within 10000 ms"))
                device.exit(process, status: 0)
                return (out, true)
            case .hangUp:
                device.exit(process, status: 6)
                return (out, true)
            case .silence:
                continue
            }
        }
        return (out, false)
    }

    func closed() {
        device.note("socket closed \(process.number)")
        device.exit(process, status: 0)
    }

    /// Whole frames from `bytes` and what came before; call with the lock held.
    private func takeFrames(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard buffer.count >= 4 + length else { break }
            payloads.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return payloads
    }

    static func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        let count = UInt32(body.count)
        return Data([UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + body
    }

    static func ok(id: Int, fields: String) -> String {
        let inner = fields.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()
        let sequence = inner.contains("\"eventSeq\"") ? "" : #","eventSeq":7"#
        return #"{"id":\#(id),"ok":true"# + (inner.isEmpty ? "" : "," + inner) + sequence + "}"
    }

    static func bye(_ reason: String, detail: String?) -> String {
        #"{"event":"bye","reason":"\#(reason)","detail":\#(detail.map { "\"\($0)\"" } ?? "null")}"#
    }
}
