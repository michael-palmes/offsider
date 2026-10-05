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
}
