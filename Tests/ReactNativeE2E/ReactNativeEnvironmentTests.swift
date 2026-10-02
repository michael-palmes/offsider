import Foundation
import Testing

@Suite("React Native screenshots", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeEnvironmentTests {
    struct Capture: Decodable {
        let width: Int
        let height: Int
        let pixelsPerPoint: Double
    }

    static func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-rn-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    static func region(of frame: (x: Double, y: Double, width: Double, height: Double)) -> String {
        [frame.x, frame.y, frame.width, frame.height].map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    @Test("a points screenshot is one pixel per point of the describe-ui screen", arguments: RNPlatform.enabled)
    func pointsScreenshotMatchesScreen(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")
        let screen = try await app.screenSize()

        let capture = try await Self.withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("screen.png").path
            let json = try await app.run("screenshot --scale points --json --output \(AndroidE2E.quote(output))").stdout
            #expect(FileManager.default.fileExists(atPath: output))
            return try JSONDecoder().decode(Capture.self, from: Data(json.utf8))
        }

        #expect(capture.width == Int(screen.width.rounded()))
        #expect(capture.height == Int(screen.height.rounded()))
        #expect(capture.pixelsPerPoint == 1)
    }

    @Test("a region around the swatch is the swatch's size in points", arguments: RNPlatform.enabled)
    func regionMatchesFrame(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")
        let swatch = try await app.frame(of: "environment-test-swatch")

        let capture = try await Self.withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("swatch.png").path
            let json = try await app.run("screenshot --scale points --json --region \(Self.region(of: swatch)) --output \(AndroidE2E.quote(output))").stdout
            return try JSONDecoder().decode(Capture.self, from: Data(json.utf8))
        }

        #expect(abs(Double(capture.width) - swatch.width) <= 1, "image \(capture.width) wide for a \(swatch.width) frame")
        #expect(abs(Double(capture.height) - swatch.height) <= 1, "image \(capture.height) high for a \(swatch.height) frame")
    }

    @Test("--compare sees a canvas flash that leaves the tree unchanged", arguments: RNPlatform.enabled)
    func compareSeesPixelOnlyChange(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")
        let region = Self.region(of: try await app.frame(of: "environment-test-canvas"))
        let canvasState = try await app.label(of: "environment-test-canvas-state")
        #expect(canvasState == "Canvas: Still")

        try await Self.withTemporaryDirectory { directory in
            let baseline = AndroidE2E.quote(directory.appendingPathComponent("baseline.png").path)
            try await app.run("screenshot --region \(region) --output \(baseline)")

            let unchanged = try await app.offsider("screenshot --region \(region) --compare \(baseline)")
            #expect(unchanged.exitCode == 5, "a fresh capture of a still canvas should be unchanged: \(unchanged.stderr)")

            try await app.run("tap --id environment-test-canvas-flash")
            try await Task.sleep(for: .milliseconds(1_500))

            let changed = try await app.offsider("screenshot --region \(region) --compare \(baseline)")
            #expect(changed.exitCode == 0, "the flash should change the canvas pixels: \(changed.stderr)")
        }

        #expect(try await app.label(of: "environment-test-canvas-state") == canvasState)
    }
}
