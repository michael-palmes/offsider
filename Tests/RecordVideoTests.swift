import AVFoundation
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Record Video Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct RecordVideoTests {
    @Test("Record video stopped with SIGINT after its first frame writes an MP4 file with default options")
    func recordVideoDefault() async throws {
        let result = try await invokeRecordVideo(duration: 3.0, stop: .interrupt)
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

    /// `--duration`, or SIGINT once the first frame is taken; a stop before the first frame records nothing.
    private enum Stop {
        case duration
        case interrupt
    }

    private func invokeRecordVideo(
        fps: Int = 10,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0,
        stop: Stop = .duration,
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
        ] + (stop == .duration ? ["--duration", "\(duration)"] : []) + extraArguments
        process.environment = TestHelpers.childEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if stop == .interrupt {
            var isDirectory: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: configuredOutputPath, isDirectory: &isDirectory) && isDirectory.boolValue
                ? configuredOutputPath : (configuredOutputPath as NSString).deletingLastPathComponent
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning, Date() < deadline,
                  !((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains(where: { $0.hasPrefix(".offsider-staging-") }) {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            process.interrupt()
        }
        try await TestHelpers.waitForProcessExit(
            process,
            timeout: duration + 30,
            description: "record-video process did not exit"
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

@Suite("Record video during sign-in")
struct RecordVideoSignInTests {
    static let key = DeviceLockKey(platform: .ios, id: "SIM-1")

    @Test("recording is refused with device_busy (exit 8) while login, wake or type holds the device", arguments: ["login", "wake", "wake --unlock", "type"])
    func refusedDuringSignIn(command: String) {
        let holder = DeviceLockHolder(pid: 4242, command: command, startedAt: nil)
        let error = #expect(throws: DeviceBusy.self) { try RecordVideo.refuseDuringSignIn(Self.key, device: "SIM-1", holder: { _ in holder }) }
        #expect(error?.reason == .deviceBusy)
        #expect(error?.reason.exitCode.rawValue == 8)
        #expect(error?.failureMessage.contains("offsider \(command)") == true)
    }

    @Test("any other holder, or none, leaves recording free", arguments: ["tap", "batch", "loginx", ""])
    func otherHolders(command: String) throws {
        try RecordVideo.refuseDuringSignIn(Self.key, device: "SIM-1", holder: { _ in DeviceLockHolder(pid: 1, command: command, startedAt: nil) })
        try RecordVideo.refuseDuringSignIn(Self.key, device: "SIM-1", holder: { _ in nil })
    }
}

@Suite("Recording marker before capture")
@MainActor
struct VideoRecordingStartTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let key = DeviceLockKey(platform: .android, id: "emulator-5554")

    @Test("record-video and stream-video mark the device before asking who holds its lock, and keep the marker while they run", arguments: ["record-video", "stream-video"])
    func markerBeforeHolderCheck(command: String) async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var liveAtCheck: Bool?
        let (booted, marker) = try await RecordVideo.start(
            command: command, backend: FakeDeviceBackend(platform: .android, trees: []), device: Self.device, checksSecureField: false, root: root,
            holder: { key in liveAtCheck = RecordingMarker.isLive(key, root: root); return nil }
        )
        #expect(booted.id == Self.device)
        #expect(liveAtCheck == true)
        #expect(RecordingMarker.isLive(Self.key, root: root))
        marker.remove()
        #expect(!RecordingMarker.isLive(Self.key, root: root))
    }

    /// Locks the device on its first tree read and keeps a reader running, as the Android backend does with its helper.
    final class LockingReadBackend: FakeDeviceBackend, TreeReadReleasing {
        let claims: DeviceClaims
        private(set) var released: [DeviceID] = []

        init(claims: DeviceClaims) {
            self.claims = claims
            super.init(platform: .android, trees: [FakeUI.tree(platform: .android, [FakeUI.node(.button, id: "start", label: "Start", frame: FakeUI.frame(20, 100, 200, 44), platform: .android)])])
        }

        override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
            try await claims.claim(id)
            return try await super.accessibilityTree(for: id, point: point)
        }

        func releaseTreeReads(on id: DeviceID) async {
            released.append(id)
        }
    }

    @Test("after its one tree read a recording lets go of the device and its reader, so another command can lock it while the marker stays", arguments: ["record-video", "stream-video"])
    func lockReleasedAfterRead(command: String) async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let claims = DeviceClaims()
        claims.root = { root }
        let backend = LockingReadBackend(claims: claims)

        let (_, marker) = try await RecordVideo.start(
            command: command, backend: backend, device: Self.device, checksSecureField: true, root: root, holder: { _ in nil }, claims: claims
        )
        defer { marker.remove() }

        #expect(backend.treeReads == 1)
        #expect(backend.released == [Self.device])
        #expect(claims.heldKeys.isEmpty)
        let other = try await DeviceLock.acquire(Self.key, command: "tap", wait: nil, root: root)
        other.release()
        #expect(RecordingMarker.isLive(Self.key, root: root))
    }

    @Test("stream-video, like record-video, is refused with device_busy (exit 8) while login holds the device, and leaves no marker", arguments: ["record-video", "stream-video"])
    func refusedDuringLogin(command: String) async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let error = await #expect(throws: DeviceBusy.self) {
            _ = try await RecordVideo.start(
                command: command, backend: FakeDeviceBackend(platform: .android, trees: []), device: Self.device, checksSecureField: false, root: root,
                holder: { _ in DeviceLockHolder(pid: 4242, command: "login", startedAt: nil) }
            )
        }
        #expect(error?.reason.exitCode.rawValue == 8)
        #expect(error?.failureMessage.contains("offsider login") == true)
        #expect(error?.hint == "add --wait-lock 30 to the same command")
        #expect(!RecordingMarker.isLive(Self.key, root: root))
    }

    @Test("a marker that cannot be written fails with video_failed before the lock holder is read or any frame is taken")
    func unwritableLocks() async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: (root as NSString).appendingPathComponent(OffsiderPrivateDirectory.locksDirectoryName), contents: Data())
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        var holderRead = false
        let error = await #expect(throws: CLIError.self) {
            _ = try await RecordVideo.start(
                command: "record-video", backend: backend, device: Self.device, checksSecureField: false, root: root,
                holder: { _ in holderRead = true; return nil }
            )
        }
        #expect(error?.reason == .videoFailed)
        #expect(error?.userFacingDescription.contains("could not mark emulator-5554 as recording") == true)
        #expect(error?.userFacingDescription.contains("so nothing was recorded") == true)
        #expect(!holderRead)
        #expect(backend.screenshotReads == 0)
    }
}

@Suite("Recording to a file", .serialized)
@MainActor
struct VideoRecordingFileTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-record-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func source(_ screenshots: [Data]) -> VideoFrameSource {
        VideoFrameSource(backend: FakeDeviceBackend(platform: .android, trees: [], screenshots: screenshots), device: device, scale: 1, regions: [])
    }

    static func samples(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 { count += 1 }
        }
        return count
    }

    /// Counts the times a stop ended the command before its first frame, which outside a test exits.
    final class EarlyStops: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    /// Asks the recording to stop from inside one capture, so the test does not depend on how fast frames come.
    final class StoppingBackend: FakeDeviceBackend {
        let early = EarlyStops()
        lazy var stop = RecordingStop(endNow: { [early] in early.add() })
        var stopAt = 6

        override func screenshotPNG(for id: DeviceID) async throws -> Data {
            let data = try await super.screenshotPNG(for: id)
            if screenshotReads == stopAt { stop.request() }
            return data
        }
    }

    @Test("a stopped recording keeps every frame it reports, at the times they were taken, and leaves only the MP4 beside it")
    func stoppedKeepsEveryFrame() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let backend = StoppingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])

        let saved = try await RecordVideo.record(
            from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
            fps: 10, quality: 50, scale: 1, duration: nil, stop: backend.stop
        )

        #expect(saved.path == target.path)
        #expect(saved.frames == 6)
        #expect(backend.early.value == 0)
        #expect(try await Self.samples(in: target) == saved.frames)
        let length = try await AVURLAsset(url: target).load(.duration).seconds
        #expect(saved.seconds > 0.3 && length >= saved.seconds, "MP4 \(length) s, reported \(saved.seconds) s")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip.mp4"])
    }

    @Test("a stop during the first capture ends the command at once, and nothing is written beside the target")
    func stopBeforeFirstFrame() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = StoppingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        backend.stopAt = 1

        let error = await #expect(throws: CLIError.self) {
            _ = try await RecordVideo.record(
                from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (folder.appendingPathComponent("clip.mp4"), true),
                fps: 10, quality: 50, scale: 1, duration: nil, stop: backend.stop
            )
        }

        #expect(backend.early.value == 1)
        #expect(error?.reason == .videoFailed)
        #expect(error?.userFacingDescription == "record-video was stopped before its first frame, so nothing was recorded.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("--duration stops the recording by itself after that much video")
    func durationStops() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = ContinuousClock.now
        let saved = try await RecordVideo.record(
            from: Self.source([try VideoMaskTests.whitePNG(width: 120, height: 260)]), to: (folder.appendingPathComponent("clip.mp4"), true),
            fps: 10, quality: 50, scale: 1, duration: 1, stop: RecordingStop(endNow: { Issue.record("stopped before the first frame") })
        )
        let took = ContinuousClock.now - started

        #expect(took >= .seconds(1) && took < .seconds(10), "\(took)")
        #expect(try await Self.samples(in: URL(fileURLWithPath: saved.path)) == saved.frames)
        #expect(saved.summary.hasPrefix("\(saved.frames) frames over "))
    }

    @Test("a recording that fails before its first frame fails with video_failed and leaves nothing beside the target")
    func failureLeavesNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let error = await #expect(throws: CLIError.self) {
            _ = try await RecordVideo.record(
                from: Self.source([]), to: (folder.appendingPathComponent("clip.mp4"), true), fps: 10, quality: 50, scale: 1, duration: nil, stop: RecordingStop(endNow: { Issue.record("stopped before the first frame") })
            )
        }

        #expect(error?.reason == .videoFailed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
