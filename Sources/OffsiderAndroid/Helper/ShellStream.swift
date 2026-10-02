import Foundation

enum ShellStreamEvent: Equatable, Sendable {
    case line(String)
    /// The exit packet, with stdout not yet returned as a line and all of stderr.
    case exited(status: Int32, stdout: String, stderr: String)
}

/// An open `shell,v2,raw:` stream read as stdout lines and an exit status; Offsider never writes to it.
@MainActor
final class ShellStream {
    let serial: String
    let label: String
    private let stream: any AdbByteStream
    private var unread: Data
    private var decoder = AdbWire.ShellV2Decoder()
    private var stdout = Data()
    private var stderr = Data()
    private var lines: [String] = []
    private var exitStatus: Int32?
    private var isClosed = false

    /// `pending` (bytes that came with the service's `OKAY`) is decoded before anything read from the stream.
    init(_ opened: AdbServiceStream, serial: String, label: String) {
        stream = opened.stream
        unread = opened.pending
        self.serial = serial
        self.label = label
    }

    /// The next stdout line or the exit; throws `AdbConnectError.timedOut` when the deadline passes first.
    func next(deadline: ContinuousClock.Instant) async throws -> ShellStreamEvent {
        while true {
            if !lines.isEmpty {
                return .line(lines.removeFirst())
            }
            if let exitStatus {
                return .exited(status: exitStatus, stdout: Self.text(stdout), stderr: Self.text(stderr))
            }
            try await fill(deadline: deadline)
        }
    }

    /// Reads to the exit packet, skipping output; nil when the deadline passes or the stream ends first.
    func exitStatus(deadline: ContinuousClock.Instant) async -> Int32? {
        while exitStatus == nil {
            lines.removeAll()
            do {
                try await fill(deadline: deadline)
            } catch {
                return nil
            }
        }
        return exitStatus
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await stream.close()
    }

    private func fill(deadline: ContinuousClock.Instant) async throws {
        var chunk = unread
        unread = Data()
        if chunk.isEmpty {
            chunk = try await stream.read(upTo: 64 * 1024, deadline: deadline)
            if chunk.isEmpty {
                throw AndroidError.adbCommandFailed(serial: serial, command: label, detail: "the connection closed before the command finished")
            }
        }
        for packet in try decoder.feed(chunk) {
            switch packet.kind {
            case .stdout:
                stdout.append(packet.payload)
                splitLines()
            case .stderr:
                stderr.append(packet.payload)
            case .exit:
                exitStatus = Int32(packet.payload.first ?? 0)
            default:
                continue
            }
        }
    }

    private func splitLines() {
        while let newline = stdout.firstIndex(of: 0x0A) {
            let line = stdout[stdout.startIndex..<newline]
            lines.append(Self.text(Data(line)).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            stdout = Data(stdout[stdout.index(after: newline)...])
        }
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
