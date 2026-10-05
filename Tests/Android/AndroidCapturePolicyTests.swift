import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Raw screencap parsing")
struct ScreencapRawTests {
    nonisolated static let letters = AndroidScreenCaptureTests.rgba(AndroidScreenCaptureTests.letters)
    /// What a phone with several displays prints before the image when `screencap` has no `-d`.
    nonisolated static let warning = Data("[Warning] Multiple displays were found, but no display id was specified! Defaulting to the first display found, however this default is not guaranteed to be consistent across captures. A display id should be specified.\nA display ID can be specified with the [-d display-id] option.\nSee \"dumpsys SurfaceFlinger --display-id\" for valid display IDs.\n".utf8)

    static func header(_ words: [UInt32]) -> Data {
        Data(words.flatMap { word in (0..<4).map { UInt8(word >> ($0 * 8) & 0xFF) } })
    }

    static func raw(format: UInt32 = 1, headerWords: Int = 4) -> Data {
        header(Array([3, 2, format, 1].prefix(headerWords))) + letters
    }

    @Test("the 16-byte header of API 28 and later, with its colour space word, gives the pixels after it")
    func sixteenByteHeader() throws {
        let pixels = try AndroidScreenCapture.pixels(fromScreencapRaw: Self.raw())
        #expect(pixels == AndroidScreenCapture.Pixels(width: 3, height: 2, bytes: Self.letters))
    }

    @Test("the older 12-byte header is read too")
    func twelveByteHeader() throws {
        let pixels = try AndroidScreenCapture.pixels(fromScreencapRaw: Self.raw(headerWords: 3))
        #expect(pixels == AndroidScreenCapture.Pixels(width: 3, height: 2, bytes: Self.letters))
    }

    @Test("a multi-display warning before the header is skipped")
    func warningSkipped() throws {
        let pixels = try AndroidScreenCapture.pixels(fromScreencapRaw: Self.warning + Self.raw())
        #expect(pixels.width == 3 && pixels.height == 2)
        #expect(pixels.bytes == Self.letters)
    }

    @Test("RGBX_8888 is accepted, and any other pixel format is refused by its number")
    func pixelFormats() throws {
        #expect(try AndroidScreenCapture.pixels(fromScreencapRaw: Self.raw(format: 2)).bytes == Self.letters)
        #expect(throws: AndroidScreenCapture.ImageFailure(detail: "screencap reported pixel format 4, not RGBA_8888 or RGBX_8888")) {
            try AndroidScreenCapture.pixels(fromScreencapRaw: Self.raw(format: 4))
        }
    }

    @Test("output whose pixel bytes do not fill a header's size is unreadable, quoting its start")
    func truncated() {
        let error = #expect(throws: AndroidScreenCapture.ImageFailure.self) {
            try AndroidScreenCapture.pixels(fromScreencapRaw: Self.raw().dropLast(5))
        }
        #expect(error?.detail.hasPrefix("screencap's raw output has no header Offsider can read (35 bytes") == true)
        #expect(throws: AndroidScreenCapture.ImageFailure.self) { try AndroidScreenCapture.pixels(fromScreencapRaw: Data("Error: display off\n".utf8)) }
    }

    @Test("a PNG after warning text is found and cut from it; output without one is nil")
    func pngAfterWarning() {
        let png = Data(AndroidScreenCapture.pngSignature + [1, 2, 3])
        #expect(AndroidScreenCapture.png(fromScreencap: png) == png)
        #expect(AndroidScreenCapture.png(fromScreencap: Self.warning + png) == png)
        #expect(AndroidScreenCapture.png(fromScreencap: Data("Error: display off\n".utf8)) == nil)
    }
}

@Suite("Android capture policy")
@MainActor
struct AndroidCapturePolicyTests {
    static let device = HelperRig.device

    static func policy(_ value: String?) throws -> AndroidCapturePolicy {
        try AndroidCapturePolicy.policy(host: AndroidTestHost.make(environment: value.map { ["OFFSIDER_ANDROID_CAPTURE": $0] } ?? [:]))
    }

    /// The rig's device answers `screencap` raw and `screencap -p` with these outputs.
    static func rig(_ capture: String?, raw: Data = ScreencapRawTests.raw(), png: Data? = nil, device: FakeHelperDevice = FakeHelperDevice()) throws -> HelperRig {
        let rig = try HelperRig(device, environment: capture.map { ["OFFSIDER_ANDROID_CAPTURE": $0] } ?? [:])
        let pngOutput = try png ?? AndroidScreenCapture.encodePNG(AndroidScreenCapture.Pixels(width: 1, height: 1, bytes: Data([9, 9, 9, 255])))
        rig.device.other = { service in
            switch service {
            case "exec:screencap": return FakeAdbServer.exec(raw)
            case "exec:screencap -p": return FakeAdbServer.exec(pngOutput)
            default: return FakeAdbServer.shell()
            }
        }
        return rig
    }

    static func execs(_ rig: HelperRig) -> [String] {
        rig.server.services.filter { $0.hasPrefix("exec:") }
    }

    @Test("OFFSIDER_ANDROID_CAPTURE is auto when unset or empty, reads its four values in any case, and refuses others")
    func parsing() throws {
        #expect(try Self.policy(nil) == .auto)
        #expect(try Self.policy("") == .auto)
        #expect(try Self.policy("ScreenCap") == .screencap)
        #expect(try Self.policy("RAW") == .raw)
        #expect(try Self.policy("helper") == .helper)
        let error = #expect(throws: AndroidError.self) { try Self.policy("grpc") }
        #expect(error?.message == "OFFSIDER_ANDROID_CAPTURE is grpc, which Offsider cannot read. Use auto, screencap, raw or helper, or unset it.")
    }

    @Test("auto keeps the device's own PNG from `screencap -p`")
    func autoUsesScreencapPNG() async throws {
        let png = Data(AndroidScreenCapture.pngSignature + [7])
        let rig = try Self.rig(nil, png: png)
        #expect(try await rig.backend.screenshotPNG(for: Self.device) == png)
        #expect(Self.execs(rig) == ["exec:screencap -p"])
        await rig.backend.close()
    }

    @Test("raw reads screencap's pixels after a multi-display warning and encodes the PNG on the Mac")
    func raw() async throws {
        let rig = try Self.rig("raw", raw: ScreencapRawTests.warning + ScreencapRawTests.raw())
        let png = try await rig.backend.screenshotPNG(for: Self.device)

        let decoded = try AndroidScreenCaptureTests.labels(ofPNG: png)
        #expect(decoded.width == 3 && decoded.height == 2)
        #expect(decoded.labels == AndroidScreenCaptureTests.letters)
        #expect(Self.execs(rig) == ["exec:screencap"])
        await rig.backend.close()
    }

    @Test("raw output Offsider cannot read falls back to `screencap -p`")
    func rawFallsBack() async throws {
        let png = Data(AndroidScreenCapture.pngSignature + [7])
        let rig = try Self.rig("raw", raw: Data("Error: no display\n".utf8), png: png)

        #expect(try await rig.backend.screenshotPNG(for: Self.device) == png)
        #expect(Self.execs(rig) == ["exec:screencap", "exec:screencap -p"])
        await rig.backend.close()
    }

    @Test("helper takes the screenshot through the helper's raw frame, with no screencap")
    func helper() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "screenshot" ? FakeHelperDevice.screenshot(width: 4, height: 3) : nil }
        let rig = try Self.rig("helper", device: device)
        let png = try await rig.backend.screenshotPNG(for: Self.device)
        await rig.backend.close()

        let decoded = try AndroidScreenCaptureTests.labels(ofPNG: png)
        #expect(decoded.width == 4 && decoded.height == 3)
        #expect(decoded.labels == (0..<12).map { UInt8($0) })
        #expect(rig.device.ops == ["hello", "screenshot", "quit"])
        #expect(rig.device.frames.first { $0.op == "screenshot" }?.json.contains(#""format":"raw""#) == true)
        #expect(Self.execs(rig).isEmpty)
    }

    @Test("a helper that refuses the screenshot warns and falls back to `screencap -p`")
    func helperRefusalFallsBack() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in
            op == "screenshot" ? .error(code: "frame-too-large", message: "the screenshot needs 40000000 bytes, more than the 33554432 byte frame limit") : nil
        }
        let png = Data(AndroidScreenCapture.pngSignature + [7])
        let rig = try Self.rig("helper", png: png, device: device)

        #expect(try await rig.backend.screenshotPNG(for: Self.device) == png)
        #expect(rig.log.warnings == [
            "The UiAutomation helper could not take a screenshot on emulator-5556 (frame-too-large: the screenshot needs 40000000 bytes, more than the 33554432 byte frame limit), so Offsider used `screencap -p`.",
        ])
        #expect(Self.execs(rig) == ["exec:screencap -p"])
        await rig.backend.close()
    }

    @Test("a helper frame that disagrees with its header is a protocol error, not an image")
    func mismatchedFrame() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in
            op == "screenshot" ? .okWithPayload(#"{"frame":{"width":2,"height":2,"format":"rgba8888","bytes":16},"captureMs":1,"copyMs":0,"encodeMs":0}"#, Data(count: 12)) : nil
        }
        let session = try await HelperSessionTests.start(device)

        await #expect(throws: HelperProtocolError.self) { try await session.screenshot() }
        await session.close()
    }
}
