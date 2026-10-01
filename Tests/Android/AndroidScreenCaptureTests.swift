import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android screen capture")
@MainActor
struct AndroidScreenCaptureTests {
    /// A 3 x 2 image whose pixels are A B C over D E F, each opaque with red = its letter.
    nonisolated static let letters: [UInt8] = Array("ABCDEF".utf8)
    nonisolated static func rgba(_ labels: [UInt8]) -> Data {
        Data(labels.flatMap { [$0, 0, 0, 255] })
    }
    nonisolated static let sample = EmulatorFrame(format: .rgba8888, width: 3, height: 2, emulatorRotation: 0, sequence: 1, bytes: rgba(letters))

    nonisolated static func labels(ofPNG data: Data) throws -> (width: Int, height: Int, labels: [UInt8]) {
        let pixels = try AndroidScreenCapture.rgba(from: try AndroidScreenCapture.decodePNG(data))
        return (pixels.width, pixels.height, stride(from: 0, to: pixels.bytes.count, by: 4).map { pixels.bytes[$0] })
    }

    @Test("a PNG frame that needs no turn passes through byte for byte")
    func pngPassThrough() throws {
        let png = try AndroidScreenCapture.encodePNG(try AndroidScreenCapture.rgba(from: Self.sample))
        let frame = EmulatorFrame(format: .png, width: 3, height: 2, emulatorRotation: 3, sequence: 1, bytes: png)
        #expect(try AndroidScreenCapture.png(from: frame, guestRotation: 3) == png)
    }

    @Test("guest rotation 1 with the emulator upright turns the frame a quarter counterclockwise")
    func rgbaTurnedCounterclockwise() throws {
        let result = try Self.labels(ofPNG: AndroidScreenCapture.png(from: Self.sample, guestRotation: 1))
        #expect(result.width == 2 && result.height == 3)
        #expect(result.labels == Array("CFBEAD".utf8))
    }

    @Test("guest rotation 3 turns it clockwise, and a PNG input is decoded and turned too")
    func pngTurnedClockwise() throws {
        let png = try AndroidScreenCapture.encodePNG(try AndroidScreenCapture.rgba(from: Self.sample))
        let frame = EmulatorFrame(format: .png, width: 3, height: 2, emulatorRotation: 0, sequence: 1, bytes: png)
        let result = try Self.labels(ofPNG: AndroidScreenCapture.png(from: frame, guestRotation: 3))
        #expect(result.width == 2 && result.height == 3)
        #expect(result.labels == Array("DAEBFC".utf8))
    }

    @Test("BGRA swaps red and blue and keeps green and alpha")
    func bgraSwap() throws {
        let frame = EmulatorFrame(format: .rgba8888, width: 1, height: 1, emulatorRotation: 0, sequence: 1, bytes: Data([10, 20, 30, 255]))
        #expect(try AndroidScreenCapture.bgra(from: frame, guestRotation: 0).bytes == Data([30, 20, 10, 255]))
    }

    static func rig(frames: [EmulatorFrame], geometry: String = AndroidBackendTests.geometryOutput, environment: [String: String] = [:]) throws -> AndroidGrpcInputTests.Rig {
        try AndroidGrpcInputTests.rig(geometry: geometry, emulator: FakeEmulator(frames: frames), environment: environment)
    }

    @Test("screenshots come from gRPC, turned for a landscape guest, without adb's screencap")
    func screenshotOverGrpc() async throws {
        let rig = try Self.rig(frames: [Self.sample], geometry: AndroidGrpcInputTests.landscape)
        let png = try await rig.backend.screenshotPNG(for: AndroidGrpcInputTests.device)

        #expect(try Self.labels(ofPNG: png).labels == Array("CFBEAD".utf8))
        #expect(rig.emulator.calls == [.screenshot(.png, nil)])
        #expect(!rig.server.services.contains { $0.hasPrefix("exec:") })
    }

    @Test("with gRPC forced off, screenshots fall back to adb's screencap")
    func screenshotOverAdb() async throws {
        let rig = try Self.rig(frames: [Self.sample], environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb"])
        await #expect(throws: AndroidError.self) { try await rig.backend.screenshotPNG(for: AndroidGrpcInputTests.device) }
        #expect(rig.server.services.contains("exec:screencap -p"))
        #expect(rig.emulator.calls.isEmpty)
    }

    @Test("captured frames are upright RGBA the emulator scaled to a square box on the long side")
    func frameCapture() async throws {
        let rig = try Self.rig(frames: [Self.sample], geometry: AndroidGrpcInputTests.landscape)
        let image = try await rig.backend.captureFrame(for: AndroidGrpcInputTests.device, scale: 0.5)

        #expect(image.width == 2 && image.height == 3)
        #expect(rig.emulator.calls == [.screenshot(.rgba8888, FrameBox(width: 1212, height: 1212))])
    }

    @Test("streamed BGRA frames go to the file descriptor, at most fps a second")
    func streamBGRA() async throws {
        let rig = try Self.rig(frames: [Self.sample, Self.sample, Self.sample])
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer { close(descriptors[0]) }

        try await rig.backend.streamBGRA(from: AndroidGrpcInputTests.device, fps: 1, quality: 80, scale: 1, to: descriptors[1], isCancelled: { false })
        close(descriptors[1])
        let written = FileHandle(fileDescriptor: descriptors[0]).readDataToEndOfFile()

        #expect(written == Data(Self.letters.flatMap { [0, 0, $0, 255] }))
        #expect(rig.emulator.calls == [.stream(.rgba8888, nil)])
    }

    @Test("BGRA streaming over adb fails with the gRPC message")
    func streamBGRAOverAdb() async throws {
        let rig = try Self.rig(frames: [Self.sample], environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb"])
        let error = await #expect(throws: AndroidError.self) {
            try await rig.backend.streamBGRA(from: AndroidGrpcInputTests.device, fps: 10, quality: 80, scale: 1, to: -1, isCancelled: { false })
        }
        #expect(error?.message == "Streaming BGRA frames on Android needs the emulator's gRPC endpoint, and OFFSIDER_ANDROID_TRANSPORT is adb. Unset it, or use --format mjpeg.")
    }
}
