import Foundation
import Testing

@Suite("Device controls", .serialized, .enabled(if: isE2EEnabled))
struct DeviceControlTests {
    struct Capture: Decodable {
        let width: Int
        let height: Int
        let pixelsPerPoint: Double
    }

    /// Runs `restore` as a guard, then `body`, then `restore` again even when `body` throws.
    private static func restoring(_ restore: String, _ body: () async throws -> Void) async throws {
        try await TestHelpers.runOffsiderCommand(restore, simulatorUDID: defaultSimulatorUDID)
        do {
            try await body()
            try await TestHelpers.runOffsiderCommand(restore, simulatorUDID: defaultSimulatorUDID)
        } catch {
            _ = try? await TestHelpers.runOffsiderCommand(restore, simulatorUDID: defaultSimulatorUDID)
            throw error
        }
    }

    private static func waitForReadout(_ prefix: String, _ expected: String) async throws {
        _ = try await TestHelpers.waitForLabel(containing: prefix, timeout: 10) { $0 == expected }
    }

    @Test("appearance dark then light flips the app's colour scheme")
    func appearance() async throws {
        try await Self.restoring("appearance light") {
            try await TestHelpers.launchPlaygroundApp(to: "environment-test")
            try await Self.waitForReadout("Colour Scheme:", "Colour Scheme: light")

            try await TestHelpers.runOffsiderCommand("appearance dark", simulatorUDID: defaultSimulatorUDID)
            try await Self.waitForReadout("Colour Scheme:", "Colour Scheme: dark")

            try await TestHelpers.runOffsiderCommand("appearance light", simulatorUDID: defaultSimulatorUDID)
            try await Self.waitForReadout("Colour Scheme:", "Colour Scheme: light")
        }
    }

    @Test("content-size accessibility-large then reset flips the app's Dynamic Type size")
    func contentSize() async throws {
        try await Self.restoring("content-size reset") {
            try await TestHelpers.launchPlaygroundApp(to: "environment-test")
            try await Self.waitForReadout("Content Size:", "Content Size: large")

            try await TestHelpers.runOffsiderCommand("content-size accessibility-large", simulatorUDID: defaultSimulatorUDID)
            try await Self.waitForReadout("Content Size:", "Content Size: accessibility-large")

            try await TestHelpers.runOffsiderCommand("content-size reset", simulatorUDID: defaultSimulatorUDID)
            try await Self.waitForReadout("Content Size:", "Content Size: large")
        }
    }

    @Test("orientation landscape-right turns the app, reads back, and a points screenshot matches the turned screen")
    func orientation() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.restoring("orientation portrait --timeout 10") {
            try await TestHelpers.launchPlaygroundApp(to: "environment-test")
            try await Self.waitForReadout("Interface Orientation:", "Interface Orientation: portrait")

            try await TestHelpers.runOffsiderCommand("orientation landscape-right --timeout 10", simulatorUDID: udid)
            try await Self.waitForReadout("Interface Orientation:", "Interface Orientation: landscape-right")
            let read = try await TestHelpers.runOffsiderCommandSeparated("orientation", simulatorUDID: udid)
            #expect(read.stdout.contains("landscape-right"), "\(read.stdout)")

            let tree = try DescribeUITree.parse(try await TestHelpers.runOffsiderCommandSeparated("describe-ui", simulatorUDID: udid).stdout)
            let screen = try #require(DescribeUITree.screenSize(in: tree))
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-landscape-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: output) }
            let json = try await TestHelpers.runOffsiderCommandSeparated("screenshot --scale points --json --output \(output.path)", simulatorUDID: udid)
            let capture = try JSONDecoder().decode(Capture.self, from: Data(json.stdout.utf8))
            #expect(capture.width > capture.height, "\(capture.width) x \(capture.height)")
            #expect(capture.width == Int(screen.width.rounded()))
            #expect(capture.height == Int(screen.height.rounded()))
            #expect(capture.pixelsPerPoint == 1)

            try await TestHelpers.runOffsiderCommand("orientation portrait --timeout 10", simulatorUDID: udid)
            try await Self.waitForReadout("Interface Orientation:", "Interface Orientation: portrait")
        }
    }

    @Test("shake reaches the app as a motion-shake event")
    func shake() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "button-test")
        // The screen's outer accessibilityIdentifier replaces button-test-shake, so match the label.
        try await Self.waitForReadout("Shake:", "Shake: None")

        try await TestHelpers.runOffsiderCommand("shake", simulatorUDID: defaultSimulatorUDID)

        try await Self.waitForReadout("Shake:", "Shake: Detected")
    }
}
