import Foundation
import Testing

let isFoldableE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_FOLDABLE_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

/// The iPhone Duo simulator (SIMULATOR_UDID), folded and unfolded with `offsider posture`; the suite ends unfolded.
@Suite("Foldable iPhone", .serialized, .enabled(if: isFoldableE2EEnabled))
struct FoldableTests {
    struct Display: Decodable {
        let id: String
        let platformId: String
        let width: Double
        let height: Double
        let rotation: Int?
        let active: Bool
    }

    struct Displays: Decodable {
        let displays: [Display]
        let posture: String?
    }

    struct PostureReport: Decodable {
        let posture: String
        let display: String?
    }

    struct DisplayRef: Decodable {
        let id: String
        let platformId: String
    }

    struct Capture: Decodable {
        let width: Int
        let height: Int
        let pixelsPerPoint: Double
        let orientation: String
        let rotation: Int?
        let display: DisplayRef?
        let posture: String?
        let upright: Bool
    }

    struct Screen: Decodable {
        let width: Double
        let height: Double
        let orientation: String
        let rotation: Int?
        let display: DisplayRef?
        let posture: String?
    }

    struct Tree: Decodable {
        let screen: Screen
    }

    static func udid() throws -> String {
        guard let udid = defaultSimulatorUDID, !udid.isEmpty else {
            throw TestError.commandError("SIMULATOR_UDID must name the Offsider Duo iPhone for the foldable suite.")
        }
        return udid
    }

    @discardableResult
    static func offsider(_ arguments: String) async throws -> String {
        let result = try await TestHelpers.runOffsiderCommandSeparated(arguments, simulatorUDID: try udid(), timeout: 120)
        guard result.exitCode == 0 else {
            throw TestError.unexpectedState("offsider \(arguments) exited \(result.exitCode): \(result.stderr)")
        }
        return result.stdout
    }

    static func decode<T: Decodable>(_ type: T.Type, _ arguments: String) async throws -> T {
        try JSONDecoder().decode(type, from: Data(try await offsider(arguments).utf8))
    }

    static func posture() async throws -> String {
        try await decode(PostureReport.self, "posture --json").posture
    }

    /// Folds or unfolds the Duo with `offsider posture` unless it already reports `wanted`.
    static func requirePosture(_ wanted: String) async throws {
        let displays = try await decode(Displays.self, "displays --json")
        try #require(Set(displays.displays.map(\.id)) == ["cover", "inner"], "SIMULATOR_UDID is not a foldable: \(displays.displays.map(\.id))")
        if displays.posture == wanted { return }
        let report = try await decode(PostureReport.self, "posture \(wanted) --json")
        try #require(report.posture == wanted, "posture \(wanted) reported \(report.posture)")
    }

    static func screenshot(_ options: String = "") async throws -> Capture {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-foldable-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        return try await decode(Capture.self, "screenshot --json \(options) --output \(output.path)")
    }

    /// A coordinate tap lands at that point (the screen's centre unless given), then a selector tap on BackButton leaves the screen.
    static func expectTapsLand(on screen: Screen, at point: (x: Int, y: Int)? = nil) async throws {
        let udid = try udid()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test", simulatorUDID: udid)
        let x = point?.x ?? Int(screen.width / 2)
        let y = point?.y ?? Int(screen.height * 0.6)
        try await offsider("tap -x \(x) -y \(y)")
        let location = try await TestHelpers.waitForLabel(containing: "Tap Location:", timeout: 10, simulatorUDID: udid) { _ in true }
        let landed = try #require(CoordinateParser.parseCoordinates(from: location), "\(location)")
        #expect(abs(landed.x - x) <= 1 && abs(landed.y - y) <= 1, "tapped (\(x), \(y)), the app saw \(location)")

        try await offsider("tap --id BackButton")
        _ = try await TestHelpers.waitForLabel(containing: "Touch & Gestures", timeout: 10, simulatorUDID: udid) { _ in true }
    }

    // MARK: Folded (cover display)

    @Test("folded: displays lists the cover as active and the inner display as inactive")
    func foldedDisplays() async throws {
        try await Self.requirePosture("closed")
        let list = try await Self.decode(Displays.self, "displays --json")
        #expect(list.posture == "closed")
        let cover = try #require(list.displays.first { $0.id == "cover" })
        let inner = try #require(list.displays.first { $0.id == "inner" })
        #expect(cover.active && !inner.active)
        #expect(cover.width == 466 && cover.height == 678, "cover \(cover.width) x \(cover.height)")
        #expect(cover.rotation == 0)
        #expect(inner.width == 669 && inner.height == 951, "inner \(inner.width) x \(inner.height)")
        #expect(inner.rotation == nil)
    }

    @Test("folded: screenshot captures the cover display, in pixels and in points")
    func foldedScreenshot() async throws {
        try await Self.requirePosture("closed")
        let pixels = try await Self.screenshot()
        #expect(pixels.width == 1398 && pixels.height == 2034, "\(pixels.width) x \(pixels.height)")
        #expect(pixels.display?.id == "cover")
        #expect(pixels.posture == "closed")
        #expect(pixels.orientation == "portrait")
        #expect(pixels.upright)

        let points = try await Self.screenshot("--scale points")
        #expect(points.width == 466 && points.height == 678, "\(points.width) x \(points.height)")
        #expect(points.pixelsPerPoint == 1)
    }

    @Test("folded: describe-ui reports the cover screen, and --display inner names the inactive display")
    func foldedDescribeUI() async throws {
        try await Self.requirePosture("closed")
        let screen = try await Self.decode(Tree.self, "describe-ui").screen
        #expect(screen.display?.id == "cover")
        #expect(screen.posture == "closed")
        #expect(screen.rotation == 0)
        #expect(screen.orientation == "portrait")
        #expect(screen.width == 466 && screen.height == 678, "\(screen.width) x \(screen.height)")

        let inner = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --display inner", simulatorUDID: try Self.udid())
        #expect(inner.exitCode != 0)
        #expect(inner.stderr.contains("describe-ui reads the active display only, and inner is not active (posture closed). Unfold the simulator with `offsider posture open --device \(try Self.udid())`, then retry."), "\(inner.stderr)")

        let cover = try await Self.decode(Tree.self, "describe-ui --display cover").screen
        #expect(cover.display?.id == "cover")
    }

    @Test("folded: posture reads closed; half-opened unfolds to the inner display at 120 degrees and closed folds it again")
    func foldedPosture() async throws {
        try await Self.requirePosture("closed")
        let read = try await Self.decode(PostureReport.self, "posture --json")
        #expect(read.posture == "closed" && read.display == "cover")

        let half = try await Self.decode(PostureReport.self, "posture half-opened --json")
        #expect(half.posture == "half-opened" && half.display == "inner")
        #expect(try await Self.posture() == "half-opened")

        let closed = try await Self.decode(PostureReport.self, "posture closed --json")
        #expect(closed.posture == "closed" && closed.display == "cover")
    }

    @Test("folded: coordinate and selector taps land on the cover display")
    func foldedTaps() async throws {
        try await Self.requirePosture("closed")
        try await Self.expectTapsLand(on: try await Self.decode(Tree.self, "describe-ui").screen)
    }

    // MARK: Unfolded (inner display)

    @Test("unfolded: the inner display is a 951 x 669 pt landscape screen, captured upright, described and tapped where asked")
    func unfolded() async throws {
        try await Self.requirePosture("open")
        let screen = try await Self.decode(Tree.self, "describe-ui").screen
        #expect(screen.display?.id == "inner")
        #expect(screen.posture == "open")
        #expect(screen.width == 951 && screen.height == 669, "\(screen.width) x \(screen.height)")
        #expect(screen.orientation == "landscape")
        #expect(screen.rotation == 270)

        let list = try await Self.decode(Displays.self, "displays --json")
        let inner = try #require(list.displays.first { $0.id == "inner" })
        #expect(inner.active && inner.width == 951 && inner.height == 669 && inner.rotation == 270)
        #expect(try await Self.offsider("orientation").hasPrefix("Orientation: portrait (951 x 669 pt)"))

        let points = try await Self.screenshot("--scale points")
        #expect(points.display?.id == "inner")
        #expect(points.width == 951 && points.height == 669, "capture \(points.width) x \(points.height)")
        #expect(points.orientation == "landscape" && points.rotation == 270)
        #expect(points.upright)

        let cover = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --display cover", simulatorUDID: try Self.udid())
        #expect(cover.exitCode != 0)
        #expect(cover.stderr.contains("cover is not active (posture open). Fold the simulator with `offsider posture closed"), "\(cover.stderr)")

        try await Self.expectTapsLand(on: screen, at: (x: 300, y: 500))
    }
}
