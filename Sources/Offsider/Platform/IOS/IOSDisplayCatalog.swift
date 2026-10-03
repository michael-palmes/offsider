import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore

/// The simulator's built-in displays from its device type profile and, on a foldable, which one is active.
/// One-display devices never run devicectl.
@MainActor
final class IOSDisplayCatalog {
    private let logger: OffsiderLogger
    private var profiles: [String: [DisplayDescriptor]] = [:]
    private var actives: [String: ActiveDisplay] = [:]

    init(logger: OffsiderLogger) {
        self.logger = logger
    }

    /// The integrated displays, or nil when the profile cannot be read (treated as one display).
    func profile(of simulator: FBSimulator) -> [DisplayDescriptor]? {
        if let cached = profiles[simulator.udid] { return cached }
        let profile = Self.readProfile(of: simulator, logger: logger)
        if let profile { profiles[simulator.udid] = profile }
        return profile
    }

    func isFoldable(_ simulator: FBSimulator) -> Bool {
        (profile(of: simulator)?.count ?? 0) > 1
    }

    /// Cached for the command unless `refresh`; `applicationFrame` is the fallback when devicectl cannot say, or the first choice with `preferFrame`.
    func activeDisplay(
        of simulator: FBSimulator,
        applicationFrame: UIFrame?,
        refresh: Bool = false,
        preferFrame: Bool = false
    ) async -> ActiveDisplay? {
        guard let profile = profile(of: simulator) else { return nil }
        let frame = applicationFrame.map { (width: $0.width, height: $0.height) }
        guard profile.count > 1 else {
            return ActiveDisplay.resolve(profile: profile, devicectl: nil, applicationFrame: nil)
        }
        if !refresh, let cached = actives[simulator.udid] { return cached }
        if preferFrame, let frame,
           let matched = ActiveDisplay.resolve(profile: profile, devicectl: nil, applicationFrame: frame), matched.source == .applicationFrame {
            return matched
        }
        let devicectl = await Self.devicectlDisplays(udid: simulator.udid, logger: logger)
        let active = ActiveDisplay.resolve(profile: profile, devicectl: devicectl, applicationFrame: frame)
        if let active {
            logger.info().log("Active display: \(active.descriptor.role.rawValue) (screen \(active.descriptor.platformId)) from \(active.source.rawValue)")
            actives[simulator.udid] = active
        }
        return active
    }

    /// The posture, refined by a short hinge reading when the inner display is active, as only the hinge can tell half-opened from open.
    func posture(of simulator: FBSimulator, applicationFrame: UIFrame?, refresh: Bool = false) async -> Posture? {
        guard let active = await activeDisplay(of: simulator, applicationFrame: applicationFrame, refresh: refresh) else { return nil }
        guard active.posture == .open, let angle = await Self.hingeAngle(udid: simulator.udid, logger: logger) else {
            return active.posture
        }
        logger.info().log("Hinge angle: \(angle)")
        return Posture(hingeAngle: angle) == .halfOpened ? .halfOpened : .open
    }

    // MARK: - Sources

    /// SimDeviceType's `capabilities` (the whole plist), else the `capabilities.plist` in its bundle; both private CoreSimulator, so read through KVC.
    private static func readProfile(of simulator: FBSimulator, logger: OffsiderLogger) -> [DisplayDescriptor]? {
        guard simulator.responds(to: NSSelectorFromString("device")),
              let device = simulator.value(forKey: "device") as? NSObject,
              device.responds(to: NSSelectorFromString("deviceType")),
              let deviceType = device.value(forKey: "deviceType") as? NSObject else {
            logger.info().log("Display profile: device type unavailable")
            return nil
        }
        if deviceType.responds(to: NSSelectorFromString("capabilities")),
           let capabilities = deviceType.value(forKey: "capabilities") as? [String: Any],
           let displays = SimulatorDisplayProfile.displays(capabilities: capabilities) {
            return displays
        }
        guard deviceType.responds(to: NSSelectorFromString("bundlePath")),
              let bundlePath = deviceType.value(forKey: "bundlePath") as? String else {
            logger.info().log("Display profile: device type bundle unavailable")
            return nil
        }
        let path = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources/capabilities.plist")
        guard let data = FileManager.default.contents(atPath: path.path) else {
            logger.info().log("Display profile: no capabilities.plist at \(path.path)")
            return nil
        }
        return SimulatorDisplayProfile.displays(plist: data)
    }

    private static func devicectlDisplays(udid: String, logger: OffsiderLogger) async -> DevicectlDisplays? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-displays-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            let result = try await ProcessCapture.run(
                executable: "/usr/bin/xcrun",
                arguments: ["devicectl", "device", "info", "displays", "--device", udid, "--timeout", "9", "--json-output", output.path],
                timeout: 10
            )
            guard result.status == 0, let data = FileManager.default.contents(atPath: output.path) else {
                logger.info().log("devicectl displays failed (\(result.status)): \(result.stderr)")
                return nil
            }
            return try DevicectlDisplays.parse(json: data)
        } catch {
            logger.info().log("devicectl displays failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// `devicectl device motion hinge-angle` streams until its session ends, so read the first angle and stop it.
    private static func hingeAngle(udid: String, logger: OffsiderLogger, timeout: TimeInterval = 5) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "motion", "hinge-angle", "--device", udid, "--session-timeout", "3", "--timeout", "8"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(chunk)
            }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                usleep(100_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        do {
            try process.run()
        } catch {
            logger.info().log("Hinge angle: could not run devicectl: \(error)")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let angle = DevicectlDisplays.hingeAngle(in: buffer.text) { return angle }
            if !process.isRunning, buffer.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return DevicectlDisplays.hingeAngle(in: buffer.text)
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty
    }
}
