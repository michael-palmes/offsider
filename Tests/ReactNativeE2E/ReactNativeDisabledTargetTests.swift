import Foundation
import Testing

/// A React Native `Pressable` while it is disabled: the tree says so on both platforms, and a selector tap refuses it.
@Suite("React Native disabled targets", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeDisabledTargetTests {
    @Test("a control still disabled is refused with nothing sent, --allow-disabled proves it does nothing, and --wait-timeout taps it once enabled", arguments: RNPlatform.enabled)
    func disabledControl(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("batch-test")
        try await app.run("tap --id batch-disable-trigger")

        let refused = try await app.offsider("tap --id batch-enable-target --json")
        #expect(refused.exitCode == 1, "\(refused.stderr)")
        #expect(refused.stdout.contains(#""reason":"target_disabled""#), "\(refused.stdout)")
        try await app.run("tap --id batch-enable-target --allow-disabled")
        try await app.run("assert --label 'Current State: Enable target disabled'")

        try await app.run("tap --id batch-enable-target --wait-timeout 10")
        try await app.run("wait --label 'Current State: Enable target tapped' --timeout 5")
    }
}
