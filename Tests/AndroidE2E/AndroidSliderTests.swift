import Foundation
import Testing

@Suite("Android slider", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidSliderTests {
    private let tolerance = 0.0007

    /// The value after the readout's prefix, for example 0.4 from "Slider Exact Value: 0.4000".
    private func number(in label: String?, after prefix: String) -> Double? {
        guard let label, label.hasPrefix(prefix) else { return nil }
        return Double(label.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }

    /// Waits until the app's exact readout and the slider's own percentage both show `percent`.
    private func expectSliderReached(_ percent: Double) async throws {
        let expected = percent / 100
        var exact: String?
        var value: String?
        let reached = try await AndroidE2E.eventually(timeout: 20) {
            let nodes = AndroidE2E.nodes(in: try await AndroidE2E.tree())
            exact = nodes.first { $0["id"] as? String == "slider-exact-value-state" }?["label"] as? String
            value = nodes.first { $0["id"] as? String == "slider-value-slider" }?["value"] as? String
            guard let readout = number(in: exact, after: "Slider Exact Value:"),
                  let position = value.flatMap({ Double($0.replacingOccurrences(of: "%", with: "")) }) else {
                return false
            }
            return abs(readout - expected) <= tolerance && abs(position / 100 - expected) <= tolerance
        }
        #expect(reached, "wanted \(percent)%; readout \(exact ?? "none"), slider value \(value ?? "none")")
    }

    @Test("--id sets the React Native slider to the requested value", arguments: [0.0, 0.1, 1.5, 40.0, 75.0, 78.25, 100.0])
    func byID(percent: Double) async throws {
        try await AndroidE2E.open("slider-value-test", waitingFor: "slider-value-slider")
        let result = try await AndroidE2E.run("slider --id slider-value-slider --element-type slider --value \(percent)")
        #expect(result.stdout.contains("Slider set to"), "stdout: \(result.stdout)")
        try await expectSliderReached(percent)
    }

    @Test("--label sets the slider")
    func byLabel() async throws {
        try await AndroidE2E.open("slider-value-test", waitingFor: "slider-value-slider")
        try await AndroidE2E.run("slider --label 'Slider Value Slider' --value 40")
        try await expectSliderReached(40)
    }

    @Test("--wait-timeout waits for a slider that is not on screen yet")
    func waitsForSlider() async throws {
        try await AndroidE2E.launch("slider-value-test")
        try await AndroidE2E.run("slider --id slider-value-slider --value 60 --wait-timeout 30")
        try await expectSliderReached(60)
    }

    @Test("a button target fails as not a slider and leaves the slider alone")
    func buttonIsNotASlider() async throws {
        try await AndroidE2E.open("slider-value-test", waitingFor: "slider-value-slider")
        let result = try await AndroidE2E.offsider("slider --id slider-value-button --value 50")
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("not a slider"), "stderr: \(result.stderr)")
        #expect(try await AndroidE2E.label(of: "slider-exact-value-state") == "Slider Exact Value: 0.2500")
    }
}
