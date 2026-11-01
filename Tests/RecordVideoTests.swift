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

        // Its own folder, so the staging folder the SIGINT wait looks for can only be this recording's.
        let defaultFolder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-record-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        let defaultOutputURL = defaultFolder.appendingPathComponent("clip.mp4")
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

        try? FileManager.default.removeItem(at: defaultFolder)

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
        #expect(error?.hint == "retry when it finishes")
        #expect(error?.failureMessage.contains("--wait-lock") == false)
        #expect(!RecordingMarker.isLive(Self.key, root: root))
    }

    @Test("a device another command holds during the password read stays exit 8, never offers --unmasked, and both video commands take --wait-lock", arguments: ["record-video", "stream-video"])
    func busyDuringTheRead(command: String) async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let claims = DeviceClaims()
        claims.root = { root }
        let held = try await DeviceLock.acquire(Self.key, command: "tap", wait: nil, root: root)
        defer { held.release() }

        let error = await #expect(throws: DeviceBusy.self) {
            _ = try await RecordVideo.start(
                command: command, backend: LockingReadBackend(claims: claims), device: Self.device, checksSecureField: true, root: root, holder: { _ in nil }, claims: claims
            )
        }
        #expect(error?.reason == .deviceBusy && error?.reason.exitCode.rawValue == 8)
        #expect(error?.failureMessage.contains("--unmasked") == false)
        #expect(try RecordVideo.parse(["--wait-lock", "5", "--device", Self.device.rawValue, "--output", "a.mp4"]).deviceOption.waitLock == 5)
        #expect(try StreamVideo.parse(["--wait-lock", "5", "--device", Self.device.rawValue]).deviceOption.waitLock == 5)
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

    /// Hangs from its `hangAt`th capture on, as a wedged device does, ignoring cancellation.
    final class HangingBackend: FakeDeviceBackend {
        var hangAt = 3

        override func screenshotPNG(for id: DeviceID) async throws -> Data {
            let data = try await super.screenshotPNG(for: id)
            if screenshotReads >= hangAt {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            return data
        }
    }

    /// Fails each capture from its `failAt`th on, as a device that has gone does.
    final class FailingBackend: FakeDeviceBackend {
        override func screenshotPNG(for id: DeviceID) async throws -> Data {
            let data = try await super.screenshotPNG(for: id)
            if screenshotReads >= 3 { throw CLIError(errorDescription: "gone") }
            return data
        }
    }

    /// Asks the recording to stop from inside one capture, so the test does not depend on how fast frames come.
    class StoppingBackend: FakeDeviceBackend {
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

    static func stopSoon(_ stop: RecordingStop) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { stop.request() }
    }

    @Test("a stop while a capture hangs still saves the frames so far, soon", .timeLimit(.minutes(1)))
    func stopDuringHungCapture() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let backend = HangingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        let stop = RecordingStop(endNow: { Issue.record("stopped before the first frame") }, giveUp: { _, message in Issue.record("gave up: \(message)") })
        Self.stopSoon(stop)

        let started = ContinuousClock.now
        let saved = try await RecordVideo.record(
            from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
            fps: 10, quality: 50, scale: 1, duration: nil, stop: stop
        )

        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(saved.frames == 2)
        #expect(try await Self.samples(in: target) == saved.frames)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip.mp4"])
    }

    @Test("--duration ends a recording whose capture hangs", .timeLimit(.minutes(1)))
    func durationDuringHungCapture() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let backend = HangingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])

        let saved = try await RecordVideo.record(
            from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
            fps: 10, quality: 50, scale: 1, duration: 1, stop: RecordingStop(endNow: { Issue.record("stopped before the first frame") })
        )
        #expect(saved.frames == 2)
    }

    @Test("a device that stops answering past the read limit ends the recording with device_unresponsive, its frames saved", .timeLimit(.minutes(1)))
    func hungPastReadLimit() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let backend = HangingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])

        let error = await #expect(throws: CLIError.self) {
            _ = try await RecordVideo.record(
                from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
                fps: 10, quality: 50, scale: 1, duration: nil, stop: RecordingStop(endNow: { Issue.record("stopped before the first frame") }), readLimit: .seconds(1)
            )
        }
        #expect(error?.reason == .deviceUnresponsive)
        #expect(error?.userFacingDescription.contains(target.path) == true)
        #expect(try await Self.samples(in: target) == 2)
    }

    @Test("captures that only fail past the read limit end the recording too", .timeLimit(.minutes(1)))
    func failingPastReadLimit() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let backend = FailingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])

        let error = await #expect(throws: CLIError.self) {
            _ = try await RecordVideo.record(
                from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
                fps: 10, quality: 50, scale: 1, duration: nil, stop: RecordingStop(endNow: { Issue.record("stopped before the first frame") }), readLimit: .seconds(1)
            )
        }
        #expect(error?.reason == .deviceUnresponsive)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a writer that has failed throws at once, rather than waiting for ever for room")
    func failedWriterThrows() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try H264StreamRecorder(outputURL: folder.appendingPathComponent("clip.mp4"), width: 120, height: 260, fps: 10, quality: 50)
        recorder.invalidate()
        #expect(!recorder.isWriting)
        let image = try #require(VideoFrameUtilities.makeCGImage(from: try VideoMaskTests.whitePNG(width: 120, height: 260)))
        #expect(throws: (any Error).self) { try recorder.append(image: image, presentationTime: .zero) }
    }

    @Test("a recording with no --duration has a 10 minute limit, and only the limit earns the note")
    func defaultLimit() {
        #expect(RecordVideo.defaultLimit == 600)
        #expect(RecordVideo.limitNote(duration: nil, stopped: false)?.contains("10 minute limit") == true)
        #expect(RecordVideo.limitNote(duration: nil, stopped: true) == nil)
        #expect(RecordVideo.limitNote(duration: 30, stopped: false) == nil)
    }

    @Test("--json says when the limit ended the recording")
    func reachedLimitJSON() throws {
        let line = VideoRecordingReport(path: "/tmp/a.mp4", frames: 2, heldFrames: 0, seconds: 1, regions: 0, unmasked: false, reachedLimit: true).jsonLine()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["reachedLimit"] as? Bool == true)
    }

    @Test("the read limit bounds simulators and emulators, and leaves phones and iPhones to their own")
    func readLimitByDevice() {
        #expect(RecordVideo.readLimit(for: Self.device) == .seconds(30))
        #expect(RecordVideo.readLimit(for: DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)) == .seconds(30))
        #expect(RecordVideo.readLimit(for: DeviceID(rawValue: "00008130-0000000000000ABC", platform: .ios)) == nil)
        #expect(RecordVideo.readLimit(for: DeviceID(rawValue: PolicyFixtures.serial, platform: .android)) == nil)
    }
}

@Suite("Stopping a recording that is stuck")
struct RecordingStopTests {
    final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(FailureReason, String)] = []
        func add(_ reason: FailureReason, _ message: String) { lock.withLock { seen.append((reason, message)) } }
        var all: [(FailureReason, String)] { lock.withLock { seen } }
    }

    static func stop(_ fired: Fired, command: String = "record-video", stuckAfter: TimeInterval = 0.2, savingAfter: TimeInterval = 30) -> RecordingStop {
        let stop = RecordingStop(command: command, endNow: { Issue.record("not early") }, giveUp: { fired.add($0, $1) }, stuckAfter: stuckAfter, savingAfter: savingAfter)
        #expect(stop.beginCapturing())
        return stop
    }

    @Test("a stop the loop never reaches gives up from another thread, once, with video_failed and the staging folder gone")
    func stuckGivesUp() async throws {
        let fired = Fired()
        let stop = Self.stop(fired)
        let folder = NSTemporaryDirectory() + ".offsider-staging-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        stop.discardOnGivingUp(folder)

        stop.request()
        stop.request()
        try await Task.sleep(for: .seconds(1))

        #expect(fired.all.count == 1)
        #expect(fired.all.first?.0 == .videoFailed)
        #expect(fired.all.first?.1.contains("record-video could not stop in time") == true)
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    @Test("a stalled reader's stream-video says so")
    func streamWording() async throws {
        let fired = Fired()
        let stop = Self.stop(fired, command: "stream-video")
        stop.request()
        try await Task.sleep(for: .seconds(1))
        #expect(fired.all.first?.1.contains("its reader stopped reading") == true)
    }

    @Test("once the loop has stopped, the writer gets its longer limit, so a good file is not thrown away")
    func savingGetsLonger() async throws {
        let fired = Fired()
        let stop = Self.stop(fired)
        stop.request()
        stop.saving()
        try await Task.sleep(for: .seconds(0.6))
        #expect(fired.all.isEmpty)
    }

    @Test("a first stop while the writer saves keeps the writer's longer limit, so Ctrl+C cannot cost a finished video")
    func stopDuringSavingKeepsLimit() async throws {
        let fired = Fired()
        let stop = Self.stop(fired)
        stop.saving()
        stop.request()
        try await Task.sleep(for: .seconds(0.6))
        #expect(fired.all.isEmpty)
    }

    @Test("a recording waits longer than a stream before it gives up, as it has a file to lose")
    func stuckLimits() {
        #expect(RecordingStop.stuckAfter("record-video") > RecordingStop.stuckAfter("stream-video"))
        #expect(RecordingStop.stuckAfter("stream-video") == 5)
    }

    @Test("a writer stuck past its own limit gives up too")
    func savingGivesUp() async throws {
        let fired = Fired()
        let stop = Self.stop(fired, savingAfter: 0.2)
        stop.saving()
        try await Task.sleep(for: .seconds(0.8))
        #expect(fired.all.count == 1)
    }

    @Test("a finished recording never gives up, even on a late signal")
    func finishedNeverGivesUp() async throws {
        let fired = Fired()
        let stop = Self.stop(fired)
        stop.request()
        stop.finished()
        stop.request()
        stop.saving()
        try await Task.sleep(for: .seconds(0.6))
        #expect(fired.all.isEmpty)
    }

    @Test("a stop before the first frame ends at once and arms nothing")
    func earlyStopArmsNothing() async throws {
        let early = VideoRecordingFileTests.EarlyStops()
        let fired = Fired()
        let stop = RecordingStop(endNow: { early.add() }, giveUp: { fired.add($0, $1) }, stuckAfter: 0.1)
        stop.request()
        try await Task.sleep(for: .seconds(0.4))
        #expect(early.value == 1)
        #expect(fired.all.isEmpty)
    }
}

@Suite("Streaming frames")
@MainActor
struct StreamFramesTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    static func output() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-stream-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    static func source(_ backend: FakeDeviceBackend) -> VideoFrameSource {
        VideoFrameSource(backend: backend, device: device, scale: 1, regions: [])
    }

    @Test("a stop during the first capture ends with exit 1 and nothing streamed, not even the HTTP header")
    func stopDuringFirstCapture() async throws {
        let (url, handle) = try Self.output()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = VideoRecordingFileTests.StoppingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        backend.stopAt = 1
        let error = await #expect(throws: CLIError.self) {
            try await StreamVideo.streamFrames(from: Self.source(backend), format: .mjpeg, fps: 10, quality: 50, scale: 1, stop: backend.stop, to: handle)
        }
        #expect(backend.early.value == 1)
        #expect(error?.reason == .videoFailed)
        #expect(error?.userFacingDescription == "stream-video was stopped before its first frame, so nothing was streamed.")
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test("a failed first capture is still before the first frame, so a stop during the retry ends at once too")
    func stopDuringRetry() async throws {
        let (url, handle) = try Self.output()
        defer { try? FileManager.default.removeItem(at: url) }
        final class FailsThenStops: VideoRecordingFileTests.StoppingBackend {
            override func screenshotPNG(for id: DeviceID) async throws -> Data {
                let data = try await super.screenshotPNG(for: id)
                if screenshotReads == 1 { throw CLIError(errorDescription: "not yet") }
                return data
            }
        }
        let backend = FailsThenStops(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        backend.stopAt = 2
        await #expect(throws: CLIError.self) {
            try await StreamVideo.streamFrames(from: Self.source(backend), format: .mjpeg, fps: 10, quality: 50, scale: 1, stop: backend.stop, to: handle)
        }
        #expect(backend.early.value == 1)
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test("a stop after the first frame ends the stream cleanly: header, frames and closing boundary")
    func stopAfterFirstFrame() async throws {
        let (url, handle) = try Self.output()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = VideoRecordingFileTests.StoppingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        backend.stopAt = 3
        try await StreamVideo.streamFrames(from: Self.source(backend), format: .mjpeg, fps: 10, quality: 50, scale: 1, stop: backend.stop, to: handle)
        let text = String(decoding: try Data(contentsOf: url), as: Unicode.ASCII.self)
        #expect(backend.early.value == 0)
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.components(separatedBy: "--mjpegstream\r\nContent-Type: image/jpeg").count - 1 == 3)
        #expect(text.hasSuffix("--mjpegstream--\r\n"))
    }

    @Test("a stop while a capture hangs ends the stream, and a hang past the read limit is device_unresponsive", .timeLimit(.minutes(1)))
    func hungCapture() async throws {
        let (url, handle) = try Self.output()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = VideoRecordingFileTests.HangingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        let stop = RecordingStop(command: "stream-video", endNow: { Issue.record("stopped before the first frame") }, giveUp: { _, message in Issue.record("gave up: \(message)") })
        VideoRecordingFileTests.stopSoon(stop)
        try await StreamVideo.streamFrames(from: Self.source(backend), format: .mjpeg, fps: 10, quality: 50, scale: 1, stop: stop, to: handle)
        #expect(String(decoding: try Data(contentsOf: url), as: Unicode.ASCII.self).hasSuffix("--mjpegstream--\r\n"))

        let again = VideoRecordingFileTests.HangingBackend(platform: .android, trees: [], screenshots: [try VideoMaskTests.whitePNG(width: 120, height: 260)])
        let (url2, handle2) = try Self.output()
        defer { try? FileManager.default.removeItem(at: url2) }
        let error = await #expect(throws: CLIError.self) {
            try await StreamVideo.streamFrames(from: Self.source(again), format: .raw, fps: 10, quality: 50, scale: 1, stop: RecordingStop(command: "stream-video", endNow: {}), readLimit: .seconds(1), to: handle2)
        }
        #expect(error?.reason == .deviceUnresponsive)
    }
}
