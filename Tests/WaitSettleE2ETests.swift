import Foundation
import Testing

/// `wait --settled` on the playground's chart, whose groups never stop moving.
@Suite("wait --settled on a moving chart", .serialized, .enabled(if: isE2EEnabled))
struct WaitSettleE2ETests {
    @Test("the chart keeps --settled from settling until the printed flag leaves it out, pixels included")
    func flagSettlesTheChart() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "live-chart")

        let stuck = try await TestHelpers.runOffsiderCommandAllowFailure("wait --settled --ignore-values --timeout 4", simulatorUDID: defaultSimulatorUDID)
        #expect(stuck.exitCode == 5, "\(stuck.output)")
        #expect(stuck.output.contains("add --ignore-id live-chart to leave it out."), "\(stuck.output)")

        try await TestHelpers.runOffsiderCommand("wait --settled --ignore-values --ignore-id live-chart --timeout 10", simulatorUDID: defaultSimulatorUDID)
        try await TestHelpers.runOffsiderCommand("wait --settled --settle-by both --ignore-id live-chart --timeout 15", simulatorUDID: defaultSimulatorUDID)
    }
}
