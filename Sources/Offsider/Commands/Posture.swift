import ArgumentParser
import Foundation
import OffsiderCore

struct PostureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "posture",
        abstract: "Read or set a foldable's posture, waiting until the device reports it.",
        discussion: """
        Postures: closed (the cover display is active), half-opened, open (the inner display is active). Without \
        a value, prints the current posture and the active display. A device with one display is not foldable. \
        On an iOS simulator Offsider moves the hinge as Device Hub's slider does (closed 0, half-opened 120, open \
        180 degrees); --angle sets another angle. Telling half-opened from open needs a hinge reading, which takes \
        a moment.

        Examples:
          offsider posture --device DEVICE_ID
          offsider posture open --device DEVICE_ID
          offsider posture --angle 90 --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The posture to set; omit to read the current one.", valueName: "closed|half-opened|open"))
    var value: String?

    @Option(help: ArgumentHelp("The hinge angle to move to, from 0 (closed) to 180 (open); iOS simulators only.", valueName: "degrees"))
    var angle: Int?

    @Option(help: ArgumentHelp("Seconds to wait for the posture, from 0.5 to 60.", valueName: "seconds"))
    var timeout: Double = 10

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let settable: [Posture] = [.closed, .halfOpened, .open]

    func validate() throws {
        _ = try target()
        guard (0.5...60).contains(timeout) else {
            throw ValidationError("--timeout must be from 0.5 to 60 seconds; got \(DeviceSettingsReport.number(timeout)).")
        }
    }

    func target() throws -> Posture? {
        if let angle {
            guard value == nil else {
                throw ValidationError("Give a posture or --angle, not both.")
            }
            guard HingeControl.range.contains(angle) else {
                throw ValidationError("--angle must be from 0 to 180 degrees; got \(angle).")
            }
            return nil
        }
        guard let value else { return nil }
        guard let posture = Posture(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased()), Self.settable.contains(posture) else {
            throw ValidationError("Unknown posture '\(value)'. Use one of: \(Self.settable.map(\.rawValue).joined(separator: ", ")).")
        }
        return posture
    }

    func run() async throws {
        let target = try target()
        let watchdog = DeviceWatchdog()
        try await watchdog.guarding(bound: DeviceWatchdog.setupBound, device: deviceOption.id) {
            let logger = OffsiderLogger()
            let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
            try await route.backend.prepare()
            let device = try await route.backend.requireBootedDevice(route.device).id
            watchdog.arm(bound: timeout + 10, device: deviceOption.id)
            print(try await Self.report(
                target, angle: angle, json: json, timeout: timeout, on: device, backend: route.backend, deviceName: deviceOption.id,
                sleep: { try await Task.sleep(for: $0) }, now: { Date().timeIntervalSinceReferenceDate }
            ))
        }
    }

    @MainActor
    static func report(
        _ target: Posture?,
        angle: Int? = nil,
        json: Bool,
        timeout: TimeInterval,
        on device: DeviceID,
        backend: any DeviceBackend,
        deviceName: String,
        sleep: @MainActor (Duration) async throws -> Void,
        now: @MainActor () -> TimeInterval
    ) async throws -> String {
        guard let folder = backend as? any PostureControlling else {
            throw CLIError(errorDescription: "posture is not available for \(deviceName) yet.")
        }
        guard let previous = try await folder.posture(of: device) else {
            throw CLIError(errorDescription: DisplayReport.notFoldable(device: deviceName))
        }
        var current = previous
        if let angle {
            current = try await moveHinge(to: angle, from: previous, timeout: timeout, on: device, folder: folder, deviceName: deviceName, sleep: sleep, now: now)
        } else if let target, target != previous {
            let before = try? await backend.screenInfo(for: device)
            try await folder.requestPosture(target, on: device)
            let outcome = try await StateWait.run(
                target: target,
                timeout: timeout,
                read: { try await folder.posture(of: device) },
                request: { try await folder.requestPosture(target, on: device) },
                sleep: sleep,
                now: now
            )
            guard outcome == .reached else {
                throw CLIError(errorDescription: timeoutMessage(target: target, timeout: timeout, platform: device.platform, device: deviceName))
            }
            current = target
            // The device state commits before the panel swap, so wait for the screen to follow it.
            let swapDeadline = now() + min(timeout, 10)
            while now() < swapDeadline {
                let screen = try? await backend.screenInfo(for: device)
                if screen.map({ Self.panelChanged(from: before, to: $0, target: target) }) ?? true { break }
                try await sleep(.milliseconds(250))
            }
        }
        let screen = try? await backend.screenInfo(for: device)
        if json {
            return DisplayReport.postureJSON(current, previous: target == nil && angle == nil ? nil : previous, screen: screen, platform: device.platform)
        }
        return DisplayReport.postureLine(current, screen: screen, platform: device.platform)
    }

    /// Waits for the hinge to read `angle`, then for the posture to settle: which panel shows depends on the way the hinge moved, not only where it stops.
    @MainActor
    static func moveHinge(
        to angle: Int,
        from previous: Posture,
        timeout: TimeInterval,
        on device: DeviceID,
        folder: any PostureControlling,
        deviceName: String,
        sleep: @MainActor (Duration) async throws -> Void,
        now: @MainActor () -> TimeInterval
    ) async throws -> Posture {
        guard let hinge = folder as? any HingeControlling else {
            throw CLIError(errorDescription: "posture --angle is not available for \(deviceName); set a posture by name instead.")
        }
        try await hinge.requestHingeAngle(angle, on: device)
        let outcome = try await StateWait.run(
            target: angle,
            timeout: timeout,
            read: { try await hinge.hingeAngle(of: device).map { Int($0.rounded()) } },
            request: { try await hinge.requestHingeAngle(angle, on: device) },
            sleep: sleep,
            now: now
        )
        guard outcome == .reached else {
            throw CLIError(errorDescription: "The hinge did not reach \(angle) degrees within \(DeviceSettingsReport.number(timeout)) s. Check with `offsider posture --device \(deviceName)`.")
        }
        var current = try await folder.posture(of: device) ?? previous
        let settleDeadline = now() + min(timeout, 5)
        while now() < settleDeadline {
            try await sleep(.milliseconds(500))
            let next = try await folder.posture(of: device) ?? current
            if next == current { break }
            current = next
        }
        return current
    }

    /// Also true once the target's own panel is active, as opening to half-opened keeps the inner display.
    static func panelChanged(from before: UIScreenInfo?, to after: UIScreenInfo, target: Posture) -> Bool {
        guard let before else { return true }
        if let role = after.display?.id, role == (target == .closed ? DisplayRole.cover : DisplayRole.inner).rawValue { return true }
        return before.display?.id != after.display?.id || before.width != after.width || before.height != after.height
    }

    static func timeoutMessage(target: Posture, timeout: TimeInterval, platform: DevicePlatform, device: String) -> String {
        let noun = platform == .ios ? "simulator" : "emulator"
        return "The \(noun) did not report \(target.rawValue) within \(DeviceSettingsReport.number(timeout)) s. Check with `offsider posture --device \(device)`."
    }
}
