import Foundation
import Testing

@Suite("React Native gestures", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeGestureTests {
    private static func holdTwoFingers(_ app: RNApp, environment: [String: String]? = nil) async throws {
        try await app.open("multi-touch")
        let centre = try await app.centre(of: "multi-touch-area")
        let arguments = "touch -x \(centre.x) -y \(centre.y) --fingers 2 --hold 1000"
        if let environment, app.platform == .android {
            try await AndroidE2E.run(arguments, environment: environment)
        } else {
            try await app.run(arguments)
        }
        _ = try await app.waitForLabel(of: "multi-touch-fingers") { $0 == "Fingers: 2" }
        let held = try await app.waitForLabel(of: "multi-touch-held-ms") { $0 != "Held: 0 ms" }
        let ms = Int(held.dropFirst("Held: ".count).prefix { $0.isNumber }) ?? 0
        #expect(ms >= 900, "\(held)")
    }

    @Test("two fingers go down together and stay down for the hold", arguments: RNPlatform.enabled)
    func twoFingers(platform: RNPlatform) async throws {
        try await Self.holdTwoFingers(RNApp(platform))
    }

    @Test("over adb, two fingers go through the UiAutomation helper", .enabled(if: isAndroidE2EEnabled))
    func twoFingersThroughHelper() async throws {
        try await Self.holdTwoFingers(RNApp(.android), environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb", "OFFSIDER_ANDROID_INPUT": "helper"])
    }

    private static func drag(_ app: RNApp, _ options: String) async throws -> String {
        try await app.open("hold-drag")
        let tile = try await app.centre(of: "hold-drag-tile")
        let zone = try await app.centre(of: "hold-drag-zone-b")
        try await app.run("drag --start-x \(tile.x) --start-y \(tile.y) --end-x \(zone.x) --end-y \(zone.y) \(options)")
        try await Task.sleep(for: .milliseconds(500))
        return try await app.label(of: "hold-drag-zone") ?? ""
    }

    @Test("drag --hold-ms 800 picks the tile up and drops it in zone B; a plain drag does not", arguments: RNPlatform.enabled)
    func holdThenDrag(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        #expect(try await Self.drag(app, "") == "Zone: A")
        #expect(try await Self.drag(app, "--hold-ms 800") == "Zone: B")
    }

    @Test("gesture long-press-drag drops the tile in zone B", arguments: RNPlatform.enabled)
    func longPressDragPreset(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("hold-drag")
        let tile = try await app.centre(of: "hold-drag-tile")
        let zone = try await app.centre(of: "hold-drag-zone-b")
        try await app.run("gesture long-press-drag --x \(tile.x) --y \(tile.y) --to-x \(zone.x) --to-y \(zone.y)")
        _ = try await app.waitForLabel(of: "hold-drag-zone") { $0 == "Zone: B" }
    }
}
