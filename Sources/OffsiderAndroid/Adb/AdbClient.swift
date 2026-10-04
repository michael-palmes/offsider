import Foundation
import OffsiderCore

struct AdbShellResult: Equatable, Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { Self.text(stdout) }
    var stderrText: String { Self.text(stderr) }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }
}

/// An open device service; `pending` holds bytes that arrived with its `OKAY`, which come before anything read from `stream`.
struct AdbServiceStream: Sendable {
    let stream: any AdbByteStream
    let pending: Data
}

/// A client of the adb server: one connection per service, as the protocol requires.
actor AdbClient {
    let endpoint: LoopbackEndpoint
    private let connector: any AdbConnecting
    private let connectTimeout: Duration
    private let hostTimeout: Duration
    let timing: AndroidTiming

    init(
        endpoint: LoopbackEndpoint,
        connector: any AdbConnecting,
        connectTimeout: Duration = .seconds(1),
        hostTimeout: Duration = .seconds(3),
        timing: AndroidTiming = .disabled
    ) {
        self.endpoint = endpoint
        self.connector = connector
        self.connectTimeout = connectTimeout
        self.hostTimeout = hostTimeout
        self.timing = timing
    }

    func serverVersion() async throws -> Int {
        let payload = try await hostQuery("host:version")
        guard let version = Int(payload.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
            throw AndroidError.adbProtocol("host:version replied \(payload.prefix(16))")
        }
        return version
    }

    func devices() async throws -> [AdbDeviceEntry] {
        try await timing.measure(.adbDevices) {
            AdbDeviceListParser.parse(try await hostQuery("host:devices-l"))
        }
    }

    /// `host:mdns:check`: the server's own answer about its mDNS discovery, unparsed.
    func mdnsCheck() async throws -> String {
        try await hostQuery("host:mdns:check")
    }

    /// A read-only device service answered with one length-prefixed string, such as `reverse:list-forward`.
    func deviceQuery(_ service: String, on serial: String, timeout: Duration = .seconds(5)) async throws -> String {
        let connection = try await openDevice(serial, service: service, label: service, timeout: timeout)
        return try await closing(connection, serial: serial, command: service, timeout: timeout) {
            let length = try AdbWire.length(fromHex: try await connection.readExactly(4))
            return String(decoding: try await connection.readExactly(length), as: UTF8.self)
        }
    }

    /// `host:transport:<serial>`, then `shell,v2,raw:<command>`; reads until the exit packet.
    /// `label` names the command in errors when the script itself is too long to quote.
    func shell(_ command: String, on serial: String, timeout: Duration = .seconds(10), label: String? = nil) async throws -> AdbShellResult {
        try await timing.measure(.adbShell) {
            try await runShell(command, on: serial, timeout: timeout, label: label)
        }
    }

    private func runShell(_ command: String, on serial: String, timeout: Duration, label: String?) async throws -> AdbShellResult {
        let name = label ?? command
        let connection = try await openDevice(serial, service: "shell,v2,raw:" + command, label: name, timeout: timeout)
        var decoder = AdbWire.ShellV2Decoder()
        var stdout = Data()
        var stderr = Data()
        return try await closing(connection, serial: serial, command: name, timeout: timeout) {
            var chunk = connection.takeBuffered()
            while true {
                for packet in try decoder.feed(chunk) {
                    switch packet.kind {
                    case .stdout: stdout.append(packet.payload)
                    case .stderr: stderr.append(packet.payload)
                    case .exit: return AdbShellResult(status: Int32(packet.payload.first ?? 0), stdout: stdout, stderr: stderr)
                    default: continue
                    }
                }
                chunk = try await connection.stream.read(upTo: 64 * 1024, deadline: connection.deadline)
                if chunk.isEmpty {
                    throw AndroidError.adbCommandFailed(serial: serial, command: name, detail: "the connection closed before the command finished")
                }
            }
        }
    }

    /// `host:transport:<serial>`, then `exec:<command>`; raw stdout until the end of the stream.
    func exec(_ command: String, on serial: String, timeout: Duration = .seconds(15)) async throws -> Data {
        let connection = try await openDevice(serial, service: "exec:" + command, label: command, timeout: timeout)
        var output = connection.takeBuffered()
        return try await closing(connection, serial: serial, command: command, timeout: timeout) {
            while true {
                let chunk = try await connection.stream.read(upTo: 256 * 1024, deadline: connection.deadline)
                if chunk.isEmpty { return output }
                output.append(chunk)
            }
        }
    }

    /// The raw stream after `OKAY` for any device service; the caller owns it and must close it.
    func openService(_ service: String, on serial: String, timeout: Duration) async throws -> AdbServiceStream {
        let connection = try await openDevice(serial, service: service, label: service, timeout: timeout)
        return AdbServiceStream(stream: connection.stream, pending: connection.takeBuffered())
    }

    private func hostQuery(_ service: String) async throws -> String {
        let connection = try await connect(timeout: hostTimeout)
        do {
            try await connection.send(service)
            if case .fail(let message) = try await connection.readStatus() {
                throw AndroidError.adbProtocol("\(service) failed: \(message)")
            }
            let length = try AdbWire.length(fromHex: try await connection.readExactly(4))
            let payload = String(decoding: try await connection.readExactly(length), as: UTF8.self)
            await connection.stream.close()
            return payload
        } catch {
            await connection.stream.close()
            if let error = error as? AdbConnectError {
                throw serverError(error, seconds: Int(hostTimeout.components.seconds))
            }
            throw error
        }
    }

    /// Runs `body`, closes the connection either way, and maps socket failures to device errors.
    private func closing<T>(
        _ connection: AdbConnection,
        serial: String,
        command: String,
        timeout: Duration,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            let value = try await body()
            await connection.stream.close()
            return value
        } catch {
            await connection.stream.close()
            if let error = error as? AdbConnectError {
                throw deviceError(error, serial: serial, command: command, timeout: timeout)
            }
            throw error
        }
    }

    private func openDevice(_ serial: String, service: String, label: String, timeout: Duration) async throws -> AdbConnection {
        let connection = try await connect(timeout: timeout)
        do {
            try await connection.send("host:transport:" + serial)
            if case .fail(let message) = try await connection.readStatus() {
                throw transportError(message, serial: serial)
            }
            try await connection.send(service)
            if case .fail(let message) = try await connection.readStatus() {
                throw AndroidError.adbCommandFailed(serial: serial, command: label, detail: message)
            }
            return connection
        } catch {
            await connection.stream.close()
            if let error = error as? AdbConnectError {
                throw deviceError(error, serial: serial, command: label, timeout: timeout)
            }
            throw error
        }
    }

    private func connect(timeout: Duration) async throws -> AdbConnection {
        do {
            let stream = try await connector.connect(to: endpoint, timeout: connectTimeout)
            return AdbConnection(stream: stream, deadline: ContinuousClock.now + timeout)
        } catch let error as AdbConnectError {
            throw serverError(error, seconds: Int(connectTimeout.components.seconds))
        }
    }

    private func serverError(_ error: AdbConnectError, seconds: Int) -> AndroidError {
        switch error {
        case .refused, .noSuchSocket:
            return .adbServerNotRunning(endpoint: endpoint.description)
        case .timedOut, .failed:
            return .adbServerNoAnswer(endpoint: endpoint.description, seconds: seconds)
        }
    }

    func deviceError(_ error: AdbConnectError, serial: String, command: String, timeout: Duration) -> AndroidError {
        guard error == .timedOut else { return serverError(error, seconds: Int(connectTimeout.components.seconds)) }
        return .adbCommandFailed(serial: serial, command: command, detail: "no answer within \(timeout.components.seconds) s")
    }

    private func transportError(_ message: String, serial: String) -> AndroidError {
        let emulator = if case .androidSerial = DeviceIDClassifier.classify(serial) { true } else { false }
        if message.contains("not found") { return emulator ? .serialNotRunning(serial) : .phoneNotConnected(serial) }
        if message.contains("offline") { return emulator ? .deviceOffline(serial, avd: nil) : .phoneOffline(serial) }
        if message.contains("unauthorized") { return emulator ? .deviceUnauthorised(serial, avd: nil) : .phoneUnauthorised(serial) }
        return .adbCommandFailed(serial: serial, command: "host:transport:\(serial)", detail: message)
    }
}

/// One service connection with the bytes read past the last status reply.
private final class AdbConnection: @unchecked Sendable {
    let stream: any AdbByteStream
    let deadline: ContinuousClock.Instant
    private var buffer = Data()

    init(stream: any AdbByteStream, deadline: ContinuousClock.Instant) {
        self.stream = stream
        self.deadline = deadline
    }

    func send(_ service: String) async throws {
        try await stream.write(try AdbWire.request(service), deadline: deadline)
    }

    func readStatus() async throws -> AdbWire.Status {
        while true {
            if let reply = try AdbWire.status(from: buffer) {
                buffer = Data(buffer.dropFirst(reply.consumed))
                return reply.status
            }
            try await fill()
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill()
        }
        let bytes = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return bytes
    }

    func takeBuffered() -> Data {
        defer { buffer = Data() }
        return buffer
    }

    private func fill() async throws {
        let chunk = try await stream.read(upTo: 64 * 1024, deadline: deadline)
        guard !chunk.isEmpty else { throw AndroidError.adbProtocol("the adb server closed the connection early") }
        buffer.append(chunk)
    }
}
