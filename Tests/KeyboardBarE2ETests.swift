import CoreGraphics
import Foundation
import OffsiderCore
import Testing

/// The keyboard's suggestion bar on a simulator, on the playground's Keyboard Bar screens; the typed text is invented, and iOS echoes it in the bar's first cell.
@Suite("iOS keyboard bar on a simulator", .serialized, .enabled(if: isE2EEnabled))
struct KeyboardBarE2ETests {
    static let typed = "Zqx"

    static func tree() async throws -> [String: Any] {
        let result = try await TestHelpers.runOffsiderCommandSeparated("describe-ui", simulatorUDID: defaultSimulatorUDID)
        return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    static func nodes(_ node: [String: Any]) -> [[String: Any]] {
        [node] + ((node["children"] as? [[String: Any]]) ?? []).flatMap(nodes)
    }

    static func keyboardShown(_ tree: [String: Any]) -> Bool {
        (tree["context"] as? [String: Any])?["keyboard"] as? Bool == true
    }

    /// Reads until the keyboard is up or gone, for 5 s by the clock, however long a read takes.
    static func treeOnceKeyboard(is shown: Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        var latest = try await tree()
        while keyboardShown(latest) != shown, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            latest = try await tree()
        }
        return latest
    }

    /// Opens `screen`, puts focus in `field` and waits for the keys.
    static func focus(_ field: String, on screen: String) async throws {
        try await TestHelpers.launchPlaygroundApp(to: screen)
        try await TestHelpers.runOffsiderCommand("tap --id \(field)", simulatorUDID: defaultSimulatorUDID)
        #expect(keyboardShown(try await treeOnceKeyboard(is: true)), "the keyboard never came up")
    }

    static func screenshot() async throws -> (report: [String: Any], image: CGImage) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-keyboard-bar-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await TestHelpers.runOffsiderCommandSeparated("screenshot --json --output \(path)", simulatorUDID: defaultSimulatorUDID)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        return (report, try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    static func bar(in tree: [String: Any]) throws -> (node: [String: Any], frame: CGRect) {
        let roots = try #require(tree["roots"] as? [[String: Any]])
        let bar = try #require(roots.flatMap(nodes).first { ($0["id"] as? String)?.hasPrefix("SystemInputAssistant") == true }, "the tree lists no suggestion bar")
        let frame = try #require(bar["frame"] as? [String: Double])
        return (bar, CGRect(x: frame["x"] ?? 0, y: frame["y"] ?? 0, width: frame["width"] ?? 0, height: frame["height"] ?? 0))
    }

    @Test("with suggestions showing, the tree names none of them and the screenshot paints the bar, not the keys")
    func barIsMasked() async throws {
        try await Self.focus("keyboard-suggest-field", on: "keyboard-bar")
        try await TestHelpers.runOffsiderCommand("type \(Self.typed)", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let tree = try await Self.tree()
        let bar = try Self.bar(in: tree)
        let texts = Self.nodes(bar.node).flatMap { [$0["label"] as? String, $0["value"] as? String] }.compactMap { $0 }.filter { !$0.isEmpty }
        #expect(!texts.isEmpty, "the bar listed no text at all, so nothing was there to hide")
        #expect(texts.allSatisfy { $0 == "[redacted]" }, "\(texts)")
        let roots = try #require(tree["roots"] as? [[String: Any]])
        let holders = roots.flatMap(Self.nodes).filter { ($0["label"] as? String)?.contains(Self.typed) == true || ($0["value"] as? String)?.contains(Self.typed) == true }
        #expect(holders.map { $0["id"] as? String } == ["keyboard-suggest-field"], "only the field itself may hold what was typed")

        // A point read answers with one cell and no parents.
        for x in [bar.frame.minX + 30, bar.frame.midX, bar.frame.maxX - 30] {
            let point = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --point \(Int(x)),\(Int(bar.frame.midY))", simulatorUDID: defaultSimulatorUDID)
            #expect(!point.stdout.contains(Self.typed), "a point read in the bar named what was typed: \(point.stdout)")
        }

        let shot = try await Self.screenshot()
        #expect((shot.report["maskedBy"] as? [String: Int])?["keyboard"] == 1)
        #expect(shot.report["maskUnproven"] == nil)
        let scale = try #require(shot.report["pixelsPerPoint"] as? Double)
        let pixel = { (x: Double, y: Double) in ScreenshotMaskTests.pixel(shot.image, Int(x * scale), Int(y * scale)) }
        #expect(pixel(bar.frame.minX + 8, bar.frame.midY) == [0, 0, 0])
        #expect(pixel(bar.frame.midX, bar.frame.midY) == [0, 0, 0])
        #expect(pixel(bar.frame.maxX - 8, bar.frame.maxY - 2) == [0, 0, 0])
        #expect(pixel(bar.frame.midX, bar.frame.maxY + 40) != [0, 0, 0], "the keys below the bar stay visible")
    }

    @Test("video refuses to start while the bar shows")
    func videoRefuses() async throws {
        try await Self.focus("keyboard-suggest-field", on: "keyboard-bar")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-keyboard-bar-\(UUID().uuidString).mp4").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try await TestHelpers.runOffsiderCommandSeparated("record-video --duration 1 --output \(path)", simulatorUDID: defaultSimulatorUDID)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("keyboard shows suggestions"), "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a keyboard with no suggestion bar paints nothing and warns of nothing")
    func noBarNoBand() async throws {
        try await Self.focus("keyboard-plain-field", on: "keyboard-bar")

        let shot = try await Self.screenshot()

        #expect((shot.report["maskedBy"] as? [String: Int])?["keyboard"] == nil)
        #expect(shot.report["maskUnproven"] == nil)
    }

    @Test("keyboard hide sends nothing where the keyboard has no way out, and --tap-outside closes it")
    func hideByTappingOutside() async throws {
        try await Self.focus("keyboard-suggest-field", on: "keyboard-bar")

        let refused = try await TestHelpers.runOffsiderCommandSeparated("keyboard hide --json", simulatorUDID: defaultSimulatorUDID)
        #expect(refused.exitCode == 1)
        #expect(refused.stdout.contains(#""reason":"state_not_reached""#) && refused.stdout.contains(#""dispatched":"no""#), "\(refused.stdout)")
        #expect(Self.keyboardShown(try await Self.tree()))

        let hidden = try await TestHelpers.runOffsiderCommandSeparated("keyboard hide --tap-outside --json", simulatorUDID: defaultSimulatorUDID)
        #expect(hidden.exitCode == 0, "\(hidden.stdout) \(hidden.stderr)")
        #expect(hidden.stdout.contains(#""value":"hidden""#), "\(hidden.stdout)")
        #expect(!Self.keyboardShown(try await Self.treeOnceKeyboard(is: false)))
    }

    @Test("keyboard hide presses an app's Done bar above the suggestions, then reports absent")
    func hideByDoneBar() async throws {
        try await Self.focus("keyboard-suggest-field", on: "keyboard-toolbar")

        let hidden = try await TestHelpers.runOffsiderCommandSeparated("keyboard hide --json", simulatorUDID: defaultSimulatorUDID)
        #expect(hidden.exitCode == 0, "\(hidden.stdout) \(hidden.stderr)")
        #expect(hidden.stdout.contains(#""value":"hidden""#), "\(hidden.stdout)")
        #expect(!Self.keyboardShown(try await Self.treeOnceKeyboard(is: false)))

        let absent = try await TestHelpers.runOffsiderCommandSeparated("keyboard hide --json", simulatorUDID: defaultSimulatorUDID)
        #expect(absent.exitCode == 0)
        #expect(absent.stdout.contains(#""value":"absent""#) && absent.stdout.contains(#""dispatched":"no""#), "\(absent.stdout)")
    }
}
