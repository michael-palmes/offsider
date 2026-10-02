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

    @Test("assert sees a parked sheet as gone, and wait sees it arrive and leave", arguments: RNPlatform.enabled)
    func assertAndWaitOnParkedSheet(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        let present = try await app.offsider("assert --id parked-sheet-test-apply")
        #expect(present.exitCode == 5)
        switch platform {
        case .ios:
            #expect(present.stderr.contains("off screen"), "iOS keeps the parked sheet in the tree: \(present.stderr)")
        case .android:
            #expect(present.stderr.contains("not found"), "Android's helper omits invisible nodes: \(present.stderr)")
        }
        let gone = try await app.offsider("assert --id parked-sheet-test-apply --gone")
        #expect(gone.exitCode == 0, "\(gone.stderr)")

        try await app.run("tap --id parked-sheet-test-open-slow")
        let arrived = try await app.offsider("wait --id parked-sheet-test-apply --timeout 6")
        #expect(arrived.exitCode == 0, "\(arrived.stderr)")

        _ = try await app.waitForLabel(of: "parked-sheet-test-position") { $0 == "Sheet Position: Open" }
        try await app.run("tap --id parked-sheet-test-close")
        let left = try await app.offsider("wait --id parked-sheet-test-apply --gone")
        #expect(left.exitCode == 0, "\(left.stderr)")
        _ = try await app.waitForLabel(of: "parked-sheet-test-position") { $0 == "Sheet Position: Parked" }
        if platform == .ios {
            #expect(try await app.label(of: "parked-sheet-test-apply") == "Apply Filters", "iOS keeps the closed sheet mounted off screen")
        }
    }

    struct BatchLine: Decodable {
        let step: Int?
        let kind: String
        let ok: Bool
        let exitCode: Int32?
        let steps: Int?
        let failed: Int?
    }

    static func batchLines(_ stdout: String) throws -> [BatchLine] {
        try stdout.split(separator: "\n").map { try JSONDecoder().decode(BatchLine.self, from: Data($0.utf8)) }
    }

    @Test("one batch --json runs a whole sheet case as NDJSON", arguments: RNPlatform.enabled)
    func batchJSONCase(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-rn-batch-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: shot) }

        // assert reads once, so a wait covers the render after the tap (about 300 ms on Android).
        let steps = [
            "tap --id parked-sheet-test-open",
            "wait --id parked-sheet-test-apply",
            "wait --settled",
            "tap --id parked-sheet-test-apply",
            "wait --label 'Parked Sheet State: Filters applied'",
            "assert --label 'Parked Sheet State: Filters applied'",
            "screenshot --output \(shot.path) --scale points",
            "describe-ui --summary",
        ]
        let result = try await app.offsider("batch --json " + steps.map { "--step \(AndroidE2E.quote($0))" }.joined(separator: " "))

        #expect(result.exitCode == 0, "\(result.stderr)")
        let lines = try Self.batchLines(result.stdout)
        #expect(lines.map { $0.step } == Array(1...steps.count).map(Optional.some) + [nil])
        #expect(lines.dropLast().allSatisfy { $0.ok })
        let summary = try #require(lines.last)
        #expect(summary.kind == "batch")
        #expect(summary.ok)
        #expect(summary.steps == steps.count)
        #expect(summary.failed == 0)
        #expect(FileManager.default.fileExists(atPath: shot.path))
    }

    @Test("a failing assert in a batch exits 5 with its NDJSON line marked", arguments: RNPlatform.enabled)
    func batchFailingAssert(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        let result = try await app.offsider("batch --json --step \"assert --label 'Parked Sheet State: Nope'\" --step 'describe-ui --summary'")

        #expect(result.exitCode == 5, "\(result.stderr)")
        let lines = try Self.batchLines(result.stdout)
        let failed = try #require(lines.first)
        #expect(failed.kind == "assert")
        #expect(!failed.ok)
        #expect(failed.exitCode == 5)
        let summary = try #require(lines.last)
        #expect(lines.count == 2, "the failure stops the batch before describe-ui")
        #expect(!summary.ok)
        #expect(summary.steps == 2)
        #expect(summary.failed == 1)
    }
}
