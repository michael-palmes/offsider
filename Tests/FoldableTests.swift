import Foundation
import Testing

let isFoldableE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_FOLDABLE_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

/// The iPhone Duo simulator (SIMULATOR_UDID). Only Device Hub folds it, so each half waits for the owner, then skips.
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

    static let ownerTimeout: TimeInterval = 120

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

    /// Returns once the Duo reports `wanted`, asking the owner to fold or unfold it; cancels the test after `ownerTimeout`.
    static func requirePosture(_ wanted: String) async throws {
        let displays = try await decode(Displays.self, "displays --json")
        try #require(Set(displays.displays.map(\.id)) == ["cover", "inner"], "SIMULATOR_UDID is not a foldable: \(displays.displays.map(\.id))")
        if displays.posture == wanted { return }
        let action = wanted == "closed" ? "Fold" : "Unfold"
        print("\(action) the Offsider Duo iPhone in Device Hub now; waiting up to \(Int(ownerTimeout)) s for posture \(wanted).")
        let deadline = Date().addingTimeInterval(ownerTimeout)
        while Date() < deadline {
            if (try? await posture()) == wanted { return }
            try await Task.sleep(for: .seconds(2))
        }
        try Test.cancel("The Duo stayed \(displays.posture ?? "unknown"); nobody can \(action.lowercased()) it from the command line, so this half needs the owner in Device Hub.")
    }

    static func screenshot(_ options: String = "") async throws -> Capture {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-foldable-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        return try await decode(Capture.self, "screenshot --json \(options) --output \(output.path)")
    }

    /// A coordinate tap at the screen's centre lands at that point, then a selector tap on BackButton leaves the screen.
    static func expectTapsLand(on screen: Screen) async throws {
        let udid = try udid()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test", simulatorUDID: udid)
        let x = Int(screen.width / 2)
        let y = Int(screen.height * 0.6)
        try await offsider("tap -x \(x) -y \(y)")
        let location = try await TestHelpers.waitForLabel(containing: "Tap Location:", timeout: 10, simulatorUDID: udid) { _ in true }
        let point = try #require(CoordinateParser.parseCoordinates(from: location), "\(location)")
        #expect(abs(point.x - x) <= 1 && abs(point.y - y) <= 1, "tapped (\(x), \(y)), the app saw \(location)")

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
        #expect(Set([inner.width, inner.height]) == [669, 951], "inner \(inner.width) x \(inner.height)")
    }

    @Test("folded: screenshot captures the cover display, in pixels and in points")
    func foldedScreenshot() async throws {
        try await Self.requirePosture("closed")
        let pixels = try await Self.screenshot()
        #expect(pixels.width == 1398 && pixels.height == 2034, "\(pixels.width) x \(pixels.height)")
        #expect(pixels.display?.id == "cover")
        #expect(pixels.posture == "closed")
        #expect(pixels.orientation == "portrait")

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
        #expect(inner.stderr.contains("describe-ui reads the active display only, and inner is not active (posture closed). Unfold the simulator in Device Hub, then retry."), "\(inner.stderr)")

        let cover = try await Self.decode(Tree.self, "describe-ui --display cover").screen
        #expect(cover.display?.id == "cover")
    }

    @Test("folded: posture reads closed, and setting it on iOS explains that only Device Hub folds the simulator")
    func foldedPosture() async throws {
        try await Self.requirePosture("closed")
        let read = try await Self.decode(PostureReport.self, "posture --json")
        #expect(read.posture == "closed" && read.display == "cover")

        let udid = try Self.udid()
        let set = try await TestHelpers.runOffsiderCommandSeparated("posture open", simulatorUDID: udid)
        #expect(set.exitCode != 0)
        #expect(set.stderr.contains("Setting the posture is not available on iOS simulators: no simulator tool folds the device. Fold or unfold it in Device Hub, then check with `offsider posture --device \(udid)`."), "\(set.stderr)")
    }

    @Test("folded: coordinate and selector taps land on the cover display")
    func foldedTaps() async throws {
        try await Self.requirePosture("closed")
        try await Self.expectTapsLand(on: try await Self.decode(Tree.self, "describe-ui").screen)
    }

    // MARK: Unfolded (inner display)

    @Test("unfolded: the inner display is active, captured, described and tapped")
    func unfolded() async throws {
        try await Self.requirePosture("open")
        let screen = try await Self.decode(Tree.self, "describe-ui").screen
        #expect(screen.display?.id == "inner")
        #expect(screen.posture == "open")
        #expect(Set([screen.width.rounded(), screen.height.rounded()]) == [669, 951], "\(screen.width) x \(screen.height)")
        #expect(screen.orientation == (screen.width > screen.height ? "landscape" : "portrait"))

        let points = try await Self.screenshot("--scale points")
        #expect(points.display?.id == "inner")
        #expect(points.width == Int(screen.width.rounded()) && points.height == Int(screen.height.rounded()), "capture \(points.width) x \(points.height), screen \(screen.width) x \(screen.height)")

        let cover = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --display cover", simulatorUDID: try Self.udid())
        #expect(cover.exitCode != 0)
        #expect(cover.stderr.contains("cover is not active (posture open). Fold the simulator in Device Hub"), "\(cover.stderr)")

        try await Self.expectTapsLand(on: screen)
    }
}
