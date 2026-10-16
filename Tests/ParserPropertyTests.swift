import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid
@testable import OffsiderIOSDevice

/// SplitMix64: the same bytes for a seed on every run and machine.
struct SeededBytes {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
    }

    /// `data` cut at random points into chunks, some empty.
    mutating func split(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(data.endIndex, start + int(0...max(1, data.count / 3)))
            chunks.append(Data(data[start..<end]))
            start = end
        }
        return chunks
    }
}

@Suite("Parser properties")
struct ParserPropertyTests {
    static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89]

    private static func shellPacket(_ id: UInt8, _ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([id, UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)]) + payload
    }

    private static func helperFrame(_ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + payload
    }

    @Test("shell v2: valid packets decode the same however the stream is split; random bytes never trap or overbuffer", arguments: seeds)
    func shellV2(seed: UInt64) throws {
        var random = SeededBytes(seed: seed)
        let packets = (0..<random.int(1...20)).map { _ in (UInt8(random.int(0...5)), random.bytes(random.int(0...2048))) }
        let stream = packets.reduce(Data()) { $0 + Self.shellPacket($1.0, $1.1) }

        var whole = AdbWire.ShellV2Decoder(maxPacketBytes: 4096)
        let expected = try whole.feed(stream)
        var split = AdbWire.ShellV2Decoder(maxPacketBytes: 4096)
        var decoded: [AdbWire.ShellPacket] = []
        for chunk in random.split(stream) {
            decoded += try split.feed(chunk)
            #expect(split.bufferedCount <= 5 + 4096 + chunk.count)
        }
        #expect(decoded == expected)
        #expect(expected.map(\.payload) == packets.map(\.1))

        var noisy = AdbWire.ShellV2Decoder(maxPacketBytes: 4096)
        for chunk in random.split(random.bytes(random.int(0...8192))) {
            do { _ = try noisy.feed(chunk) } catch { break }
            #expect(noisy.bufferedCount <= 5 + 4096 + chunk.count)
        }
    }

    @Test("helper frames: valid frames decode the same however split; random bytes never trap", arguments: seeds)
    func helperFrames(seed: UInt64) throws {
        var random = SeededBytes(seed: seed)
        let payloads = (0..<random.int(1...20)).map { _ in random.bytes(random.int(0...4096)) }
        let stream = payloads.reduce(Data()) { $0 + Self.helperFrame($1) }

        var split = HelperWire.FrameDecoder()
        var decoded: [Data] = []
        for chunk in random.split(stream) { decoded += try split.feed(chunk) }
        #expect(decoded == payloads)

        var noisy = HelperWire.FrameDecoder()
        for chunk in random.split(random.bytes(random.int(0...8192))) {
            do { _ = try noisy.feed(chunk) } catch { break }
            #expect(noisy.bufferedCount <= 8192 + 4)
        }
    }

    @Test("usbmux frames round-trip, and random headers never trap", arguments: seeds)
    func usbmuxFrames(seed: UInt64) throws {
        var random = SeededBytes(seed: seed)
        let frame = UsbmuxFrame(tag: UInt32(truncatingIfNeeded: random.next()), payload: random.bytes(random.int(0...4096)))
        #expect(try UsbmuxFrame.decode(frame.encoded()) == frame)
        for _ in 0..<200 {
            let bytes = random.bytes(random.int(0...64))
            if let header = try? UsbmuxFrame.header(bytes) {
                #expect(header.length <= UsbmuxFrame.maximumLength)
            }
            _ = try? UsbmuxFrame.decode(bytes)
        }
    }

    @Test("usbmux HTTP: a response read in pieces parses once complete and the same; random heads never trap", arguments: seeds)
    func usbmuxHTTP(seed: UInt64) throws {
        var random = SeededBytes(seed: seed)
        let body = random.bytes(random.int(0...2048))
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        var received = Data()
        var parsed: UsbmuxHTTPResponse?
        for chunk in random.split(response) {
            #expect(parsed == nil)
            received.append(chunk)
            parsed = try UsbmuxHTTP.parseResponse(received)
        }
        #expect(parsed?.body == body)
        #expect(parsed?.status == 200)

        for _ in 0..<50 {
            var noise = random.bytes(random.int(0...512))
            if random.int(0...1) == 1 { noise += Data("\r\n\r\n".utf8) + random.bytes(random.int(0...64)) }
            _ = try? UsbmuxHTTP.parseResponse(noise)
        }
    }

    @Test("raw screencap headers: a real header is found after leading noise; random bytes never trap", arguments: seeds)
    func screencapHeader(seed: UInt64) throws {
        var random = SeededBytes(seed: seed)
        let width = random.int(1...32), height = random.int(1...32)
        var header = Data()
        for word in [UInt32(width), UInt32(height), 1, 0] {
            withUnsafeBytes(of: word.littleEndian) { header.append(contentsOf: $0) }
        }
        let lead = Data("[Warning] Multiple displays were found\n".utf8)
        let output = lead + header + random.bytes(width * height * 4)
        let found = try #require(try AndroidScreenCapture.rawHeader(output))
        #expect(found.width == width && found.height == height && found.offset == lead.count)

        for _ in 0..<100 {
            _ = try? AndroidScreenCapture.rawHeader(random.bytes(random.int(0...600)))
        }
    }

    @Test("uiautomator dumps: random and truncated XML never trap", arguments: seeds)
    func uiautomator(seed: UInt64) {
        var random = SeededBytes(seed: seed)
        let valid = #"<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="Hi" resource-id="a" class="android.widget.TextView" package="p" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1e19,nan]" /></hierarchy>"#
        _ = try? UIAutomatorDump.parse(valid)
        let bytes = Data(valid.utf8)
        for _ in 0..<20 {
            _ = try? UIAutomatorDump.parse(String(decoding: bytes.prefix(random.int(0...bytes.count)), as: UTF8.self))
            _ = try? UIAutomatorDump.parse(String(decoding: random.bytes(random.int(0...256)), as: UTF8.self))
        }
    }

    private static func value(_ random: inout SeededBytes, depth: Int) -> MediaStreamValue {
        switch random.int(0...(depth > 3 ? 6 : 8)) {
        case 0: return .string(String(decoding: random.bytes(random.int(0...8)), as: UTF8.self))
        case 1: return .bool(random.int(0...1) == 1)
        case 2: return .int(Int64(bitPattern: random.next()))
        case 3: return .uint([0, 1, 4096, UInt64(UInt32.max), UInt64.max, random.next()][random.int(0...5)])
        case 4: return .double([Double.nan, .infinity, -1, 1e300, 0][random.int(0...4)])
        case 5: return .data(random.bytes(random.int(0...16)))
        case 6: return .uuid(UUID())
        case 7: return .array((0..<random.int(0...3)).map { _ in value(&random, depth: depth + 1) })
        default:
            let keys = ["negotiatorAnswer", "answer", "connection", "streamConfig", "RemoteSSRC", "CustomWidth", "CustomHeight", "FrameRate", "x"]
            return .dictionary(Dictionary((0..<random.int(0...5)).map { _ in (keys[random.int(0...keys.count - 1)], value(&random, depth: depth + 1)) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    @Test("media stream answers: random value trees never trap, and a size is always in range", arguments: seeds)
    func mediaStreamAnswer(seed: UInt64) {
        var random = SeededBytes(seed: seed)
        for _ in 0..<300 {
            if let answer = try? MediaStreamAnswer.parse(Self.value(&random, depth: 0)) {
                #expect((1...DeviceSessionLimits.maxFrameDimension).contains(answer.width))
                #expect((1...DeviceSessionLimits.maxFrameDimension).contains(answer.height))
            }
        }
    }

    @Test("pixel math never traps on any side or ratio, and only sizes it accepts have a byte count", arguments: seeds)
    func pixelMath(seed: UInt64) {
        var random = SeededBytes(seed: seed)
        let sides = [Int.min, -1, 0, 1, PixelMath.maxSide, PixelMath.maxSide + 1, Int.max]
        let doubles = [Double.nan, .infinity, -.infinity, 1e19, -1e19, 0.5, -0.5, Double(Int32.max) + 1]
        for _ in 0..<500 {
            let width = random.int(0...3) == 0 ? sides[random.int(0...sides.count - 1)] : Int(truncatingIfNeeded: random.next())
            let height = random.int(0...3) == 0 ? sides[random.int(0...sides.count - 1)] : random.int(-10...20_000)
            if let bytes = PixelMath.byteCount(width: width, height: height) {
                #expect(PixelMath.isSide(width) && PixelMath.isSide(height) && bytes == width * height * 4)
            }
            let double = random.int(0...1) == 0 ? doubles[random.int(0...doubles.count - 1)] : Double(bitPattern: random.next())
            #expect((Int(Int32.min)...Int(Int32.max)).contains(PixelMath.roundedPixel(double)))
            #expect((1...PixelMath.maxSwipeSteps).contains(PixelMath.swipeSteps(double)))
        }
    }
}

/// Every length-prefixed reader in the repo, handed a header that announces 4 GiB.
@Suite("Length-prefixed decoders refuse FF FF FF FF")
struct LengthPrefixCapTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        /// Throws for a refused header; returns the bytes the decoder still holds, nil when it holds none it can report.
        let run: @Sendable () throws -> Int?
    }

    static let maxed = Data([0xFF, 0xFF, 0xFF, 0xFF])

    static let cases: [Case] = [
        Case(testDescription: "adb shell v2 packet") {
            var decoder = AdbWire.ShellV2Decoder()
            do { _ = try decoder.feed(Data([1]) + maxed) } catch { #expect(decoder.bufferedCount == 0); throw error }
            return decoder.bufferedCount
        },
        Case(testDescription: "adb status FAIL length") { _ = try AdbWire.status(from: Data("FAIL".utf8) + maxed); return nil },
        Case(testDescription: "adb sync FAIL reply") { _ = try AdbSync.reply(from: Data("FAIL".utf8) + maxed); return nil },
        Case(testDescription: "helper frame") {
            var decoder = HelperWire.FrameDecoder()
            do { _ = try decoder.feed(maxed) } catch { #expect(decoder.bufferedCount <= 4); throw error }
            return decoder.bufferedCount
        },
        Case(testDescription: "usbmux frame header") { _ = try UsbmuxFrame.header(maxed + Data(count: 12)); return nil },
        Case(testDescription: "usbmux HTTP Content-Length") {
            _ = try UsbmuxHTTP.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 4294967295\r\n\r\n".utf8)); return nil
        },
        Case(testDescription: "usbmux HTTP head with no end") { _ = try UsbmuxHTTP.parseResponse(Data(repeating: 0xFF, count: 16 * 1024 + 1)); return nil },
        Case(testDescription: "session broker frame") {
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
            let reader = DeviceSessionChannel(descriptor: pair[0])
            defer { reader.close(); Darwin.close(pair[1]) }
            _ = maxed.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, 4) }
            _ = try reader.readFrame(limit: DeviceSessionWire.maxPayloadBytes, timeout: .seconds(1))
            return nil
        },
    ]

    @Test("a 4 GiB length is refused at the header, holding nothing for it", arguments: cases)
    func refusesAtHeader(_ decoder: Case) {
        #expect(throws: (any Error).self) { _ = try decoder.run() }
    }
}
