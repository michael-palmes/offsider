import ArgumentParser
import CoreGraphics
import Foundation
import OffsiderCore

struct StreamVideo: AsyncParsableCommand {
    enum OutputFormat: String, ExpressibleByArgument {
        case mjpeg
        case raw
        case ffmpeg
        case bgra
    }

    static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Stream device frames to stdout using screenshot capture",
        discussion: """
        mjpeg, raw and ffmpeg send one JPEG per screenshot, upright as `screenshot` takes it; --mask-region paints \
        a rectangle in points black on every one of them, and a frame that may have been taken in another orientation \
        or size than the first is replaced by the last masked frame. bgra passes the device's own video stream through \
        and takes no --mask-region. Video cannot be masked by the accessibility tree: --mask-secure, --mask-id, \
        --mask-label, --mask-label-contains, --mask-text and --mask-emails exit 1 with video_unmasked and send nothing, as does a stream \
        while the evidence run masks emails or ids. One tree read before the first frame refuses the same way when a password \
        field is on screen or the tree cannot be read (OFFSIDER_MASK_SECURE=0 skips it outside a run); --unmasked streams anyway, \
        with a warning.
        """
    )

    @OptionGroup
    var deviceOption: ReadDeviceOption

    @Option(help: "Output format: mjpeg, raw, ffmpeg, bgra (default: mjpeg)")
    var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "JPEG quality (1-100, default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @OptionGroup
    var masks: VideoMaskOptions

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

        if format == .bgra, !masks.maskRegions.isEmpty {
            throw ValidationError("--mask-region paints screenshot frames, and --format bgra passes the device's own video through unpainted. Use --format mjpeg, raw or ffmpeg.")
        }
    }

    @MainActor
    func run() async throws {
        let checksSecureField = try masks.requireMaskable(command: "stream-video")
        let regions = try masks.regions()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        let backend = route.backend
        let (device, marker) = try await RecordVideo.start(command: "stream-video", backend: backend, device: route.device, checksSecureField: checksSecureField)
        defer { marker.remove() }

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        switch format {
        case .bgra:
            try await streamBGRA(from: backend, device: device, cancellationFlag: cancellationFlag)
        default:
            let source = VideoFrameSource(backend: backend, device: device, scale: scale, regions: regions)
            try await streamCompressedFrames(from: source, format: format, cancellationFlag: cancellationFlag)
        }
    }

    // MARK: - Screenshot-based streaming

    @MainActor
    private func streamCompressedFrames(
        from source: VideoFrameSource,
        format: OutputFormat,
        cancellationFlag: CancellationFlag
    ) async throws {
        let device = source.device
        FileHandle.standardError.write(Data("Starting screenshot-based video stream from \(device.platform.videoSourceNoun) \(device.rawValue)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format.rawValue), FPS: \(fps), Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        var pending = try await source.firstFrame { error in
            FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
        }
        let frameInterval = 1.0 / Double(fps)
        let mjpegBoundary = "--mjpegstream"
        let destination = FileHandle.standardOutput

        if format == .mjpeg {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(mjpegBoundary)\r\n\r\n"
            destination.write(Data(header.utf8))
        }

        var frameCount: UInt64 = 0
        var heldCount = 0
        let startTime = Date()

        while true {
            if Task.isCancelled {
                break
            }
            if await cancellationFlag.isCancelled() {
                break
            }

            let frameStartTime = Date()

            do {
                let frame: VideoFrame
                if let first = pending {
                    frame = VideoFrame(image: first, held: false)
                    pending = nil
                } else {
                    frame = try await source.next()
                }
                let processedData = try VideoFrameUtilities.jpegData(from: frame.image, scale: source.scalesItself ? 1 : scale, quality: quality)

                switch format {
                case .mjpeg:
                    let frameHeader = "\(mjpegBoundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(processedData.count)\r\n\r\n"
                    destination.write(Data(frameHeader.utf8))
                    destination.write(processedData)
                    destination.write(Data("\r\n".utf8))
                case .raw:
                    var length = UInt32(processedData.count).bigEndian
                    destination.write(Data(bytes: &length, count: 4))
                    destination.write(processedData)
                case .ffmpeg:
                    destination.write(processedData)
                case .bgra:
                    break
                }

                frameCount += 1
                if frame.held { heldCount += 1 }

                if frameCount % UInt64(max(1, fps)) == 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        let actualFPS = Double(frameCount) / elapsed
                        FileHandle.standardError.write(Data(String(format: "Captured %llu frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStartTime)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        if format == .mjpeg {
            destination.write(Data("\(mjpegBoundary)--\r\n".utf8))
        }

        let elapsed = Date().timeIntervalSince(startTime)
        if frameCount > 0 && elapsed > 0 {
            let avgFPS = Double(frameCount) / elapsed
            let held = heldCount > 0 ? ", \(heldCount) held" : ""
            let summary = String(format: "Streamed %llu frames in %.1f seconds (%.1f FPS average)", frameCount, elapsed, avgFPS)
            FileHandle.standardError.write(Data("\(summary)\(held)\n".utf8))
        }
    }

    // MARK: - BGRA streaming

    private func streamBGRA(
        from backend: any DeviceBackend,
        device: DeviceID,
        cancellationFlag: CancellationFlag
    ) async throws {
        guard let streamer = backend as? any RawVideoStreaming else {
            throw CLIError(errorDescription: "BGRA streaming is not supported for device \(device.rawValue).", reason: .notSupported)
        }

        FileHandle.standardError.write(Data("Starting BGRA video stream from \(device.platform.videoSourceNoun) \(device.rawValue)...\n".utf8))
        FileHandle.standardError.write(Data("Format: bgra, Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Note: This is raw pixel data. Use ffmpeg to convert:\n".utf8))
        FileHandle.standardError.write(Data("  offsider stream-video --format bgra --device <DEVICE_ID> | ffmpeg -f rawvideo -pixel_format bgra -video_size WIDTHxHEIGHT -i - output.mp4\n".utf8))
        if device.platform == .android {
            FileHandle.standardError.write(Data("Note: the Android Emulator sends a new frame only when the screen changes, so a still screen sends one frame.\n".utf8))
        }
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        try await streamer.streamBGRA(
            from: device,
            fps: fps,
            quality: quality,
            scale: scale,
            to: STDOUT_FILENO,
            isCancelled: { await cancellationFlag.isCancelled() }
        )
    }
}
