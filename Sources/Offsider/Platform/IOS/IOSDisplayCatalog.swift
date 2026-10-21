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
    private var postures: [String: Posture] = [:]
    private let displayReadings = FreshReadings<DevicectlDisplays?>()
    private let hingeReadings = FreshReadings<SimulatorHingeLog.Reading?>()

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

    /// Cached for the command unless `refresh`, which reads devicectl at most once a second; `applicationFrame` is the fallback when devicectl cannot say, or the first choice with `preferFrame`.
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
        let devicectl = await displayReadings.value(for: simulator.udid) {
            await Self.devicectlDisplays(udid: simulator.udid, logger: logger)
        }
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
        var posture = active.posture
        if active.posture == .open, let hinge = await hingeReading(of: simulator) {
            logger.info().log("Hinge: \(hinge)")
            posture = hinge.posture == .halfOpened ? .halfOpened : .open
        }
        postures[simulator.udid] = posture
        return posture
    }

    /// The posture this command last read, else the cached active display's.
    func lastPosture(of simulator: FBSimulator) -> Posture? {
        postures[simulator.udid] ?? actives[simulator.udid]?.posture
    }

    /// The hinge angle in degrees from the simulator's log; nil when the log gives only its state, or nothing.
    func hingeAngle(of simulator: FBSimulator) async -> Double? {
        await hingeReading(of: simulator)?.angle
    }

    /// Read at most once a second.
    private func hingeReading(of simulator: FBSimulator) async -> SimulatorHingeLog.Reading? {
        await hingeReadings.value(for: simulator.udid) {
            await Self.hingeReading(udid: simulator.udid, logger: logger)
        }
    }

    /// After moving the hinge or turning the device, so the next readings are fresh.
    func forgetReadings(of udid: String) {
        displayReadings.forget(udid)
        hingeReadings.forget(udid)
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

    private static func hingeReading(udid: String, logger: OffsiderLogger) async -> SimulatorHingeLog.Reading? {
        do {
            let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: SimulatorHingeLog.arguments(udid: udid), timeout: 10)
            guard result.status == 0 else {
                logger.info().log("Hinge log failed (\(result.status)): \(result.stderr)")
                return nil
            }
            return SimulatorHingeLog.reading(in: result.stdout)
        } catch {
            logger.info().log("Hinge log failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// The last reading per simulator, served again while younger than `window`, so polling does not spawn a reader every time.
@MainActor
final class FreshReadings<Value> {
    let window: TimeInterval
    private var readings: [String: (value: Value, at: TimeInterval)] = [:]
    private let now: @MainActor () -> TimeInterval

    init(window: TimeInterval = 1, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.window = window
        self.now = now
    }

    func value(for udid: String, read: () async -> Value) async -> Value {
        if let last = readings[udid], now() - last.at < window { return last.value }
        let value = await read()
        readings[udid] = (value, now())
        return value
    }

    func forget(_ udid: String) {
        readings[udid] = nil
    }
}
