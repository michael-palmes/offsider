import Foundation
import Testing

/// `wait --settled` on a chart that never stops moving, and on a page whose pixels arrive after the tree lists it.
@Suite("React Native settle", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeSettleTests {
    @Test("a moving chart never settles, the timeout prints the flag that leaves it out, and that flag settles it", arguments: RNPlatform.enabled)
    func movingChart(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("live-chart")

        let stuck = try await app.offsider("wait --settled --ignore-values --timeout 4 --json")

        if platform == .ios {
            withKnownIssue("iOS lists the bars by height, so each place in the tree changes label, and --ignore-values leaves out the frame of a node whose text changed") {
                #expect(stuck.exitCode == 5, "\(stuck.stderr)")
            }
            return
        }
        #expect(stuck.exitCode == 5, "\(stuck.stderr)")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(stuck.stdout.utf8)) as? [String: Any])
        let flag = try #require(report["leaveOut"] as? String)
        #expect(stuck.stderr.contains("add \(flag) to leave it out."), "\(stuck.stderr)")
        try await app.run("wait --settled --ignore-values \(flag) --timeout 10")
    }

    @Test("after a push whose pixels arrive late, the next screenshot shows the finished page", .enabled(if: isAndroidE2EEnabled))
    func lateDraw() async throws {
        let app = RNApp(.android)
        try await app.open("late-draw")
        let baseline = FileManager.default.temporaryDirectory.appendingPathComponent("late-draw-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: baseline) }

        try await app.run("tap --id late-draw-open")
        try await app.run("wait --settled --timeout 15")
        try await app.run("screenshot --output \(baseline)")
        try await Task.sleep(for: .seconds(2))

        let later = try await app.offsider("screenshot --compare \(baseline) --threshold 0.02 --expect unchanged --json")
        #expect(later.exitCode == 0, "the screenshot right after the wait was still drawing: \(later.stdout)")
        try await app.run("tap --id late-draw-back")
    }

    @Test("--settle-by tree reads no pixels", .enabled(if: isAndroidE2EEnabled))
    func treeOnlySkipsTheHold() async throws {
        let app = RNApp(.android)
        try await app.open("late-draw")

        try await app.run("tap --id late-draw-open")
        let treeOnly = try await app.offsider("wait --settled --settle-by tree --timeout 15", environment: ["OFFSIDER_TIMINGS": "1"])

        #expect(treeOnly.exitCode == 0, "\(treeOnly.stderr)")
        #expect(!treeOnly.stderr.contains("timing: capture"), "\(treeOnly.stderr)")
        try await app.run("tap --id late-draw-back")
    }
}
