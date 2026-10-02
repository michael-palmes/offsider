import Foundation

/// adb's file sync protocol after `sync:`, from AOSP's `SYNC.TXT`: a four-letter id, then a little-endian 32-bit value.
enum AdbSync {
    static let maxChunk = 64 * 1024
    static let maxPathBytes = 1024

    /// `SEND` + LE32 length + "<path>,<mode in decimal>"
    static func send(path: String, mode: UInt32) throws -> Data {
        let pathBytes = path.utf8.count
        guard pathBytes <= maxPathBytes else {
            throw AndroidError.adbProtocol("a sync path of \(pathBytes) bytes is longer than \(maxPathBytes)")
        }
        let payload = Data("\(path),\(mode)".utf8)
        return message("SEND", UInt32(payload.count)) + payload
    }

    /// `DATA` + LE32 + at most 64 KiB each; an empty file has none.
    static func data(_ bytes: Data) -> [Data] {
        stride(from: 0, to: bytes.count, by: maxChunk).map { offset in
            let chunk = Data(bytes.dropFirst(offset).prefix(maxChunk))
            return message("DATA", UInt32(chunk.count)) + chunk
        }
    }

    /// `DONE` + LE32 mtime in seconds.
    static func done(mtime: UInt32) -> Data {
        message("DONE", mtime)
    }

    /// `QUIT` + LE32 0
    static let quit = message("QUIT", 0)

    enum Reply: Equatable, Sendable {
        case okay
        case fail(String)
    }

    /// A whole reply from the start of `buffer`, or nil until complete.
    static func reply(from buffer: Data) throws -> (reply: Reply, consumed: Int)? {
        guard buffer.count >= 8 else { return nil }
        let header = [UInt8](buffer.prefix(8))
        let value = Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
        switch String(decoding: header.prefix(4), as: UTF8.self) {
        case "OKAY":
            return (.okay, 8)
        case "FAIL":
            guard value <= maxChunk else {
                throw AndroidError.adbProtocol("a sync failure message of \(value) bytes")
            }
            guard buffer.count >= 8 + value else { return nil }
            return (.fail(String(decoding: buffer.dropFirst(8).prefix(value), as: UTF8.self)), 8 + value)
        default:
            throw AndroidError.adbProtocol("expected OKAY or FAIL after a sync push, got \(AdbWire.printable(Data(header.prefix(4))))")
        }
    }

    private static func message(_ id: String, _ value: UInt32) -> Data {
        Data(id.utf8) + Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}

extension AdbClient {
    /// One `sync:` connection: SEND, DATA chunks, DONE, the reply, QUIT. A FAIL reply throws `adbCommandFailed`.
    func push(_ bytes: Data, to path: String, mode: UInt32 = 0o100644, mtime: UInt32, on serial: String, timeout: Duration) async throws {
        let label = "push \(path)"
        let request = try AdbSync.send(path: path, mode: mode)
        let deadline = ContinuousClock.now + timeout
        let opened = try await openService("sync:", on: serial, timeout: timeout)
        do {
            try await opened.stream.write(request, deadline: deadline)
            for chunk in AdbSync.data(bytes) {
                try await opened.stream.write(chunk, deadline: deadline)
            }
            try await opened.stream.write(AdbSync.done(mtime: mtime), deadline: deadline)

            var buffer = opened.pending
            while true {
                if let decoded = try AdbSync.reply(from: buffer) {
                    if case .fail(let message) = decoded.reply {
                        throw AndroidError.adbCommandFailed(serial: serial, command: label, detail: message)
                    }
                    // The file is in place once OKAY arrives, so a lost QUIT does not fail the push.
                    try? await opened.stream.write(AdbSync.quit, deadline: deadline)
                    break
                }
                let chunk = try await opened.stream.read(upTo: 4096, deadline: deadline)
                guard !chunk.isEmpty else {
                    throw AndroidError.adbCommandFailed(serial: serial, command: label, detail: "the device closed the sync connection before confirming the push")
                }
                buffer.append(chunk)
            }
        } catch {
            await opened.stream.close()
            if let error = error as? AdbConnectError {
                throw deviceError(error, serial: serial, command: label, timeout: timeout)
            }
            throw error
        }
        await opened.stream.close()
    }
}
