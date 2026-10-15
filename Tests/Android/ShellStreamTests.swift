import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Shell stream")
@MainActor
struct ShellStreamTests {
    /// Hands out scripted chunks, then the end of the stream.
    private final class ScriptedStream: AdbByteStream, @unchecked Sendable {
        private var chunks: [Data]
        private(set) var reads = 0

        init(_ chunks: [Data]) { self.chunks = chunks }

        func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {}
        func read(upTo count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
            reads += 1
            return chunks.isEmpty ? Data() : chunks.removeFirst()
        }
        func close() async {}
    }

    private static func packet(_ id: UInt8, _ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([id, UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)]) + payload
    }

    private static func stream(_ chunks: [Data]) -> ShellStream {
        ShellStream(AdbServiceStream(stream: ScriptedStream(chunks), pending: Data()), serial: "emulator-5554", label: "helper")
    }

    private var deadline: ContinuousClock.Instant { .now + .seconds(5) }

    @Test("lines arrive one by one, then the exit with what is left")
    func linesThenExit() async throws {
        let shell = Self.stream([Self.packet(1, Data("ready\nhalf".utf8)) + Self.packet(3, Data([7]))])
        #expect(try await shell.next(deadline: deadline) == .line("ready"))
        #expect(try await shell.next(deadline: deadline) == .exited(status: 7, stdout: "half", stderr: ""))
    }

    @Test("stdout with no newline past 1 MiB fails with a clean error")
    func pendingLineCap() async {
        let chunk = Self.packet(1, Data(repeating: 0x78, count: 600_000))
        let shell = Self.stream([chunk, chunk])
        let error = await #expect(throws: AndroidError.self) { try await shell.next(deadline: deadline) }
        #expect(error?.message.contains("a line or error over 1 MB") == true)
    }

    @Test("a packet header announcing more than 1 MiB fails before its bytes arrive")
    func packetHeaderCap() async {
        let shell = Self.stream([Data([1, 0xFF, 0xFF, 0xFF, 0xFF])])
        let error = await #expect(throws: AndroidError.self) { try await shell.next(deadline: deadline) }
        #expect(error?.kind == .adbCommandFailed)
    }

    @Test("stderr past 1 MiB fails too")
    func stderrCap() async {
        let chunk = Self.packet(2, Data(repeating: 0x65, count: 600_000))
        let shell = Self.stream([chunk, chunk])
        await #expect(throws: AndroidError.self) { try await shell.next(deadline: deadline) }
    }
}
