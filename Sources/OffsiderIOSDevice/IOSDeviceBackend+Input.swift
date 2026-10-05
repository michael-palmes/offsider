import Foundation
import OffsiderCore

/// Input wiring the runner lane and tests fill in; one per backend, so per command.
@MainActor
public struct IOSDeviceInputHooks {
    /// The session for hosts below the HID floor (the runner's); without it they refuse with `xcode_too_old`.
    public var fallbackInputSession: ((DeviceID) async throws -> any InputSession)?
    /// Unicode and `--replace` text; without it they refuse with `not_supported`.
    public var runnerText: (any RunnerTextTyping)?
    var coreDeviceVersion: () -> CoreDeviceVersion? = { CoreDeviceVersion.installed() }
    var makeSink: ((_ identifier: String, _ version: CoreDeviceVersion, _ name: String, _ udid: String) -> any DTUHIDSink)?
    var panels: [String: IOSDevicePanel] = [:]

    public init() {}
}

extension IOSDeviceBackend {
    /// UI points to points on the panel's native axes for the digitizer; the runner below the HID floor takes points as they are.
    public func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] {
        _ = try await requireBootedDevice(id)
        guard let version = input.coreDeviceVersion(), version.supportsHID else { return points }
        let panel = try await panel(for: id)
        return points.map { panel.panelPoint(x: $0.x, y: $0.y) }
    }

    /// CoreDevice HID on an Xcode 27 host; below the floor, the fallback session or `xcode_too_old` before any XPC.
    public func openInputSession(for id: DeviceID) async throws -> any InputSession {
        _ = try await requireBootedDevice(id)
        guard let device = try await directory.device(udid: id.rawValue) else {
            throw IOSDeviceError.notListed(id.rawValue)
        }
        let name = DeviceName.display(device.udid, label: device.label)
        guard let version = input.coreDeviceVersion(), version.supportsHID else {
            if let fallback = input.fallbackInputSession {
                return try await fallback(id)
            }
            throw IOSDeviceError.xcodeTooOld(name, version: input.coreDeviceVersion())
        }
        guard let identifier = device.coreDeviceIdentifier else {
            throw IOSDeviceError.hidFailed(name, udid: device.udid, detail: "devicectl did not report its CoreDevice identifier", sent: false)
        }
        let panel = try await panel(for: id)
        let sink = input.makeSink?(identifier, version, name, device.udid)
            ?? CoreDeviceSession(deviceIdentifier: identifier, version: version, name: name, udid: device.udid)
        return IOSDeviceInputSession(device: id, panel: panel, sink: sink, runnerText: input.runnerText)
    }

    /// Only a whole touch in one call: a held contact cannot outlive the command's sockets.
    public func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        guard let touch = Self.wholeTouch(steps) else {
            throw IOSDeviceError.notSupportedOnDevice(
                "A touch that stays down between commands",
                instead: "Pass --down and --up together (with --delay for a long press), or use `offsider tap`."
            )
        }
        let session = try await openInputSession(for: id)
        var down = false
        do {
            try await session.perform(.touch(direction: .down, x: touch.x, y: touch.y))
            down = true
            if touch.hold > 0 { try await Task.sleep(for: .seconds(touch.hold)) }
            try await session.perform(.touch(direction: .up, x: touch.x, y: touch.y))
        } catch {
            if down { try? await session.perform(.touch(direction: .up, x: touch.x, y: touch.y)) }
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

    /// Read once per command from `devicectl device info displays`.
    func panel(for id: DeviceID) async throws -> IOSDevicePanel {
        if let panel = input.panels[id.rawValue] { return panel }
        let output = try await directory.run(
            ["device", "info", "displays", "--device", id.rawValue, "--timeout", "20", "--json-output", "-", "-q"],
            label: "device info displays",
            udid: id.rawValue,
            timeout: IOSDeviceDirectory.infoTimeout
        )
        guard let panel = IOSDevicePanel.parse(displaysJSON: Data(output.utf8)) else {
            throw IOSDeviceError.devicectlFailed("device info displays", udid: id.rawValue, detail: "it reported no display size")
        }
        input.panels[id.rawValue] = panel
        return panel
    }
}
