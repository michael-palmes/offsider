import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("adb wire framing")
struct AdbWireTests {
    @Test("a request is four lower-case hex digits of its length, then the service")
    func requestEncoding() throws {
        #expect(try AdbWire.request("host:version") == Data("000chost:version".utf8))
        #expect(try AdbWire.request(String(repeating: "a", count: 300)).prefix(4) == Data("012c".utf8))
    }

    @Test("a request longer than 65,535 bytes throws instead of wrapping its length")
    func overlongRequestThrows() {
        #expect(throws: AndroidError.self) {
            try AdbWire.request(String(repeating: "x", count: 65_536))
        }
    }

    @Test("OKAY and FAIL replies decode with the bytes they use")
    func statusReplies() throws {
        let okay = try #require(try AdbWire.status(from: Data("OKAYrest".utf8)))
        #expect(okay.status == .okay)
        #expect(okay.consumed == 4)

        let reply = Data("FAIL0020device 'emulator-5560' not foundtrailing".utf8)
        let fail = try #require(try AdbWire.status(from: reply))
        #expect(fail.status == .fail(message: "device 'emulator-5560' not found"))
        #expect(fail.consumed == 8 + 0x20)
    }

    @Test("an incomplete FAIL waits for more bytes")
    func incompleteFail() throws {
        #expect(try AdbWire.status(from: Data("FAI".utf8)) == nil)
        #expect(try AdbWire.status(from: Data("FAIL00".utf8)) == nil)
        #expect(try AdbWire.status(from: Data("FAIL0005abc".utf8)) == nil)
    }

    @Test("an unknown status word or a non-hex length is a protocol error")
    func malformedStatus() {
        #expect(throws: AndroidError.self) { try AdbWire.status(from: Data("NOPE".utf8)) }
        #expect(throws: AndroidError.self) { try AdbWire.length(fromHex: Data("00zz".utf8)) }
    }

    private static func packet(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let count = UInt32(payload.count)
        return [id, UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)] + payload
    }

    private static let stream: [UInt8] = packet(1, Array("hello\n".utf8)) + packet(2, Array("warn".utf8)) + packet(3, [137])

    private static let expected = [
        AdbWire.ShellPacket(kind: .stdout, payload: Data("hello\n".utf8)),
        AdbWire.ShellPacket(kind: .stderr, payload: Data("warn".utf8)),
        AdbWire.ShellPacket(kind: .exit, payload: Data([137])),
    ]

    @Test("shell v2 packets decode the same however the stream is split", arguments: Array(0...stream.count))
    func splitAnywhere(splitAt: Int) throws {
        var decoder = AdbWire.ShellV2Decoder()
        let first = try decoder.feed(Data(Self.stream[..<splitAt]))
        let second = try decoder.feed(Data(Self.stream[splitAt...]))
        #expect(first + second == Self.expected)
    }

    @Test("shell v2 packets decode when fed one byte at a time")
    func byteAtATime() throws {
        var decoder = AdbWire.ShellV2Decoder()
        var packets: [AdbWire.ShellPacket] = []
        for byte in Self.stream {
            packets += try decoder.feed(Data([byte]))
        }
        #expect(packets == Self.expected)
    }

    @Test("an unknown shell packet id throws")
    func unknownPacketId() {
        var decoder = AdbWire.ShellV2Decoder()
        #expect(throws: AndroidError.self) {
            try decoder.feed(Data(Self.packet(9, [1])))
        }
    }
}
