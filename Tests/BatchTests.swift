import CoreGraphics
import Foundation
import OffsiderCore
import Testing

@Suite("Batch Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct BatchTests {
    @Test("Batch executes ordered tap steps")
    func orderedTapSteps() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        try await TestHelpers.runOffsiderCommand(
            "batch --step \"tap -x 180 -y 360\" --step \"tap -x 220 -y 420\"",
            simulatorUDID: defaultSimulatorUDID
        )

        _ = try await waitForLabel(containing: "Tap Count:", timeout: 3) {
            (extractInt(from: $0) ?? 0) >= 2
        }

        let uiState = try await TestHelpers.getUIState()
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        #expect(tapLocationElement?.label == "Tap Location: (220, 420)")
    }

    @Test("A tap during a batch on the same simulator exits 8 and names the batch")
    func tapDuringBatchIsRefused() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let batch = Process()
        batch.executableURL = URL(fileURLWithPath: try TestHelpers.getOffsiderPath())
        batch.arguments = ["batch", "--device", udid, "--step", "sleep 4"]
        batch.environment = TestHelpers.childEnvironment()
        batch.standardOutput = FileHandle.nullDevice
        batch.standardError = FileHandle.nullDevice
        try batch.run()
        defer { batch.terminate() }

        let lockPath = (OffsiderPrivateDirectory.root as NSString).appendingPathComponent("locks/ios-\(udid.uppercased()).lock")
        let deadline = Date().addingTimeInterval(30)
        while (try? String(contentsOfFile: lockPath, encoding: .utf8))?.contains("pid=\(batch.processIdentifier)\n") != true {
            try #require(Date() < deadline && batch.isRunning, "batch never took the lock")
            try await Task.sleep(for: .milliseconds(50))
        }

        let result = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1", simulatorUDID: udid, unsetting: ["OFFSIDER_WAIT_LOCK"])
        #expect(result.exitCode == 8)
        #expect(result.stderr.contains("pid \(batch.processIdentifier) (offsider batch"))
    }

    @Test("Batch reads steps from file")
    func fileInputSource() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("batch-file-steps-\(UUID().uuidString).txt")
        let steps = [
            "tap -x 180 -y 360",
            "sleep 0.2",
            "tap -x 220 -y 420"
        ].joined(separator: "\n")
        try steps.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try await TestHelpers.runOffsiderCommand(
            "batch --file \"\(tempFile.path)\"",
            simulatorUDID: defaultSimulatorUDID
        )

        _ = try await waitForLabel(containing: "Tap Count:", timeout: 3) {
            (extractInt(from: $0) ?? 0) >= 2
        }
    }

    @Test("Batch reads steps from stdin")
    func stdinInputSource() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        let udid = try TestHelpers.requireSimulatorUDID()
        let offsiderPath = try TestHelpers.getOffsiderPath()

        let command = "printf 'tap -x 160 -y 350\\ntap -x 200 -y 410\\n' | \"\(offsiderPath)\" batch --stdin --device \"\(udid)\""
        let result = try await CommandRunner.run(command)
        #expect(result.exitCode == 0)

        _ = try await waitForLabel(containing: "Tap Count:", timeout: 3) {
            (extractInt(from: $0) ?? 0) >= 2
        }
    }

    @Test("Batch landscape coordinates preserve translated tap and swipe points", .enabled(if: isLandscapeE2EEnabled))
    func landscapeCoordinatesPreserveTranslatedTapAndSwipePoints() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "landscape-coordinate-test")
        do {
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            try await TestHelpers.setSimulatorOrientationLandscapeRight()

            let initialState = try await TestHelpers.waitForLandscapeCoordinateFixtureLayout(timeout: 6)

            guard let tapTarget = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Target"),
                  let tapFrame = tapTarget.frame,
                  let swipeStart = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Swipe Start"),
                  let swipeStartFrame = swipeStart.frame,
                  let swipeEnd = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Swipe End"),
                  let swipeEndFrame = swipeEnd.frame else {
                throw TestError.elementNotFound("landscape-coordinate-batch-targets")
            }

            let tapX = Int(tapFrame.x + tapFrame.width / 2)
            let tapY = Int(tapFrame.y + tapFrame.height / 2)
            let startX = Int(swipeStartFrame.x + swipeStartFrame.width / 2)
            let startY = Int(swipeStartFrame.y + swipeStartFrame.height / 2)
            let endX = Int(swipeEndFrame.x + swipeEndFrame.width / 2)
            let endY = Int(swipeEndFrame.y + swipeEndFrame.height / 2)

            try await TestHelpers.runOffsiderCommand(
                "batch --step \"tap -x \(tapX) -y \(tapY)\" --step \"swipe --start-x \(startX) --start-y \(startY) --end-x \(endX) --end-y \(endY) --duration 0.3 --delta 10\"",
                simulatorUDID: defaultSimulatorUDID
            )

            _ = try await waitForLabel(containing: "Landscape Hit Count:", timeout: 3) { $0 == "Landscape Hit Count: 1" }
            _ = try await waitForLabel(containing: "Landscape Swipe Hit Count:", timeout: 3) { $0 == "Landscape Swipe Hit Count: 1" }
            try await assertLastNamedCoordinate(containing: "Last Tap Hit:", expectedX: tapX, expectedY: tapY, timeout: 3)
            try await assertLastNamedCoordinate(containing: "Last Swipe Start:", expectedX: startX, expectedY: startY, timeout: 3)
            try await assertLastNamedCoordinate(containing: "Last Swipe End:", expectedX: endX, expectedY: endY, timeout: 3)
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
        } catch {
            try? await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            throw error
        }
    }

    @Test("Batch continue-on-error runs later steps and reports failures")
    func continueOnError() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        let result = try await TestHelpers.runOffsiderCommandAllowFailure(
            "batch --continue-on-error --wait-timeout 2 --poll-interval 0.1 --ax-cache perStep --step \"unknown-command\" --step \"tap --label 'Trigger State Change'\" --step \"tap --label 'State Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Batch completed with 1 failure(s):"))
        #expect(result.output.contains("unknown-command"))

        let currentState = try await waitForBatchState(expected: "State target tapped", timeout: 3)
        #expect(currentState == "State target tapped")
    }

    @Test("Batch with perBatch cache refreshes after a step that sends input")
    func perBatchCacheRefreshesAfterInput() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        try await TestHelpers.runOffsiderCommand(
            "batch --ax-cache perBatch --step \"tap --label 'Trigger State Change'\" --step \"tap --label 'State Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentState = try await waitForBatchState(expected: "State target tapped", timeout: 3)
        #expect(currentState == "State target tapped")
    }

    @Test("Batch with perStep cache handles state change")
    func perStepCacheHandlesStateChange() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        try await TestHelpers.runOffsiderCommand(
            "batch --ax-cache perStep --step \"tap --label 'Trigger State Change'\" --step \"tap --label 'State Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentState = try await waitForBatchState(expected: "State target tapped", timeout: 3)
        #expect(currentState == "State target tapped")
    }

    @Test("Batch wait-timeout can wait for delayed element")
    func waitTimeoutFindsDelayedElement() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        try await TestHelpers.runOffsiderCommand(
            "batch --wait-timeout 5 --poll-interval 0.1 --step \"tap --label 'Trigger Delayed Element'\" --step \"tap --label 'Delayed Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentState = try await waitForBatchState(expected: "Delayed target tapped", timeout: 6)
        #expect(currentState == "Delayed target tapped")
    }

    @Test("Batch without wait-timeout fails when delayed element is missing")
    func noWaitTimeoutFailsForDelayedElement() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        let result = try await TestHelpers.runOffsiderCommandAllowFailure(
            "batch --wait-timeout 0 --step \"tap --label 'Trigger Delayed Element'\" --step \"tap --label 'Delayed Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Step 2 failed:"))
    }

    @Test("Batch drives realistic login flow with loading transition")
    func loginFlowWithLoadingTransition() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-login-flow")

        try await TestHelpers.runOffsiderCommand(
            "batch --ax-cache perStep --wait-timeout 6 --poll-interval 0.1 --step \"type 'cam@example.com'\" --step \"tap --label Continue\" --step \"type 'supersecret'\" --step \"tap --label 'Sign In'\" --step \"tap --label 'Open Settings'\" --step \"tap --label 'Toggle Preference'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentScreen = try await waitForLabel(containing: "Current Screen:", timeout: 2) {
            $0 == "Current Screen: Settings"
        }
        #expect(currentScreen == "Current Screen: Settings")

        let uiState = try await TestHelpers.getUIState()
        let settingsOpened = UIStateParser.findElementContainingLabel(in: uiState, containing: "Settings Opened")
        #expect(settingsOpened != nil)
    }

    @Test("Batch selector taps toggle SwiftUI and UIKit switches")
    func selectorTapsToggleSwitches() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "switch-test")

        try await TestHelpers.runOffsiderCommand(
            "batch --ax-cache perStep --step \"tap --label 'SwiftUI Weather Alerts'\" --step \"tap --label 'UIKit Weather Alerts'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let swiftUIState = try await waitForLabel(containing: "SwiftUI Weather Alerts:", timeout: 3) {
            $0 == "SwiftUI Weather Alerts: On"
        }
        let uiKitState = try await waitForLabel(containing: "UIKit Weather Alerts:", timeout: 3) {
            $0 == "UIKit Weather Alerts: On"
        }
        #expect(swiftUIState == "SwiftUI Weather Alerts: On")
        #expect(uiKitState == "UIKit Weather Alerts: On")
    }

    @Test("Batch tap step automatic overrides simulator batch tap style for switches")
    func tapStepAutomaticOverridesSimulatorBatchStyleForSwitches() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "switch-test")

        try await TestHelpers.runOffsiderCommand(
            "batch --tap-style simulator --step \"tap --label 'SwiftUI Weather Alerts' --tap-style automatic\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let swiftUIState = try await waitForLabel(containing: "SwiftUI Weather Alerts:", timeout: 3) {
            $0 == "SwiftUI Weather Alerts: On"
        }
        #expect(swiftUIState == "SwiftUI Weather Alerts: On")
    }

    @Test("a typed password reads as bullets in describe-ui, and screenshot --mask-secure blacks out the field")
    func securePasswordMasked() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-login-flow")
        let sentinel = "S3NT1NEL"
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-mask-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: shot) }

        let result = try await TestHelpers.runOffsiderCommand(
            "batch --json --ax-cache perStep --wait-timeout 6 --step \"type 'cam@example.com'\" --step \"tap --label Continue\" --step \"wait --label 'Sign In' --timeout 5\" --step \"type \(sentinel)\" --step \"describe-ui --format json\" --step \"screenshot --output \(shot.path) --mask-secure\"",
            simulatorUDID: defaultSimulatorUDID
        )
        #expect(!result.output.contains(sentinel))

        let records = result.output.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        let typeLine = records.first { ($0["line"] as? String)?.contains("8 characters") == true }
        #expect(typeLine != nil)

        func find(_ node: Any?) -> [String: Any]? {
            guard let node = node as? [String: Any] else { return nil }
            if node["role"] as? String == "secureTextField" { return node }
            for child in (node["children"] as? [Any] ?? []) + (node["roots"] as? [Any] ?? []) {
                if let found = find(child) { return found }
            }
            return nil
        }
        let field = try #require(find(records.first { $0["kind"] as? String == "describe-ui" }?["tree"]))
        let value = try #require(field["value"] as? String)
        #expect(!value.isEmpty && value.allSatisfy { $0 == "•" })

        let screenshot = try #require(records.first { $0["kind"] as? String == "screenshot" })
        #expect(screenshot["masked"] as? Int == 1)
        let frame = try #require(field["frame"] as? [String: Double])
        let scale = try #require(screenshot["pixelsPerPoint"] as? Double)
        let image = try ScreenImage.decode(try Data(contentsOf: shot))
        let centre = (x: Int((frame["x"]! + frame["width"]! / 2) * scale), y: Int((frame["y"]! + frame["height"]! / 2) * scale))
        #expect(Self.rgb(image, centre.x, centre.y) == [0, 0, 0])
    }

    private static func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return Array(bytes.prefix(3))
    }

    @Test("Batch login flow fails without waiting for post-sign-in screen")
    func loginFlowFailsWithoutWait() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-login-flow")

        let result = try await TestHelpers.runOffsiderCommandAllowFailure(
            "batch --ax-cache perStep --wait-timeout 0 --step \"type 'cam@example.com'\" --step \"tap --label Continue\" --step \"type 'supersecret'\" --step \"tap --label 'Sign In'\" --step \"tap --label 'Open Settings'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Step 5 failed:"))
    }

    @Test("Batch enforces one input source")
    func oneSourceValidation() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("batch-steps-\(UUID().uuidString).txt")
        try "tap -x 100 -y 200\n".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        await #expect(throws: (any Error).self) {
            try await TestHelpers.runOffsiderCommand(
                "batch --step \"tap -x 100 -y 200\" --file \"\(tempFile.path)\"",
                simulatorUDID: defaultSimulatorUDID
            )
        }
    }

    private func waitForBatchState(expected: String, timeout: TimeInterval) async throws -> String {
        let label = try await waitForLabel(containing: "Current State:", timeout: timeout) {
            $0 == "Current State: \(expected)"
        }
        return label.replacingOccurrences(of: "Current State: ", with: "")
    }

    private func waitForLabel(
        containing text: String,
        timeout: TimeInterval,
        satisfies predicate: (String) -> Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let element = UIStateParser.findElementContainingLabel(in: uiState, containing: text),
               let label = element.label {
                lastValue = label
                if predicate(label) {
                    return label
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for label containing '\(text)'. Last value: \(lastValue ?? "none")")
    }

    private func extractInt(from label: String) -> Int? {
        let digits = label.filter { $0.isNumber }
        return Int(digits)
    }

    private func assertLastNamedCoordinate(
        containing text: String,
        expectedX: Int,
        expectedY: Int,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let label = UIStateParser.findElementContainingLabel(in: uiState, containing: text)?.label {
                lastValue = label
                if let point = CoordinateParser.parseNamedCoordinates(from: label),
                   abs(point.x - expectedX) <= 1,
                   abs(point.y - expectedY) <= 1 {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for \(text) near x:\(expectedX),y:\(expectedY). Last value: \(lastValue ?? "none")"
        )
    }
}
