import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("iOS device screenshot and geometry")
@MainActor
struct IOSDeviceScreenTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    static func temporaryRoot() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("offsider-ios-screen-\(UUID().uuidString)").path
    }

    /// Writes `bytes` where `--destination` points, as devicectl does.
    static func writingCapture(_ bytes: Data?) -> @Sendable ([String]) -> Void {
        { arguments in
            guard arguments.starts(with: ["device", "capture", "screenshot"]),
                  let index = arguments.firstIndex(of: "--destination"), let bytes else { return }
            FileManager.default.createFile(atPath: arguments[index + 1], contents: bytes)
        }
    }

    static func devicectl(capture: Data?, displays: ProcessCaptureResult? = nil) throws -> FakeDevicectl {
        var replies = ["list": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-list-xcode26.json"), stderr: "")]
        replies["displays"] = try displays ?? ProcessCaptureResult(status: 0, stdout: IOSDeviceFixtures.text("devicectl-info-displays.json"), stderr: "")
        return FakeDevicectl(replies: replies, effect: writingCapture(capture))
    }

    @Test("a screenshot is devicectl's PNG, captured into the private captures directory and removed after reading")
    func screenshot() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let devicectl = try Self.devicectl(capture: Self.png)
        let lines = LineSink()
        let backend = IOSDeviceBackend(host: .fake(devicectl, privateRoot: root, timing: .printing(to: lines.append))) { _, _ in }

        let data = try await backend.screenshotPNG(for: Self.phone)

        #expect(data == Self.png)
        let capture = try #require(devicectl.calls.first { $0.starts(with: ["device", "capture", "screenshot"]) })
        let captures = "\(root)/ios-devices/\(IOSDeviceFixtures.phone)/captures"
        #expect(capture[3...4] == ["--device", IOSDeviceFixtures.phone])
        #expect(capture.contains("--timeout") && capture.last == "-q")
        let destination = try #require(capture.firstIndex(of: "--destination").map { capture[$0 + 1] })
        #expect(destination.hasPrefix(captures + "/") && destination.hasSuffix(".png"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: captures).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: captures)[.posixPermissions] as? Int == 0o700)
        #expect(lines.values.contains { $0.hasPrefix("offsider timing: capture ") })
    }

    @Test("devicectl writing no image is a command failure that points at doctor")
    func noImage() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let backend = IOSDeviceBackend(host: .fake(try Self.devicectl(capture: nil), privateRoot: root)) { _, _ in }
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await backend.screenshotPNG(for: Self.phone)
        }
        #expect(error?.reason == .commandFailed)
        #expect(error?.hint == "offsider doctor --device \(IOSDeviceFixtures.phone)")
    }

    @Test("the displays reply gives the portrait panel in points and the UI's turn, not the motion orientation")
    func geometryParse() throws {
        let geometry = try IOSDeviceGeometry.parse(try IOSDeviceFixtures.data("devicectl-info-displays.json"))
        #expect(geometry == IOSDeviceGeometry(
            pixelWidth: 1290, pixelHeight: 2796, pointScale: 3, rotationDegrees: 0, points: IOSDevicePoints(width: 430, height: 932), nativeDegrees: 0
        ))
        #expect(geometry.screenInfo == UIScreenInfo(width: 430, height: 932, scale: 3, rotation: .portrait, rotationDegrees: 0))
    }

    @Test("a turned UI swaps the point size", arguments: [("rot90", 270, OrientationCoordinateMath.Orientation.landscape), ("rot270", 90, .landscapeFlipped)])
    func geometryTurned(text: String, degrees: Int, orientation: OrientationCoordinateMath.Orientation) throws {
        let json = try IOSDeviceFixtures.text("devicectl-info-displays.json").replacingOccurrences(of: "\"currentOrientation\": \"rot0\"", with: "\"currentOrientation\": \"\(text)\"")
        let info = try IOSDeviceGeometry.parse(Data(json.utf8)).screenInfo
        #expect(info.width == 932 && info.height == 430)
        #expect(info.rotation == orientation && info.rotationDegrees == degrees)
    }

    static func iPadDisplays(bounds: String) -> Data {
        Data("""
        {"result": {"displays": [{"displayId": 1, "primary": true, \(bounds) "nativeSize": [2752, 2064], "pointScale": 2,
          "currentOrientation": "rot0", "nativeOrientation": "rot270", "type": {"integrated": {}}}]}}
        """.utf8)
    }

    @Test("a landscape-native iPad reports a landscape screen at rotation 0, in its bounds' points, else its nativeSize points")
    func iPadGeometry() throws {
        let zoomed = try IOSDeviceGeometry.parse(Self.iPadDisplays(bounds: #""bounds": [[0, 0], [3200, 2400]],"#))
        #expect(zoomed.screenInfo == UIScreenInfo(width: 1600, height: 1200, scale: 2, rotation: .portrait, rotationDegrees: 0))
        let native = try IOSDeviceGeometry.parse(Self.iPadDisplays(bounds: ""))
        #expect(native.screenInfo == UIScreenInfo(width: 1376, height: 1032, scale: 2, rotation: .portrait, rotationDegrees: 0))
    }

    @Test("a geometry cached before points and native orientation were kept still reads")
    func olderGeometryFile() throws {
        let data = Data(#"{"pixelWidth": 1290, "pixelHeight": 2796, "pointScale": 3, "rotationDegrees": 0}"#.utf8)
        let geometry = try JSONDecoder().decode(IOSDeviceGeometry.self, from: data)
        #expect(geometry.screenInfo.width == 430 && geometry.screenInfo.height == 932)
    }

    @Test("a reply without a display size is refused")
    func geometryRefused() {
        #expect(throws: IOSDeviceGeometry.ParseError.self) {
            _ = try IOSDeviceGeometry.parse(Data(#"{"result": {"displays": [{"displayId": 1}]}}"#.utf8))
        }
    }

    @Test("geometry is read once per command, cached 0600, and the cache serves when devicectl later fails")
    func geometryCache() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let devicectl = try Self.devicectl(capture: nil)
        let backend = IOSDeviceBackend(host: .fake(devicectl, privateRoot: root)) { _, _ in }
        #expect(try await backend.screenInfo(for: Self.phone)?.width == 430)
        #expect(try await backend.screenSize(for: Self.phone) == UISize(width: 430, height: 932))
        #expect(devicectl.calls.filter { $0.starts(with: ["device", "info", "displays", "--device", IOSDeviceFixtures.phone]) }.count == 1)
        let file = "\(root)/ios-devices/\(IOSDeviceFixtures.phone)/geometry.json"
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)

        let failing = try Self.devicectl(capture: nil, displays: ProcessCaptureResult(status: 1, stdout: "", stderr: "ERROR: timed out"))
        let later = IOSDeviceBackend(host: .fake(failing, privateRoot: root)) { _, _ in }
        #expect(try await later.screenInfo(for: Self.phone)?.height == 932)
    }

    @Test("the status bar band is left out of --verify comparisons in every orientation, placed by the display's turn")
    func volatileBands() async throws {
        let backend = IOSDeviceBackend(host: .fake(try Self.devicectl(capture: nil))) { _, _ in }
        #expect(await backend.volatileScreenBands(for: Self.phone) == ScreenBands(top: 62, bottom: 0, everyOrientation: true, screenshotQuarterTurns: 0))
        let unread = IOSDeviceBackend(host: .fake(FakeDevicectl(replies: [:]))) { _, _ in }
        #expect(await unread.volatileScreenBands(for: Self.phone) == ScreenBands(top: 62, bottom: 0))
    }
}

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var values: [String] { lock.withLock { lines } }

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }
}
