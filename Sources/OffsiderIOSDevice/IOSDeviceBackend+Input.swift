import Foundation
import OffsiderCore

/// Input wiring the runner lane and tests fill in; one per backend, so per command.
@MainActor
public struct IOSDeviceInputHooks {
    /// The runner's session: below the HID floor it serves all input, above it the touches the broker cannot send.
    /// Without it, input below the floor refuses with `xcode_too_old`.
    public var fallbackInputSession: ((DeviceID) async throws -> any InputSession)?
    /// Unicode and `--replace` text; without it they refuse with `not_supported`.
    public var runnerText: (any RunnerTextTyping)?
    var coreDeviceVersion: () -> CoreDeviceVersion? = { CoreDeviceVersion.installed() }

    public init() {}
}

extension IOSDeviceBackend {
    /// UI points as they are: the broker maps them onto the touchscreen with the panel's current orientation, and the runner takes them directly.
    public func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] {
        _ = try await requireBootedDevice(id)
        if let tree, let screen = try? await geometry(for: id).screenInfo, Self.isWindowed(tree, screenWidth: screen.width, screenHeight: screen.height) {
            throw IOSDeviceError.notSupportedOnDevice(
                "Tapping an element of an app in a Stage Manager window",
                instead: "Its frames are relative to the window, not the screen. Make the app full screen, or tap by coordinates with `offsider tap -x <x> -y <y>`."
            )
        }
        return points
    }

    /// An app in a Stage Manager window reports frames inside the window: its root sits at the origin, smaller than the screen
    /// and clear of the screen's far edges. A Split View app spans the screen's height or width, so its frames are the screen's.
    static func isWindowed(_ tree: UITree, screenWidth: Double, screenHeight: Double) -> Bool {
        guard let app = tree.roots.first(where: { $0.role == .application }), let frame = app.frame,
              frame.x == 0, frame.y == 0, frame.width > 0, frame.height > 0, screenWidth > 0, screenHeight > 0 else { return false }
        let slack = 0.02
        let spansHeight = frame.height >= screenHeight * (1 - slack)
        let spansWidth = frame.width >= screenWidth * (1 - slack)
        return !spansHeight && !spansWidth
    }

    var hostHasHID: Bool { input.coreDeviceVersion()?.supportsHID == true }

    /// The session broker on an Xcode 27 host (falling back to the runner where it can), the runner below it,
    /// and `xcode_too_old` when neither is available.
    public func openInputSession(for id: DeviceID) async throws -> any InputSession {
        _ = try await requireBootedDevice(id)
        guard hostHasHID, sessionsAvailable else {
            if let fallback = input.fallbackInputSession {
                return try await fallback(id)
            }
            throw IOSDeviceError.xcodeTooOld(try await displayName(id), version: input.coreDeviceVersion())
        }
        let runner: (() async throws -> any InputSession)? = input.fallbackInputSession.map { open in { try await open(id) } }
        return IOSDeviceInputSession(
            device: id,
            session: { try await self.session(for: id) },
            runner: runner,
            runnerText: input.runnerText
        )
    }

    private func displayName(_ id: DeviceID) async throws -> String {
        guard let device = try await directory.device(udid: id.rawValue) else { throw IOSDeviceError.notListed(id.rawValue) }
        return DeviceName.display(device.udid, label: device.label)
    }

    /// Only a whole touch in one call, sent as one event so the broker times the hold on the device.
    public func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        guard let touch = Self.wholeTouch(steps) else {
            throw IOSDeviceError.notSupportedOnDevice(
                "A touch that stays down between commands",
                instead: "Pass --down and --up together (with --delay for a long press), or use `offsider tap`."
            )
        }
        let session = try await openInputSession(for: id)
        do {
            try await session.perform(.composite([
                .touch(direction: .down, x: touch.x, y: touch.y),
                .delay(touch.hold),
                .touch(direction: .up, x: touch.x, y: touch.y),
            ]))
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// Down, an optional hold, then up at the same point; nil for anything else.
    static func wholeTouch(_ steps: [DetachedTouchStep]) -> (x: Double, y: Double, hold: TimeInterval)? {
        guard let first = steps.first, let last = steps.last, steps.count == 2 || steps.count == 3,
              case let .down(x, y) = first, case .up(x, y) = last else { return nil }
        guard steps.count == 3 else { return (x, y, 0) }
        guard case let .hold(seconds) = steps[1] else { return nil }
        return (x, y, seconds)
    }
}

extension IOSDeviceBackend {
    /// A broker can be reached or started: a test connector, or this `offsider` executable to spawn.
    var sessionsAvailable: Bool { host.sessionConnector != nil || host.sessionExecutable != nil }

    /// One broker connection per device per command, reused or started through `session.json`; a broken one is replaced.
    func session(for id: DeviceID) async throws -> DeviceSessionClient {
        let udid = id.rawValue
        if let client = cachedSession(udid) { return client }
        let connector = try sessionConnector()
        let client = try await host.timing.measure("session") { try await connector.connect(udid: udid) }
        state.sessions[udid] = client
        return client
    }

    /// A live broker already serving `id`, never started; nil when none answers.
    func liveSession(for id: DeviceID) async -> DeviceSessionClient? {
        if let client = cachedSession(id.rawValue) { return client }
        guard hostHasHID, sessionsAvailable, let connector = try? sessionConnector(),
              let client = await connector.existing(udid: id.rawValue) else { return nil }
        state.sessions[id.rawValue] = client
        return client
    }

    /// The command's connection to the broker, dropped once broken; the request that broke it is never resent.
    private func cachedSession(_ udid: String) -> DeviceSessionClient? {
        guard let client = state.sessions[udid] else { return nil }
        guard client.isBroken else { return client }
        client.close()
        state.sessions[udid] = nil
        return nil
    }

    func sessionConnector() throws -> any DeviceSessionConnecting {
        if let connector = state.sessionConnector ?? host.sessionConnector { return connector }
        guard let executable = host.sessionExecutable else {
            throw IOSDeviceError(.sessionFailed, "This installation of Offsider cannot start a device session. Reinstall Offsider.")
        }
        let manager = DeviceSessionManager(
            store: DeviceSessionStore(root: host.privateRoot),
            processes: OffsiderSelfProcesses(executable: executable),
            environment: host.environment,
            log: log
        )
        state.sessionConnector = manager
        return manager
    }
}
