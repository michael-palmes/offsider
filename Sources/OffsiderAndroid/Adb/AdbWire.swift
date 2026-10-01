import Foundation

/// The adb server's smart-socket framing, written from AOSP adb's `docs/dev/services.md`.
enum AdbWire {
    static let maxRequestLength = 0xFFFF

    /// Four lower-case hex digits of the UTF-8 length, then the payload.
    static func request(_ service: String) throws -> Data {
        let payload = Data(service.utf8)
        guard payload.count <= maxRequestLength else {
            throw AndroidError.adbProtocol("request of \(payload.count) bytes is longer than \(maxRequestLength)")
        }
        return Data(String(format: "%04x", payload.count).utf8) + payload
    }

    enum Status: Equatable, Sendable {
        case okay
        case fail(message: String)
    }

    static func length(fromHex four: Data) throws -> Int {
        guard four.count == 4,
              let text = String(data: four, encoding: .ascii),
              text.allSatisfy(\.isHexDigit),
              let value = Int(text, radix: 16) else {
            throw AndroidError.adbProtocol("bad length \(printable(four))")
        }
        return value
    }

    /// A whole status reply (`OKAY`, or `FAIL` with a hex-length message) from the start of `buffer`; nil until complete.
    static func status(from buffer: Data) throws -> (status: Status, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let word = Data(buffer.prefix(4))
        switch String(data: word, encoding: .ascii) {
        case "OKAY":
            return (.okay, 4)
        case "FAIL":
            guard buffer.count >= 8 else { return nil }
            let count = try length(fromHex: Data(buffer.dropFirst(4).prefix(4)))
            guard buffer.count >= 8 + count else { return nil }
            let message = String(decoding: buffer.dropFirst(8).prefix(count), as: UTF8.self)
            return (.fail(message: message), 8 + count)
        default:
            throw AndroidError.adbProtocol("expected OKAY or FAIL, got \(printable(word))")
        }
    }

    struct ShellPacket: Equatable, Sendable {
        enum Kind: UInt8, Sendable {
            case stdin = 0
            case stdout = 1
            case stderr = 2
            case exit = 3
            case closeStdin = 4
            case windowSizeChange = 5
        }

        let kind: Kind
        let payload: Data
    }

    /// Shell protocol v2: a 1-byte id, a 4-byte little-endian length, then the payload; packets may split across reads.
    struct ShellV2Decoder: Sendable {
        private var pending = Data()

        mutating func feed(_ bytes: Data) throws -> [ShellPacket] {
            pending.append(bytes)
            var packets: [ShellPacket] = []
            while pending.count >= 5 {
                let header = [UInt8](pending.prefix(5))
                guard let kind = ShellPacket.Kind(rawValue: header[0]) else {
                    throw AndroidError.adbProtocol("unknown shell packet id \(header[0])")
                }
                let count = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
                guard pending.count >= 5 + count else { break }
                packets.append(ShellPacket(kind: kind, payload: Data(pending.dropFirst(5).prefix(count))))
                pending = Data(pending.dropFirst(5 + count))
            }
            return packets
        }
    }

    private static func printable(_ data: Data) -> String {
        "\"" + String(decoding: data.prefix(16), as: UTF8.self).unicodeScalars
            .map { $0.isASCII && $0.value >= 0x20 ? String($0) : "?" }
            .joined() + "\""
    }
}
