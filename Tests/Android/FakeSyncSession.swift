import Foundation
@testable import OffsiderAndroid

/// A device's `sync:` service: records Offsider's requests, keeps the pushed bytes and answers `DONE` as scripted.
final class FakeSyncSession: FakeServiceSession, @unchecked Sendable {
    enum Request: Equatable {
        /// The `SEND` payload, "<path>,<mode>".
        case send(String)
        /// One `DATA` chunk's length.
        case data(Int)
        case done(mtime: UInt32)
        case quit
        case unknown(String)
    }

    enum Answer {
        case okay
        case fail(String)
        /// Closes the connection without a reply.
        case hangUp
        /// Neither replies nor closes.
        case silence
    }

    private let lock = NSLock()
    private let answer: @Sendable (_ target: String, _ file: Data) -> Answer
    private var pending = Data()
    private var written = Data()
    private var recorded: [Request] = []
    private var target = ""
    private var contents = Data()
    private var wasClosed = false

    /// `answer` gets the `SEND` target ("<path>,<mode>") and the bytes received, when `DONE` arrives.
    init(answer: @escaping @Sendable (_ target: String, _ file: Data) -> Answer = { _, _ in .okay }) {
        self.answer = answer
    }

    var requests: [Request] { lock.withLock { recorded } }
    /// Everything Offsider wrote after `OKAY`, for byte-exact checks.
    var bytesWritten: Data { lock.withLock { written } }
    var file: Data { lock.withLock { contents } }
    var isClosed: Bool { lock.withLock { wasClosed } }

    func received(_ bytes: Data) -> (reply: Data, close: Bool) {
        lock.withLock {
            written.append(bytes)
            pending.append(bytes)
            var reply = Data()
            var close = false
            while pending.count >= 8 {
                let header = [UInt8](pending.prefix(8))
                let id = String(decoding: header.prefix(4), as: UTF8.self)
                let value = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
                let payloadLength = id == "SEND" || id == "DATA" ? Int(value) : 0
                guard pending.count >= 8 + payloadLength else { break }
                let payload = Data(pending.dropFirst(8).prefix(payloadLength))
                pending = Data(pending.dropFirst(8 + payloadLength))
                switch id {
                case "SEND":
                    target = String(decoding: payload, as: UTF8.self)
                    recorded.append(.send(target))
                case "DATA":
                    recorded.append(.data(payload.count))
                    contents.append(payload)
                case "DONE":
                    recorded.append(.done(mtime: value))
                    switch answer(target, contents) {
                    case .okay:
                        reply.append(Data("OKAY".utf8) + Data([0, 0, 0, 0]))
                    case .fail(let message):
                        let text = Data(message.utf8)
                        let count = UInt32(text.count)
                        reply.append(Data("FAIL".utf8) + Data([UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)]) + text)
                        close = true
                    case .hangUp:
                        close = true
                    case .silence:
                        break
                    }
                case "QUIT":
                    recorded.append(.quit)
                    close = true
                default:
                    recorded.append(.unknown(id))
                    close = true
                }
            }
            return (reply, close)
        }
    }

    func closed() {
        lock.withLock { wasClosed = true }
    }
}
