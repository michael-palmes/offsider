import Foundation
import Testing

@Suite("Parked sheet selectors", .serialized, .enabled(if: isE2EEnabled))
struct ParkedSheetTests {
    private static func state() async throws -> String {
        try await TestHelpers.waitForLabel(containing: "Parked Sheet State:", timeout: 5) { _ in true }
    }

    @Test("a label shared with a parked sheet taps the on-screen copy")
    func labelPrefersOnScreenCopy() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "parked-sheet-test")

        try await TestHelpers.runOffsiderCommand("tap --label Save", simulatorUDID: defaultSimulatorUDID)

        _ = try await TestHelpers.waitForLabel(containing: "Parked Sheet State:", timeout: 5) { $0 == "Parked Sheet State: Body save" }
    }

    @Test("an id on a parked sheet fails as off screen without tapping")
    func parkedIdFails() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "parked-sheet-test")

        let result = try await TestHelpers.runOffsiderCommandAllowFailure("tap --id parked-sheet-test-apply", simulatorUDID: defaultSimulatorUDID)

        #expect(result.exitCode != 0)
        #expect(result.output.contains("off screen"), "\(result.output)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await Self.state() == "Parked Sheet State: Initial")
    }

    @Test("--wait-timeout taps the sheet's button once it slides on screen")
    func waitTimeoutTapsSlidingSheet() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "parked-sheet-test")

        try await TestHelpers.runOffsiderCommand("tap --id parked-sheet-test-open-slow", simulatorUDID: defaultSimulatorUDID)
        try await TestHelpers.runOffsiderCommand("tap --id parked-sheet-test-apply --wait-timeout 6", simulatorUDID: defaultSimulatorUDID)

        _ = try await TestHelpers.waitForLabel(containing: "Parked Sheet State:", timeout: 5) { $0 == "Parked Sheet State: Filters applied" }
    }
}
