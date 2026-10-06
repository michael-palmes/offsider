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

    @Test("boot --json on the running E2E AVD reports it already running, unlocked, with its RAM and process stamp")
    func alreadyRunningJSON() async throws {
        let serial = try await AndroidE2E.serial()
        let result = try await TestHelpers.runOffsiderCommandSeparated("boot \(AndroidE2E.expectedAVD) --memory 4096 --json")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "stdout: \(result.stdout)")

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(report["ok"] as? Bool == true)
        #expect(report["avd"] as? String == AndroidE2E.expectedAVD)
        #expect(report["serial"] as? String == serial)
        #expect(report["alreadyRunning"] as? Bool == true)
        #expect((report["ignored"] as? [String])?.contains { $0.contains("--memory") } == true, "\(report["ignored"] ?? "")")
        #expect((report["memoryMB"] as? Int ?? 0) > 1024)
        let bootedBy = try #require(report["bootedBy"] as? [String: Any])
        #expect((bootedBy["pid"] as? Int ?? 0) > 0)
        #expect((bootedBy["startedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
        let lock = try #require(report["lock"] as? [String: Any])
        #expect(lock["type"] as? String == "none")
        #expect(lock["userUnlocked"] as? Bool == true)
    }

    @Test("a listener flag passed through --emulator-arg is refused before anything launches")
    func refusesListenerFlag() async throws {
        let count = "pgrep -f '[q]emu-system.*-avd \(AndroidE2E.expectedAVD)' | wc -l"
        let before = try await CommandRunner.runSeparated(count)
        let result = try await TestHelpers.runOffsiderCommandSeparated("boot \(AndroidE2E.expectedAVD) --emulator-arg -grpc")
        let after = try await CommandRunner.runSeparated(count)

        #expect(result.exitCode == 64, "stderr: \(result.stderr)")
        #expect(result.stderr.contains("-grpc"))
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

        let ramMB = try Self.configuredRAM()
        let result = try await TestHelpers.runOffsiderCommandSeparated("boot \(AndroidE2E.expectedAVD) --memory \(ramMB) --no-snapshot-load --json", timeout: 600)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "stdout: \(result.stdout)")

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(report["serial"] as? String == serial)
        #expect(report["alreadyRunning"] as? Bool == false)
        #expect(result.stderr.contains("Starting \(AndroidE2E.expectedAVD)..."))
        let memoryMB = try #require(report["memoryMB"] as? Int)
        #expect(abs(Double(memoryMB - ramMB)) <= 0.1 * Double(ramMB), "memoryMB \(memoryMB) for --memory \(ramMB)")
        #expect((report["lock"] as? [String: Any])?["userUnlocked"] as? Bool == true)
    }

    /// The AVD's own `hw.ramSize`, so the cold boot leaves it with the RAM it is configured for.
    static func configuredRAM() throws -> Int {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd/\(AndroidE2E.expectedAVD).avd/config.ini")
        let line = try #require(try String(contentsOf: config, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("hw.ramSize=") })
        return try #require(Int(line.dropFirst("hw.ramSize=".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "Mm"))))
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

    @Test("in both landscape rotations describe-ui, tap and screenshot follow the guest", arguments: [(1, 90), (3, 270)])
    func landscape(rotation: Int, degrees: Int) async throws {
        try await rotate(to: rotation)
        do {
            let tree = try await AndroidE2E.tree()
            let screen = try #require(tree["screen"] as? [String: Any])
            #expect(screen["orientation"] as? String == "landscape")
            #expect(screen["rotation"] as? Int == degrees, "user_rotation \(rotation)")
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

    @Test("orientation turns auto-rotate off while landscape and portrait restores it")
    func autoRotateRestored() async throws {
        try await AndroidE2E.shell("am start -W -f 0x10008000 -a android.settings.SETTINGS")
        try await AndroidE2E.shell("settings put system user_rotation 0")
        try await AndroidE2E.shell("settings put system accelerometer_rotation 1")
        do {
            let landscape = try await AndroidE2E.run("orientation landscape-left --timeout 15 --json")
            let turned = try #require(try JSONSerialization.jsonObject(with: Data(landscape.stdout.utf8)) as? [String: Any])
            #expect((turned["autoRotate"] as? [String: Any])?["before"] as? Bool == true)
            #expect((turned["autoRotate"] as? [String: Any])?["now"] as? Bool == false)
            #expect(try await AndroidE2E.shell("settings get system accelerometer_rotation").trimmingCharacters(in: .whitespacesAndNewlines) == "0")

            let portrait = try await AndroidE2E.run("orientation portrait --timeout 15 --json")
            let back = try #require(try JSONSerialization.jsonObject(with: Data(portrait.stdout.utf8)) as? [String: Any])
            #expect((back["autoRotate"] as? [String: Any])?["restored"] as? Bool == true)
            #expect(try await AndroidE2E.shell("settings get system accelerometer_rotation").trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        } catch {
            try await restorePortrait()
            throw error
        }
        try await restorePortrait()
    }
}

@Suite("Android evidence runs", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidRunTests {
    @Test("a screenshot, a logs read and a batch screenshot step are numbered into the run")
    func threeCaptures() async throws {
        _ = try await AndroidE2E.serial()
        let (summary, folder) = try await RunE2E.record { environment in
            for command in ["screenshot", "logs --last 5s --max-lines 20", "batch --step screenshot"] {
                try await AndroidE2E.run(command, environment: environment)
            }
        }
        try RunE2E.checkThreeCaptures(summary, folder: folder)
    }
}
