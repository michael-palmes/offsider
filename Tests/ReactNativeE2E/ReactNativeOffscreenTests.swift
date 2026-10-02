import Foundation
import Testing

@Suite("React Native off-screen selectors", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeOffscreenTests {
    static let initialState = "Parked Sheet State: Initial"

    @Test("a label shared with a parked sheet taps the on-screen copy", arguments: RNPlatform.enabled)
    func labelPrefersOnScreenCopy(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        try await app.run("tap --label Save")

        _ = try await app.waitForLabel(of: "parked-sheet-test-state") { $0 == "Parked Sheet State: Body save" }
    }

    @Test("an id on a parked sheet fails without tapping", arguments: RNPlatform.enabled)
    func parkedIdFails(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        let result = try await app.offsider("tap --id parked-sheet-test-apply")

        #expect(result.exitCode != 0)
        switch platform {
        case .ios:
            #expect(result.stderr.contains("off screen"), "iOS keeps the parked sheet in the tree, so the selector names its off-screen frame: \(result.stderr)")
        case .android:
            #expect(result.stderr.contains("No accessibility element matched"), "Android's helper omits invisible nodes, so the parked sheet is not found: \(result.stderr)")
        }
        #expect(try await app.label(of: "parked-sheet-test-state") == Self.initialState)
    }

    @Test("--allow-offscreen resolves a parked element on iOS without changing state", arguments: RNPlatform.enabled)
    func allowOffscreenEscapeHatch(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        let result = try await app.offsider("tap --id parked-sheet-test-apply --allow-offscreen")

        switch platform {
        case .ios:
            #expect(result.exitCode == 0, "iOS resolves the parked frame and taps outside the screen: \(result.stderr)")
        case .android:
            #expect(result.exitCode != 0)
            #expect(result.stderr.contains("No accessibility element matched"), "Android has no node to allow: \(result.stderr)")
        }
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "parked-sheet-test-state") == Self.initialState)
    }

    @Test("a batch waits for a sliding sheet before tapping inside it", arguments: RNPlatform.enabled)
    func batchWaitsForSheet(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        try await app.run("batch --wait-timeout 8 --step 'tap --id parked-sheet-test-open-slow' --step 'tap --id parked-sheet-test-apply'")

        _ = try await app.waitForLabel(of: "parked-sheet-test-state") { $0 == "Parked Sheet State: Filters applied" }
    }

    @Test("describe-ui --on-screen drops the parked sheet", arguments: RNPlatform.enabled)
    func onScreenFilterDropsParkedSheet(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        let onScreen = try await app.run("describe-ui --flat --on-screen --format ndjson").stdout
        let full = try await app.run("describe-ui").stdout

        #expect(onScreen.contains("parked-sheet-test-body-save"))
        #expect(!onScreen.contains("parked-sheet-test-apply"))
        switch platform {
        case .ios:
            #expect(full.contains("parked-sheet-test-apply"), "iOS reports the parked sheet with its off-screen frame")
        case .android:
            #expect(!full.contains("parked-sheet-test-apply"), "Android's helper omits invisible nodes from every view")
        }
    }

    @Test("a stack page fully off screen leaves one match; one 30% off screen leaves two", arguments: RNPlatform.enabled)
    func stackPreviousPage(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("stack-test")
        try await app.run("tap --id stack-test-next")
        _ = try await app.waitForLabel(of: "stack-test-depth") { $0 == "Stack Depth: 2" }

        // Known limit: a covered duplicate still counts as on screen, so it needs a unique id.
        let partly = try await app.offsider("tap --id stack-test-mark")
        #expect(partly.exitCode != 0)
        #expect(partly.stderr.contains("Multiple (2) accessibility elements matched --id 'stack-test-mark' on screen"), "\(partly.stderr)")
        #expect(try await app.label(of: "stack-test-state") == "Stack State: Initial")

        try await app.run("tap --id stack-test-offset")
        _ = try await app.waitForLabel(of: "stack-test-offset") { $0 == "Previous Offset: 100%" }

        try await app.run("tap --id stack-test-mark")
        _ = try await app.waitForLabel(of: "stack-test-state") { $0 == "Stack State: Page 2 marked" }
    }
}
