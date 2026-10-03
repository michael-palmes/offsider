import Foundation
import Testing

@Suite("React Native environment", .serialized, .enabled(if: RNPlatform.anyEnabled))
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

    /// Runs `restore` as a guard, then `body`, then `restore` again even when `body` throws.
    static func restoring<T>(_ app: RNApp, _ restore: String, _ body: () async throws -> T) async throws -> T {
        try await app.run(restore)
        do {
            let result = try await body()
            try await app.run(restore)
            return result
        } catch {
            _ = try? await app.run(restore)
            throw error
        }
    }

    /// The number after the last `: ` in a readout label such as `Font Scale: 1.00`.
    static func number(in label: String?) -> Double? {
        label?.components(separatedBy: ": ").last.flatMap { Double($0) }
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

    @Test("appearance dark reaches the app, reads back and repaints the swatch", arguments: RNPlatform.enabled)
    func appearanceDark(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.restoring(app, "appearance light") {
            try await app.open("environment-test")
            _ = try await app.waitForLabel(of: "environment-test-scheme") { $0 == "Colour Scheme: light" }
            let region = Self.region(of: try await app.frame(of: "environment-test-swatch"))

            try await Self.withTemporaryDirectory { directory in
                let baseline = AndroidE2E.quote(directory.appendingPathComponent("light.png").path)
                try await app.run("screenshot --region \(region) --output \(baseline)")

                let set = try await app.run("appearance dark --json").stdout
                #expect(set.contains("\"appearance\":\"dark\""), "\(set)")
                _ = try await app.waitForLabel(of: "environment-test-scheme") { $0 == "Colour Scheme: dark" }
                let read = try await app.run("appearance --json").stdout
                #expect(read.contains("\"appearance\":\"dark\""), "\(read)")

                let changed = try await app.offsider("screenshot --region \(region) --compare \(baseline)")
                #expect(changed.exitCode == 0, "the dark swatch should differ from the light baseline: \(changed.stderr)")
            }
        }
    }

    @Test("content-size scales the app's fonts and reset returns them to 1.00", arguments: RNPlatform.enabled)
    func contentSizeScalesFonts(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.restoring(app, "content-size reset") {
            try await app.open("environment-test")
            _ = try await app.waitForLabel(of: "environment-test-font-scale") { $0 == "Font Scale: 1.00" }
            try await app.run("tap --id environment-test-log")
            _ = try await app.waitForLabel(of: "environment-test-log-count") { $0 == "Log Count: 1" }

            try await app.run("content-size accessibility-large")
            let scaled = try await app.waitForLabel(of: "environment-test-font-scale", timeout: 30) { (Self.number(in: $0) ?? 0) > 1 }
            #expect((Self.number(in: scaled) ?? 0) > 1, "\(scaled)")

            switch platform {
            case .ios:
                #expect(try await app.label(of: "environment-test-log-count") == "Log Count: 1", "iOS keeps the React tree across a Dynamic Type change")
            case .android:
                #expect(try await app.label(of: "environment-test-log-count") == "Log Count: 0", "Android recreates the activity for a font scale change, so React state resets")
            }

            try await app.run("content-size reset")
            _ = try await app.waitForLabel(of: "environment-test-font-scale", timeout: 30) { $0 == "Font Scale: 1.00" }
        }
    }

    @Test("orientation landscape-left turns the app and selector taps still land", arguments: RNPlatform.enabled)
    func landscapeSelectorTap(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.restoring(app, "orientation portrait --timeout 10") {
            try await app.open("environment-test")

            try await app.run("orientation landscape-left --timeout 10")
            _ = try await app.waitForLabel(of: "environment-test-orientation") { $0 == "Orientation: landscape" }
            let screen = try await app.screenSize()
            #expect(screen.width > screen.height, "describe-ui reports \(screen.width) x \(screen.height)")
            let screenInfo = try await app.tree()["screen"] as? [String: Any]
            #expect(screenInfo?["orientation"] as? String == "landscape", "\(String(describing: screenInfo))")
            #expect(screenInfo?["rotation"] as? Int == 90, "\(String(describing: screenInfo))")

            // The log buttons sit below the fold in landscape; one preset scroll covers less on Android.
            var scrolls = 0
            while try await app.offsider("assert --id environment-test-log").exitCode != 0, scrolls < 5 {
                try await app.run("gesture scroll-up")
                scrolls += 1
            }
            let before = try await app.label(of: "environment-test-log-count")
            let count = Int(Self.number(in: before) ?? -1)
            try await app.run("tap --id environment-test-log")
            _ = try await app.waitForLabel(of: "environment-test-log-count") { $0 == "Log Count: \(count + 1)" }

            try await app.run("orientation portrait --timeout 10")
            _ = try await app.waitForLabel(of: "environment-test-orientation") { $0 == "Orientation: portrait" }
        }
    }

    struct Logs: Decodable {
        struct Entry: Decodable {
            let timestamp: String
            let level: String
            let message: String
        }
        let version: Int
        let platform: String
        let entries: [Entry]
    }

    /// RN on iOS logs console.warn at the unified log's Info level; Android logcat keeps W.
    static func expectedLevels(_ platform: RNPlatform) -> [String: String] {
        switch platform {
        case .ios: return ["info": "Info", "warning": "Info", "error": "Error"]
        case .android: return ["info": "Info", "warning": "Warning", "error": "Error"]
        }
    }

    @Test("logs --rn reads the fixture's console output at each level, and --grep filters it", arguments: RNPlatform.enabled)
    func rnLogs(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")
        let start = Date()
        let count = Int(Self.number(in: try await app.label(of: "environment-test-log-count")) ?? -1)
        try #require(count >= 0)

        for id in ["environment-test-log", "environment-test-warn", "environment-test-error"] {
            try await app.run("tap --id \(id)")
        }
        _ = try await app.waitForLabel(of: "environment-test-log-count") { $0 == "Log Count: \(count + 3)" }

        let wanted = ["info": count + 1, "warning": count + 2, "error": count + 3]
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var found: [String: Logs.Entry] = [:]
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let json = try await app.run("logs --rn --last 1m --json").stdout
            let logs = try JSONDecoder().decode(Logs.self, from: Data(json.utf8))
            #expect(logs.version == 1)
            #expect(logs.platform == platform.rawValue)
            for (level, n) in wanted {
                found[level] = logs.entries.last { $0.message == "OffsiderFixture \(level) \(n)" }
            }
            if found.count == wanted.count { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline

        for (level, n) in wanted {
            let entry = try #require(found[level], "no entry for OffsiderFixture \(level) \(n)")
            #expect(entry.level == Self.expectedLevels(platform)[level], "console \(level) logged at \(entry.level)")
            let time = try #require(parser.date(from: entry.timestamp), "\(entry.timestamp)")
            #expect(time > start.addingTimeInterval(-5), "OffsiderFixture \(level) \(n) at \(entry.timestamp) is from an earlier launch")
        }

        let grep = try await app.run("logs --rn --grep 'OffsiderFixture error' --last 1m")
        let lines = grep.stdout.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.contains("OffsiderFixture error \(count + 3)") }, "\(grep.stdout)")
        #expect(lines.allSatisfy { $0.localizedCaseInsensitiveContains("OffsiderFixture error") }, "\(grep.stdout)")
    }

    @Test("wait --region sees a canvas flash, times out on a still or spinning canvas", arguments: RNPlatform.enabled)
    func waitRegion(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")
        let region = Self.region(of: try await app.frame(of: "environment-test-canvas"))

        try await app.run("tap --id environment-test-canvas-flash")
        let changed = try await app.offsider("wait --region \(region) --changed --timeout 5")
        #expect(changed.exitCode == 0, "the flash lands 1 s after the tap: \(changed.stderr)")

        let unchanged = try await app.offsider("wait --region \(region) --changed --timeout 1.5")
        #expect(unchanged.exitCode == 5, "nothing should change without a flash: \(unchanged.stderr)")

        let still = try await app.offsider("wait --region \(region) --stable")
        #expect(still.exitCode == 0, "\(still.stderr)")

        try await app.run("tap --id environment-test-canvas-toggle")
        do {
            _ = try await app.waitForLabel(of: "environment-test-canvas-state") { $0 == "Canvas: Animating" }
            let spinning = try await app.offsider("wait --region \(region) --stable --quiet-ms 800 --timeout 2", timeout: 30)
            #expect(spinning.exitCode == 5, "a spinning canvas should never be stable: \(spinning.stderr)")
        } catch {
            _ = try? await app.run("tap --id environment-test-canvas-toggle", timeout: 30)
            throw error
        }
        try await app.run("tap --id environment-test-canvas-toggle")
        _ = try await app.waitForLabel(of: "environment-test-canvas-state") { $0 == "Canvas: Still" }
    }
}
