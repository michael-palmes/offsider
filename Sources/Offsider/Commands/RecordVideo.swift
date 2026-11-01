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
        `screenshot` or screenshot steps in a batch. Only that read holds the device, so other commands can read and \
        drive it while it records; a recording sends no input. It records until --duration runs out (10 minutes without it) or \
        it gets Ctrl+C, SIGINT, SIGTERM or SIGHUP, then saves every captured frame at the times they were taken and leaves \
        nothing else beside the file; a stop before the first frame ends it with nothing recorded (exit 1), and a closed output \
        pipe does not stop it. A simulator or emulator that stops answering for 30 s ends it with the frames so far saved \
        (exit 1, device_unresponsive); a stop that still cannot finish within seconds discards the file (exit 1, video_failed). \
        `session stop --device` also stops and saves a recording.
        """
    )

    @OptionGroup
    var deviceOption: ReadDeviceOption

    @OptionGroup
    var appOption: AppOption

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to offsider-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    @Option(help: ArgumentHelp("Stop and save this many seconds after the first frame (1 to 3600, default 600); Ctrl+C or SIGINT stops it sooner.", valueName: "seconds"))
    var duration: Double?

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

        if let duration, !(duration.isFinite && (1...3600).contains(duration)) {
            throw ValidationError("--duration must be from 1 to 3600 seconds.")
        }
    }

    /// Each stops the recording and saves it; SIGPIPE is ignored instead, so a background recording outlives the pipe it was started with.
    static let stopSignals = [SIGINT, SIGTERM, SIGHUP]

    /// How long a recording with no `--duration` runs, so a lost background one cannot block logins for ever.
    static let defaultLimit: TimeInterval = 600

    /// Heard off the main thread, as a blocked one must still be able to stop.
    static let signalQueue = DispatchQueue.global(qos: .userInitiated)

    /// The read limit for a simulator or emulator; a physical device has limits of its own, and a first read can build the runner.
    static func readLimit(for device: DeviceID) -> Duration? {
        guard !device.isPhysicalAndroidDevice, !device.isPhysicalIOSDevice else { return nil }
        return .seconds(DeviceWatchdog.readBound + DeviceWatchdog.grace)
    }

    /// Ends the process, saving nothing, when a capture blocks the main actor past the read limit, which the bounded read cannot catch.
    static func watchdog(_ stop: RecordingStop) -> DeviceWatchdog {
        DeviceWatchdog(fire: { [stop] message in stop.abandon(reason: .deviceUnresponsive, message: message) })
    }

    /// The bounded read gets to go first.
    static let watchdogExtra: TimeInterval = 5

    /// The note when the default limit, and not a stop, ended the recording.
    static func limitNote(duration: TimeInterval?, stopped: Bool) -> String? {
        guard duration == nil, !stopped else { return nil }
        return "Stopped at the 10 minute limit. For longer, pass --duration, up to 3600."
    }

    @MainActor
    func run() async throws {
        let stop = RecordingStop()
        signal(SIGPIPE, SIG_IGN)
        let signalObserver = SignalObserver(signals: Self.stopSignals, queue: Self.signalQueue) { stop.request() }
        defer { signalObserver.invalidate() }

        let checksSecureField = try masks.requireMaskable(command: "record-video")
        try await masks.confirmCheckOff(command: "record-video")
        let regions = try masks.regions()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        await appOption.apply(to: route)
        let backend = route.backend
        let (booted, marker) = try await Self.start(command: "record-video", backend: backend, device: route.device, checksSecureField: checksSecureField)
        let device = booted.id
        defer { marker.remove() }

        let target = try prepareOutputURL()
        let console = Console.current
        let recording = StartPersonView.recordingLabel(device: device.rawValue, elapsed: 0)
        console.step("Recording \(booted.videoSourceNoun) \(device.rawValue) to \(target.url.path)", label: recording)
        console.step("Press Ctrl+C or run `kill -INT \(getpid())` to stop recording; every captured frame is saved\(duration == nil ? ", and it stops by itself after 10 minutes" : "")", label: recording)

        let source = VideoFrameSource(backend: backend, device: device, scale: scale, regions: regions)
        let saved = try await console.progress(recording) {
            try await Self.record(from: source, to: target, fps: fps, quality: quality, scale: scale, duration: duration ?? Self.defaultLimit, stop: stop)
        }
        let limitNote = Self.limitNote(duration: duration, stopped: stop.isRequested)
        let held = saved.held > 0 ? ", \(saved.held) held" : ""
        console.clearLine()
        console.line("Recording saved to \(saved.path): \(saved.summary)\(held)", person: nil)
        if json {
            console.data(
                VideoRecordingReport(
                    path: saved.path, frames: saved.frames, heldFrames: saved.held, seconds: saved.seconds, regions: source.painted, unmasked: masks.unmasked, reachedLimit: limitNote != nil
                ).jsonLine() + "\n"
            )
        } else {
            console.show(StartPersonView.videoSaved(path: saved.path, seconds: saved.seconds, frames: saved.frames, held: saved.held))
        }
        if let limitNote { console.notice(.note(limitNote)) }
    }

    /// A finished recording: where it went, its frames, those repeating a masked frame, and the time from the first frame to the last.
    struct SavedRecording: Equatable {
        let path: String
        let frames: Int
        let held: Int
        let seconds: TimeInterval

        /// `248 frames over 25.6 s (9.7 FPS)`, as the frames were taken.
        var summary: String {
            let rate = VideoRecordingReport.framesPerSecond(frames: frames, seconds: seconds).map { String(format: " (%.1f FPS)", $0) } ?? ""
            return "\(frames) frame\(frames == 1 ? "" : "s") over " + String(format: "%.1f s", seconds) + rate
        }
    }

    /// Stages the MP4 beside `target` from the first frame until `stop` or `duration`, then moves it into place; the folder goes on every path.
    @MainActor
    static func record(
        from source: VideoFrameSource,
        to target: (url: URL, userNamed: Bool),
        fps: Int,
        quality: Int,
        scale: Double,
        duration: TimeInterval?,
        stop: RecordingStop,
        readLimit: Duration? = nil
    ) async throws -> SavedRecording {
        let readLimit = readLimit ?? Self.readLimit(for: source.device)
        let initialImage: CGImage
        do {
            initialImage = try await watchdog(stop).guardingRead(of: source.device, extra: watchdogExtra) { try await source.start() }
        } catch let failure as CLIError where failure.reason == .maskUnproven {
            throw failure
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(TerminalText.line(error.localizedDescription))", reason: .videoFailed)
        }
        guard stop.beginCapturing() else {
            throw CLIError(errorDescription: RecordingStop.earlyMessage("record-video"), reason: .videoFailed)
        }
        let staging: String
        do {
            staging = try OutputFile.stagingDirectory(for: target.url.path)
        } catch let error as OutputFileError {
            throw CLIError(errorDescription: error.message, reason: .videoFailed)
        }
        stop.discardOnGivingUp(staging)
        defer {
            stop.finished()
            OutputFile.discardStaging(staging)
        }
        let staged = URL(fileURLWithPath: staging).appendingPathComponent("recording.mp4")
        let written: (frames: Int, held: Int, seconds: TimeInterval, hung: Bool)
        do {
            written = try await capture(
                initialImage, from: source, outputURL: staged, fps: fps, quality: quality, scale: scale, duration: duration, stop: stop, readLimit: readLimit
            )
        } catch let failure as CLIError where failure.reason == .maskUnproven {
            throw failure
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(TerminalText.line(error.localizedDescription))", reason: .videoFailed)
        }
        do {
            let path = try OutputFile.commit(staged.path, to: target.url.path, replacing: target.userNamed)
            let saved = SavedRecording(path: path, frames: written.frames, held: written.held, seconds: written.seconds)
            if written.hung {
                throw CLIError(
                    errorDescription: "\(source.device.rawValue) stopped answering, so the recording ended early. Saved \(saved.summary) to \(path).",
                    reason: .deviceUnresponsive,
                    hint: "offsider doctor --device \(source.device.rawValue)"
                )
            }
            return saved
        } catch let error as OutputFileError {
            throw CLIError(errorDescription: error.message, reason: .videoFailed)
        }
    }

    @MainActor
    private static func capture(
        _ initialImage: CGImage,
        from source: VideoFrameSource,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        duration: TimeInterval?,
        stop: RecordingStop,
        readLimit: Duration?
    ) async throws -> (frames: Int, held: Int, seconds: TimeInterval, hung: Bool) {
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
        let clock = ContinuousClock()
        let endsAt = duration.map { clock.now + .seconds($0) }
        let watchdog = Self.watchdog(stop)
        var lastFrameAt = clock.now
        var appendFailures = 0
        var hung = false

        capturing: while true {
            if Task.isCancelled {
                break
            }
            if stop.isRequested {
                break
            }
            if let duration, Date().timeIntervalSince(writerStartTime) >= duration {
                break
            }

            let frameStart = Date()

            switch await watchdog.guardingRead(of: source.device, extra: Self.watchdogExtra, { await source.next(stop: stop, endsAt: endsAt, readLimit: readLimit) }) {
            case .frame(let frame):
                lastFrameAt = clock.now
                let now = Date()
                var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                if presentationTime <= lastPresentationTime {
                    presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                }

                do {
                    try recorder.append(image: frame.image, presentationTime: presentationTime)
                } catch {
                    appendFailures += 1
                    guard recorder.isWriting, appendFailures < Self.maximumAppendFailures else { throw error }
                    Self.frameFailed(error)
                    break
                }
                appendFailures = 0
                lastPresentationTime = presentationTime
                frameCount += 1
                if frame.held { heldCount += 1 }
                Console.current.relabel(StartPersonView.recordingLabel(device: source.device.rawValue, elapsed: now.timeIntervalSince(startTime)))

                if frameCount - lastLogFrame >= Int64(fps) {
                    lastLogFrame = frameCount
                    let elapsed = Date().timeIntervalSince(startTime)
                    let actualFPS = VideoRecordingReport.framesPerSecond(frames: Int(frameCount), seconds: presentationTime.seconds) ?? 0
                    Console.current.step(
                        String(format: "Captured %lld frames (%.1f FPS actual)", frameCount, actualFPS),
                        label: StartPersonView.recordingLabel(device: source.device.rawValue, elapsed: elapsed)
                    )
                }
            case .failed(let error):
                Self.frameFailed(error)
                if let readLimit, clock.now - lastFrameAt >= readLimit {
                    hung = true
                    break capturing
                }
            case .ended:
                break capturing
            case .hung:
                hung = true
                break capturing
            }

            let elapsed = Date().timeIntervalSince(frameStart)
            var sleepTime = frameInterval - elapsed
            if let duration {
                sleepTime = min(sleepTime, duration - Date().timeIntervalSince(writerStartTime))
            }
            if sleepTime > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        stop.saving()
        Console.current.relabel("Saving the video")
        try await recorder.finish()
        return (Int(frameCount), heldCount, lastPresentationTime.seconds, hung)
    }

    /// A writer that keeps refusing frames ends the recording; one failed frame does not.
    static let maximumAppendFailures = 5

    /// An agent reads every failed frame; a person one warning per distinct cause.
    static func frameFailed(_ error: any Error) {
        let message = TerminalText.line(error.localizedDescription)
        Console.current.line("Error capturing frame: \(message)", person: .warning("A frame could not be captured: \(message)"))
    }

    /// Refuses (exit 8, `device_busy`) while `login` or `wake` holds the device, so a typed password never lands in a recording.
    static func refuseDuringSignIn(
        _ key: DeviceLockKey, device: String, command: String = "record-video", holder: (DeviceLockKey) -> DeviceLockHolder? = { DeviceLock.currentHolder($0) }
    ) throws {
        guard let current = holder(key), RecordingMarker.refusedHolderCommands.contains(current.command.split(separator: " ").first.map(String.init) ?? "") else { return }
        throw DeviceBusy(device: device, command: command, holder: current, waited: nil)
    }

    /// The booted device and its marker for both video commands; frames need neither the tree reader nor its lock, so both go before any frame.
    @MainActor
    static func start(
        command: String, backend: any DeviceBackend, device: DeviceID, checksSecureField: Bool,
        root: String = OffsiderPrivateDirectory.root,
        holder: (DeviceLockKey) -> DeviceLockHolder? = { DeviceLock.currentHolder($0) },
        claims: DeviceClaims = .current
    ) async throws -> (booted: BootedDevice, marker: RecordingMarker) {
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(device)
        if checksSecureField {
            try await VideoMaskOptions.requireNoSecureField(command: command, backend: backend, device: booted.id)
        }
        let key = DeviceLockKey(platform: booted.id.platform, id: booted.id.rawValue)
        let marker = try beginRecording(key, device: booted.id.rawValue, command: command, root: root, holder: holder)
        await (backend as? any TreeReadReleasing)?.releaseTreeReads(on: booted.id)
        claims.release(key)
        return (booted, marker)
    }

    /// Marks the device as recording before checking the lock holder, so a `login` that takes the lock in between sees the marker.
    static func beginRecording(
        _ key: DeviceLockKey, device: String, command: String,
        root: String = OffsiderPrivateDirectory.root,
        holder: (DeviceLockKey) -> DeviceLockHolder? = { DeviceLock.currentHolder($0) }
    ) throws -> RecordingMarker {
        let marker: RecordingMarker
        do {
            marker = try RecordingMarker.create(key, root: root)
        } catch {
            throw CLIError(
                errorDescription: "Offsider could not mark \(device) as recording (\(error)), so nothing was recorded. Check that Offsider's private locks folder exists and is writable by you, then retry.",
                reason: .videoFailed
            )
        }
        do {
            try refuseDuringSignIn(key, device: device, command: command, holder: holder)
        } catch {
            marker.remove()
            throw error
        }
        return marker
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

/// Heard from the command's start, as a background job ignores SIGINT until then: before the first frame a stop ends it at once, after it the loop stops, and a timer off the main thread ends the process if the loop never gets there.
final class RecordingStop: @unchecked Sendable {
    static func earlyMessage(_ command: String) -> String {
        "\(command) was stopped before its first frame, so nothing was \(command == "stream-video" ? "streamed" : "recorded")."
    }

    /// How long a stop waits for the loop, which a blocked main thread would never reach: longer for a recording, whose file a busy Mac must not cost, than for a stream, which has none to lose.
    static func stuckAfter(_ command: String) -> TimeInterval { command == "stream-video" ? 5 : 15 }
    /// How long the writer has to finish the file once the loop has ended.
    static let savingAfter: TimeInterval = 30

    private let lock = NSLock()
    private var requested = false
    private var capturing = false
    private var done = false
    private var savingStarted = false
    private var staging: String?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "offsider.recording-stop")
    private let command: String
    private let endNow: @Sendable () -> Void
    private let giveUp: @Sendable (FailureReason, String) -> Void
    private let discards: Bool
    private let stuckAfter: TimeInterval
    private let savingAfter: TimeInterval

    init(
        command: String = "record-video", endNow: (@Sendable () -> Void)? = nil, giveUp: (@Sendable (FailureReason, String) -> Void)? = nil,
        stuckAfter: TimeInterval? = nil, savingAfter: TimeInterval = RecordingStop.savingAfter
    ) {
        self.command = command
        self.endNow = endNow ?? { ErrorReporter.exitFromTimer(reason: .videoFailed, message: RecordingStop.earlyMessage(command), hint: nil) }
        let exits = DeviceWatchdog.defaultAction
        self.discards = giveUp != nil || exits == .exitProcess
        self.giveUp = giveUp ?? { reason, message in
            switch exits {
            case .exitProcess: ErrorReporter.exitFromTimer(reason: reason, message: message, hint: nil)
            case .report: DeviceWatchdog.report(message)
            }
        }
        self.stuckAfter = stuckAfter ?? Self.stuckAfter(command)
        self.savingAfter = savingAfter
    }

    func request() {
        let (early, first) = lock.withLock { () -> (Bool, Bool) in
            let first = !requested && !done && !savingStarted
            requested = true
            return (!capturing, first)
        }
        if early {
            endNow()
        } else if first {
            arm(after: stuckAfter)
        }
    }

    /// Marks the first frame as taken; false when a stop came before it.
    func beginCapturing() -> Bool {
        lock.withLock {
            capturing = true
            return !requested
        }
    }

    var isRequested: Bool { lock.withLock { requested } }

    /// The folder to remove when the process has to end without saving.
    func discardOnGivingUp(_ path: String) {
        lock.withLock { staging = path }
    }

    /// The loop has ended, so what is left is the writer; a stop's shorter limit no longer applies.
    func saving() {
        lock.withLock { savingStarted = true }
        arm(after: savingAfter)
    }

    /// Nothing is left that could get stuck.
    func finished() {
        lock.withLock {
            done = true
            timer?.cancel()
            timer = nil
        }
    }

    /// Ends the process without saving, from any thread.
    func abandon(reason: FailureReason, message: String) {
        if discards, let folder = lock.withLock({ staging }) { OutputFile.discardStaging(folder) }
        giveUp(reason, message)
    }

    private func arm(after seconds: TimeInterval) {
        lock.withLock {
            guard !done else { return }
            timer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + seconds)
            source.setEventHandler { [weak self] in self?.gaveUp() }
            timer = source
            source.resume()
        }
    }

    private func gaveUp() {
        let finished = lock.withLock { done }
        guard !finished else { return }
        let what = command == "stream-video" ? "ended it; its reader stopped reading or the device did not answer" : "discarded the recording; the device or the video writer did not answer"
        abandon(reason: .videoFailed, message: "\(command) could not stop in time, so Offsider \(what).")
    }
}
