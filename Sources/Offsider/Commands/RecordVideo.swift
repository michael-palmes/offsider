import ArgumentParser
import Foundation
import AVFoundation
import OffsiderCore

struct RecordVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the device display to an MP4 file using H.264 encoding",
        discussion: """
        Each frame is a screenshot, upright as `screenshot` takes it. --mask-region paints a rectangle in points \
        black on every frame; Offsider reads the screen's orientation after every capture, and a frame that may have \
        been taken in another orientation or size than the first is replaced by the last masked frame (heldFrames). \
        Video cannot be masked by the accessibility tree: --mask-secure, --mask-id, --mask-label, \
        --mask-label-contains, --mask-text and --mask-emails exit 1 with video_unmasked and write nothing, as does \
        a recording while the evidence run masks emails or ids. One tree read before the first frame refuses the same way \
        when a password field is on screen or the tree cannot be read (OFFSIDER_MASK_SECURE=0 skips it outside a run); \
        --unmasked records anyway, with a warning. For masked evidence use \
        `screenshot` or screenshot steps in a batch.
        """
    )

    @OptionGroup
    var deviceOption: ReadDeviceOption

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to offsider-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    @OptionGroup
    var masks: VideoMaskOptions

    @Flag(name: .customLong("json"), help: "When the recording ends, print one JSON object to stdout instead of the path.")
    var json = false

    func validate() throws {
        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }

        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }

        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }

    @MainActor
    func run() async throws {
        let checksSecureField = try masks.requireMaskable(command: "record-video")
        let regions = try masks.regions()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)
        if checksSecureField {
            try await VideoMaskOptions.requireNoSecureField(command: "record-video", backend: backend, device: booted.id)
        }

        let key = DeviceLockKey(platform: booted.id.platform, id: booted.id.rawValue)
        try Self.refuseDuringSignIn(key, device: booted.id.rawValue)
        let marker = try? RecordingMarker.create(key)
        defer { marker?.remove() }

        let target = try prepareOutputURL()
        let staging: String
        do {
            staging = try OutputFile.stagingDirectory(for: target.url.path)
        } catch let error as OutputFileError {
            throw CLIError(errorDescription: error.message, reason: .videoFailed)
        }
        defer { OutputFile.discardStaging(staging) }
        let stagedURL = URL(fileURLWithPath: staging).appendingPathComponent("recording.mp4")
        var outputURL = target.url
        FileHandle.standardError.write(Data("Recording \(booted.id.platform.videoSourceNoun) \(booted.id.rawValue) to \(outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        let source = VideoFrameSource(backend: backend, device: booted.id, scale: scale, regions: regions)
        let written: (frames: Int, held: Int)
        do {
            written = try await recordVideo(
                from: source,
                outputURL: stagedURL,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
        } catch let failure as CLIError where failure.reason == .maskUnproven {
            throw failure
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)", reason: .videoFailed)
        }
        do {
            outputURL = URL(fileURLWithPath: try OutputFile.commit(stagedURL.path, to: target.url.path, replacing: target.userNamed))
        } catch let error as OutputFileError {
            throw CLIError(errorDescription: error.message, reason: .videoFailed)
        }
        let held = written.held > 0 ? ", \(written.held) of \(written.frames) frames held" : ""
        FileHandle.standardError.write(Data("Recording saved to \(outputURL.path)\(held)\n".utf8))
        if json {
            print(VideoRecordingReport(path: outputURL.path, frames: written.frames, heldFrames: written.held, regions: source.painted, unmasked: masks.unmasked).jsonLine())
        } else {
            print(outputURL.path)
        }
    }

    @MainActor
    private func recordVideo(
        from source: VideoFrameSource,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws -> (frames: Int, held: Int) {
        let initialImage = try await source.start()

        let dimensions = VideoFrameUtilities.computeDimensions(for: initialImage, scale: source.scalesItself ? 1.0 : scale)
        let recorder = try H264StreamRecorder(
            outputURL: outputURL,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            quality: quality
        )
        defer { recorder.invalidate() }

        let frameInterval = 1.0 / Double(fps)
        var frameCount: Int64 = 1
        var heldCount = 0
        var lastLogFrame: Int64 = 0
        let startTime = Date()
        var lastPresentationTime = CMTime.zero

        try recorder.append(image: initialImage, presentationTime: .zero)
        let writerStartTime = Date()

        while true {
            if Task.isCancelled {
                break
            }
            if await cancellationFlag.isCancelled() {
                break
            }

            let frameStart = Date()

            do {
                let frame = try await source.next()

                let now = Date()
                var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                if presentationTime <= lastPresentationTime {
                    presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                }

                try recorder.append(image: frame.image, presentationTime: presentationTime)
                lastPresentationTime = presentationTime
                frameCount += 1
                if frame.held { heldCount += 1 }

                if frameCount - lastLogFrame >= Int64(fps) {
                    lastLogFrame = frameCount
                    let elapsed = Date().timeIntervalSince(startTime)
                    let actualFPS = Double(frameCount) / max(elapsed, 0.0001)
                    FileHandle.standardError.write(Data(String(format: "Captured %lld frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStart)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        try await recorder.finish()
        return (Int(frameCount), heldCount)
    }

    /// Refuses (exit 8, `device_busy`) while `login` or `wake` holds the device, so a typed password never lands in a recording.
    static func refuseDuringSignIn(
        _ key: DeviceLockKey, device: String, holder: (DeviceLockKey) -> DeviceLockHolder? = { DeviceLock.currentHolder($0) }
    ) throws {
        guard let current = holder(key), RecordingMarker.refusedHolderCommands.contains(current.command.split(separator: " ").first.map(String.init) ?? "") else { return }
        throw DeviceBusy(device: device, command: "record-video", holder: current, waited: nil)
    }

    /// Where the recording goes once it finishes, and whether the user named that file (only then may it replace one).
    private func prepareOutputURL() throws -> (url: URL, userNamed: Bool) {
        let fileManager = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generatedName = "offsider-video-\(formatter.string(from: Date())).mp4"

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        var userNamed = false
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
            userNamed = true
        } else {
            resolvedPath = generatedName
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return (baseURL.appendingPathComponent(generatedName), false)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        if userNamed {
            do {
                try OutputFile.checkReplaceable(baseURL.path)
            } catch let error as OutputFileError {
                throw CLIError(errorDescription: error.message, reason: .videoFailed)
            }
        }
        return (baseURL, userNamed)
    }
}
