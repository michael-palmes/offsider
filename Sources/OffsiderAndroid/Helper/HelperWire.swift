import Foundation

/// A helper message Offsider could not read, or one that breaks the protocol.
struct HelperProtocolError: Error, Equatable, Sendable {
    let detail: String
}

/// The helper's framing: a 4-byte big-endian length, then that many bytes of UTF-8 JSON.
enum HelperWire {
    static let maxFrameBytes = 32 << 20

    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameBytes else {
            throw HelperProtocolError(detail: "a frame of \(payload.count) bytes is longer than \(maxFrameBytes)")
        }
        let count = UInt32(payload.count)
        return Data([UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + payload
    }

    /// Frames may split anywhere across reads; a length above the cap throws before anything is buffered for it.
    struct FrameDecoder: Sendable {
        private var buffer = Data()

        mutating func feed(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var payloads: [Data] = []
            while buffer.count >= 4 {
                let header = [UInt8](buffer.prefix(4))
                let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                guard length <= HelperWire.maxFrameBytes else {
                    throw HelperProtocolError(detail: "the helper announced a frame of \(length) bytes, more than \(HelperWire.maxFrameBytes)")
                }
                guard buffer.count >= 4 + length else { break }
                payloads.append(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return payloads
        }
    }

    /// The ready line; lines that do not start with `{` are skipped by the caller.
    static func ready(fromLine line: String) throws -> HelperReady {
        let ready: HelperReady
        do {
            ready = try JSONDecoder().decode(HelperReady.self, from: Data(line.utf8))
        } catch {
            throw HelperProtocolError(detail: "the ready line is unreadable: \(line.prefix(200))")
        }
        guard ready.event == "ready" else {
            throw HelperProtocolError(detail: "expected a ready line, got \(line.prefix(200))")
        }
        return ready
    }
}

struct HelperReady: Decodable, Equatable, Sendable {
    let event: String
    let `protocol`: Int
    let helper: String
    let pid: Int32
    /// `offsider-<32 hex>`, an abstract socket name.
    let socket: String
    /// 64 hex digits; the first frame must carry it.
    let token: String
    let sdkInt: Int
}
