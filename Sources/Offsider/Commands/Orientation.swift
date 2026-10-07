import ArgumentParser
import Foundation
import OffsiderCore

struct OrientationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orientation",
        abstract: "Read or set the device orientation, waiting until the device has turned.",
        discussion: """
        Orientations: portrait, landscape-left, landscape-right, portrait-upside-down, named after how the device \
        is turned, as Maestro and devicectl name them: landscape-left is turned 90 degrees anticlockwise, with the \
        home edge on the right (UIKit calls that interface orientation landscape-right). --rotation 0, 90, 180 or 270 \
        gives the same turns in degrees anticlockwise from the display's natural orientation; landscape-left is 90. \
        Without a value, prints the current one.
        iOS reports the frontmost app's orientation, so a portrait-only app or the home screen stays portrait, and \
        iPhones without a home button never turn upside down. On Android, Offsider turns auto-rotate off while the \
        device is turned and restores it on `orientation portrait`: the first turn in a boot, portrait included, \
        records auto-rotate and `user_rotation`, and portrait writes auto-rotate back and forgets the record. When \
        auto-rotate cannot be read or recorded, it fails before turning.

        Examples:
          offsider orientation --device DEVICE_ID
          offsider orientation landscape-left --device DEVICE_ID
          offsider orientation --rotation 90 --device DEVICE_ID
          offsider orientation portrait --timeout 10 --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The orientation to turn to; omit to read the current one.", valueName: "orientation"))
    var value: String?

    @Option(help: ArgumentHelp("The orientation as degrees anticlockwise from the display's natural orientation: 0, 90, 180 or 270.", valueName: "degrees"))
    var rotation: Int?

    @Option(help: ArgumentHelp("Seconds to wait for the turn, from 0.5 to 60.", valueName: "seconds"))
    var timeout: Double = 5

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        _ = try target()
        guard (0.5...60).contains(timeout) else {
            throw ValidationError("--timeout must be from 0.5 to 60 seconds; got \(DeviceSettingsReport.number(timeout)).")
        }
    }

    func target() throws -> DeviceOrientation? {
        if let rotation {
            guard value == nil else {
                throw ValidationError("Give an orientation or --rotation, not both.")
            }
            guard let orientation = DeviceOrientation(rotationDegrees: rotation) else {
                throw ValidationError("--rotation takes 0, 90, 180 or 270; got \(rotation).")
            }
            return orientation
        }
        guard let value else { return nil }
        guard let orientation = DeviceOrientation(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased()) else {
            let names = DeviceOrientation.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown orientation '\(value)'. Use one of: \(names).")
        }
        return orientation
    }

    func run() async throws {
        let target = try target()
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: target != nil)
        try await watchdog.guarding(bound: timeout, device: deviceOption.id) { try await turn(target, on: route, logger: logger) }
    }

    @MainActor
    private func turn(_ target: DeviceOrientation?, on route: DeviceRouter.Route, logger: OffsiderLogger) async throws {
        let backend = route.backend
        try await backend.prepare()
        let device = try await backend.requireBootedDevice(route.device).id
        guard let turner = backend as? any OrientationControlling else {
            throw CLIError(errorDescription: "orientation is not available for \(deviceOption.id).", reason: .notSupported)
        }

        let previous = try await turner.orientation(of: device)
        guard let target else {
            guard let previous else {
                throw CLIError(errorDescription: "Offsider could not read the orientation of \(deviceOption.id). Run `offsider describe-ui --device \(deviceOption.id)` to check the screen size instead.", reason: .orientationUnknown)
            }
            try await report(previous, previous: nil, backend: backend, device: device)
            return
        }
        let turn: () async throws -> Void = {
            try await turner.requestOrientation(target, on: device)
            let outcome = try await StateWait.run(
                target: target,
                timeout: timeout,
                read: { try await turner.orientation(of: device) },
                request: { try await turner.requestOrientation(target, on: device) },
                sleep: { try await Task.sleep(for: $0) },
                now: { Date().timeIntervalSinceReferenceDate }
            )
            guard outcome == .reached else {
                throw CLIError(errorDescription: Self.timeoutMessage(target: target, timeout: timeout, platform: device.platform, device: deviceOption.id, physical: device.isPhysicalIOSDevice), reason: .stateNotReached)
            }
        }
        guard let rotation = backend as? any AutoRotateControlling else {
            if previous != target { try await turn() }
            try await report(target, previous: previous, backend: backend, device: device)
            return
        }
        let marker = await (backend as? any BootMarking)?.bootMarker(for: device)
        let rotationReport = try await Self.turnKeepingAutoRotate(
            target: target,
            turning: previous != target,
            serial: device.rawValue,
            emulatorMarker: marker,
            store: RotationRecordStore(),
            read: { try await rotation.autoRotateState(on: device) },
            writeAccelerometer: { try await rotation.setAccelerometerRotation($0, on: device) },
            turn: turn,
            warn: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        try await report(target, previous: previous, backend: backend, device: device, rotation: rotationReport)
    }

    /// Records auto-rotate for this boot before a turn turns it off and writes it back on portrait; refuses to turn when it cannot record it.
    @MainActor
    static func turnKeepingAutoRotate(
        target: DeviceOrientation,
        turning: Bool,
        serial: String,
        emulatorMarker: String?,
        store: RotationRecordStore,
        read: () async throws -> AutoRotateState?,
        writeAccelerometer: (Int) async throws -> Void,
        turn: () async throws -> Void,
        warn: (String) -> Void
    ) async throws -> RotationReport {
        var before: AutoRotateState?
        var problem = "the settings read back in an unexpected form"
        do {
            before = try await read()
        } catch {
            problem = Self.message(error)
        }
        let marker = emulatorMarker ?? before?.bootID.map { "boot_id \($0)" }
        guard let plan = RotationPlan.make(before: before, target: target, record: store.read(serial), bootMarker: marker, turning: turning) else {
            throw CLIError(
                errorDescription: "Offsider could not read auto-rotate on \(serial) (\(problem)), so it did not turn the device: turning switches auto-rotate off, and Offsider records it first so `orientation portrait` can switch it back. Check the device with `offsider doctor --device \(serial)` and try again.",
                reason: .deviceControlFailed
            )
        }
        if let record = plan.recordToWrite {
            do {
                try store.write(record, serial: serial)
            } catch {
                throw CLIError(
                    errorDescription: "Offsider could not save auto-rotate for \(serial) before turning it (\(Self.message(error))), so it did not turn the device or change auto-rotate.",
                    reason: (error as? any OffsiderFailure)?.reason ?? .commandFailed
                )
            }
        }
        if turning {
            try await turn()
        }
        var restored = false
        if let value = plan.restoreAccelerometer {
            do {
                try await writeAccelerometer(value)
                restored = true
                if plan.deleteRecord { store.remove(serial: serial) }
            } catch {
                warn("Warning: Offsider could not switch auto-rotate back \(value == 0 ? "off" : "on") on \(serial) (\(Self.message(error))). Run `offsider orientation portrait --device \(serial)` to try again.")
            }
        }
        return RotationReport(before: before, now: try? await read(), restored: restored)
    }

    private static func message(_ error: any Error) -> String {
        (error as? any OffsiderFailure)?.failureMessage ?? error.localizedDescription
    }

    static func timeoutMessage(target: DeviceOrientation, timeout: Double, platform: DevicePlatform, device: String, physical: Bool = false) -> String {
        let seconds = DeviceSettingsReport.number(timeout)
        if physical {
            return "The screen did not turn to \(target.rawValue) within \(seconds) s. The device took the new orientation, but its screen follows only while it is awake and unlocked, and only if the frontmost app supports \(target.rawValue). Wake and unlock it, or rotate the device by hand, then check with `offsider orientation --device \(device)`."
        }
        switch platform {
        case .ios:
            let app = target.isLandscape ? "supports portrait only" : "does not support \(target.rawValue)"
            return "The simulator did not turn to \(target.rawValue) within \(seconds) s. This iOS runtime may ignore the orientation event Offsider sends, or the frontmost app \(app). Check with `offsider orientation --device \(device)`."
        case .android:
            return "The emulator did not turn to \(target.rawValue) within \(seconds) s. The foreground app may lock its orientation. Check with `offsider orientation --device \(device)`."
        }
    }

    private func report(_ current: DeviceOrientation, previous: DeviceOrientation?, backend: any DeviceBackend, device: DeviceID, rotation: RotationReport? = nil) async throws {
        let screen = try? await backend.screenInfo(for: device)
        if json {
            print(DeviceSettingsReport.orientation(current, previous: previous, screen: screen, rotation: rotation))
        } else {
            print(Self.line(current, screen: screen, platform: device.platform))
        }
    }

    static func line(_ current: DeviceOrientation, screen: UIScreenInfo?, platform: DevicePlatform) -> String {
        var text = "Orientation: \(current.rawValue)"
        if let screen {
            let unit = platform == .android ? "dp" : "pt"
            text += " (\(DeviceSettingsReport.number(screen.width)) x \(DeviceSettingsReport.number(screen.height)) \(unit))"
        }
        return text
    }
}
