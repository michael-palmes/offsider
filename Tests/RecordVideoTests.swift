import AVFoundation
import Foundation
import Testing

@Suite("Record Video Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct RecordVideoTests {
    @Test("Record video writes an MP4 file with default options")
    func recordVideoDefault() async throws {
        let result = try await invokeRecordVideo(duration: 3.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 10_000, "Recorded file should be non-empty and usable (got: \(result.fileSize))")
        #expect(result.stderr.contains("Recording simulator"))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == result.outputURL.path)
    }

    @Test("Record video honours FPS, scale, and quality settings")
    func recordVideoCustomOptions() async throws {
        let result = try await invokeRecordVideo(fps: 5, quality: 60, scale: 0.5, duration: 2.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 10_000)
        #expect(result.stderr.contains("Press Ctrl+C"))
    }

    @Test("Record video uses provided directory without deleting its contents")
    func recordVideoOutputDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-record-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

        let result = try await invokeRecordVideo(duration: 1.0, outputPath: tempDir.path)

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(result.exitCode == 0)
        #expect(result.fileSize > 0)
        #expect(result.outputURL.path.hasPrefix(tempDir.path))
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Record video validates FPS input")
    func recordVideoInvalidFPS() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let offsiderPath = try TestHelpers.getOffsiderPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: offsiderPath)
        process.arguments = [
            "record-video",
            "--device", udid,
            "--fps", "40"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("FPS must be between 1 and 30"))
    }

    @Test("--mask-region paints the rectangle black on the recorded frames and reports it")
    func recordVideoMaskRegion() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-record-scale-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: shot) }
        let report = try await TestHelpers.runOffsiderCommandSeparated("screenshot --json --output '\(shot.path)'", simulatorUDID: udid)
        let pixelsPerPoint = try #require((try JSONSerialization.jsonObject(with: Data(report.stdout.utf8)) as? [String: Any])?["pixelsPerPoint"] as? Double)

        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-record-region-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: clip) }
        let result = try await invokeRecordVideo(duration: 2.5, outputPath: clip.path, extraArguments: ["--mask-region", "20,120,200,150", "--json"])

        #expect(result.exitCode == 0, "\(result.stderr)")
        let summary = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(summary["heldFrames"] as? Int == 0)
        #expect((summary["maskedBy"] as? [String: Int])?["region"] == 1)
        #expect(summary["unmasked"] as? Bool == false)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result.outputURL))
        for seconds in [0.2, 1.5] {
            let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            for (x, y) in [(25.0, 125.0), (120.0, 195.0), (215.0, 265.0)] {
                let pixel = ScreenshotMaskTests.pixel(frame, Int(x * pixelsPerPoint), Int(y * pixelsPerPoint))
                #expect(pixel.allSatisfy { $0 < 24 }, "point \(x),\(y) at \(seconds) s is \(pixel)")
            }
        }
    }

    // MARK: - Helpers

    private struct RecordingResult {
        let outputURL: URL
        let stdout: String
        let stderr: String
        let fileSize: Int
        let exitCode: Int32
    }

    private func invokeRecordVideo(
        fps: Int = 10,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0,
        outputPath: String? = nil,
        extraArguments: [String] = []
    ) async throws -> RecordingResult {
        let udid = try TestHelpers.requireSimulatorUDID()
        let offsiderPath = try TestHelpers.getOffsiderPath()

        let defaultOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-record-test-\(UUID().uuidString).mp4")
        let configuredOutputPath = outputPath ?? defaultOutputURL.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: offsiderPath)
        process.arguments = [
            "record-video",
            "--device", udid,
            "--fps", "\(fps)",
            "--quality", "\(quality)",
            "--scale", "\(scale)",
            "--output", configuredOutputPath
        ] + extraArguments
        process.environment = TestHelpers.childEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        process.interrupt()
        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "record-video process did not exit after interrupt"
        )

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let printed = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedOutputPath = extraArguments.contains("--json")
            ? ((try? JSONSerialization.jsonObject(with: Data(printed.utf8))) as? [String: Any])?["path"] as? String ?? ""
            : printed
        let resolvedURL = resolvedOutputPath.isEmpty ? defaultOutputURL : URL(fileURLWithPath: resolvedOutputPath)

        var fileSize = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            fileSize = sizeNumber.intValue
        }

        if outputPath == nil {
            try? FileManager.default.removeItem(at: resolvedURL)
        }

        return RecordingResult(
            outputURL: resolvedURL,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            fileSize: fileSize,
            exitCode: process.terminationStatus
        )
    }
}
