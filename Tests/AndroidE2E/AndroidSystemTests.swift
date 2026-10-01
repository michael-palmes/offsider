import Foundation
import ImageIO
import Testing

@Suite("Android boot", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidBootTests {
    @Test("boot of the running E2E AVD prints its serial and starts nothing")
    func alreadyRunning() async throws {
        let serial = try await AndroidE2E.serial()
        let before = try await CommandRunner.runSeparated("pgrep -f '[q]emu-system.*-avd \(AndroidE2E.expectedAVD)' | wc -l")
        let result = try await TestHelpers.runOffsiderCommandSeparated("boot \(AndroidE2E.expectedAVD)")
        let after = try await CommandRunner.runSeparated("pgrep -f '[q]emu-system.*-avd \(AndroidE2E.expectedAVD)' | wc -l")

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == serial)
        #expect(result.stderr.contains("is already running as \(serial)"))
        #expect(before.stdout == after.stdout)
    }

    @Test("a cold boot of the E2E AVD prints its serial once Android and gRPC are up", .enabled(if: isAndroidBootE2EEnabled))
    func coldBoot() async throws {
        let serial = try await AndroidE2E.serial()
        try await AndroidE2E.adb("emu kill")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let running = try await CommandRunner.runSeparated("pgrep -f '[q]emu-system.*-avd \(AndroidE2E.expectedAVD)'")
            if running.exitCode != 0 { break }
            try await Task.sleep(for: .seconds(1))
        }
        try await Task.sleep(for: .seconds(3))

        let result = try await TestHelpers.runOffsiderCommandSeparated("boot \(AndroidE2E.expectedAVD)", timeout: 600)

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == serial)
        #expect(result.stderr.contains("Starting \(AndroidE2E.expectedAVD)..."))
    }
}

@Suite("Android landscape", .serialized, .enabled(if: isAndroidLandscapeE2EEnabled))
struct AndroidLandscapeTests {
    private func rotate(to rotation: Int) async throws {
        try await AndroidE2E.shell("am start -W -f 0x10008000 -a android.settings.SETTINGS")
        try await AndroidE2E.shell("settings put system accelerometer_rotation 0")
        try await AndroidE2E.shell("settings put system user_rotation \(rotation)")
        try await Task.sleep(for: .seconds(2))
    }

    /// Retried, because the system can put auto-rotate back to off while Settings is still turning.
    private func restorePortrait() async throws {
        var value = ""
        for _ in 0..<5 {
            try await AndroidE2E.shell("settings put system user_rotation 0")
            try await AndroidE2E.shell("settings put system accelerometer_rotation 1")
            try await Task.sleep(for: .seconds(1))
            value = try await AndroidE2E.shell("settings get system accelerometer_rotation").trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "1" { break }
        }
        #expect(value == "1")
    }

    @Test("in both landscape rotations describe-ui, tap and screenshot follow the guest", arguments: [(1, "landscape"), (3, "landscapeFlipped")])
    func landscape(rotation: Int, orientation: String) async throws {
        try await rotate(to: rotation)
        do {
            let tree = try await AndroidE2E.tree()
            let screen = try #require(tree["screen"] as? [String: Any])
            #expect(["landscape", "landscapeFlipped"].contains(screen["orientation"] as? String ?? ""), "rotation \(rotation) expected about \(orientation)")
            #expect((screen["width"] as? Double ?? 0) > (screen["height"] as? Double ?? 0))

            _ = try await AndroidE2E.waitForNode(timeout: 40) { $0["label"] as? String == "Network & internet" }
            try await AndroidE2E.run("tap --label 'Network & internet' --wait-timeout 10")
            _ = try await AndroidE2E.waitForNode { $0["label"] as? String == "Internet" || $0["label"] as? String == "SIMs" }

            let output = AndroidE2E.temporaryFile("landscape.png")
            defer { try? FileManager.default.removeItem(at: output) }
            try await AndroidE2E.run("screenshot --output \(AndroidE2E.quote(output.path))")
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > (properties[kCGImagePropertyPixelHeight] as? Int ?? 0))
        } catch {
            try await restorePortrait()
            throw error
        }
        try await restorePortrait()
    }
}
