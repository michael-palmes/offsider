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
        iPhones without a home button never turn upside down. On Android this turns auto-rotate off \
        (`accelerometer_rotation 0`) and sets `user_rotation`; auto-rotate stays off afterwards.

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
        try await DeviceWatchdog().guarding(bound: timeout, device: deviceOption.id) { try await turn() }
    }

    private func turn() async throws {
        let target = try target()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
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
        guard previous != target else {
            try await report(target, previous: previous, backend: backend, device: device)
            return
        }

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
            throw CLIError(errorDescription: Self.timeoutMessage(target: target, timeout: timeout, platform: device.platform, device: deviceOption.id), reason: .stateNotReached)
        }
        try await report(target, previous: previous, backend: backend, device: device)
    }

    static func timeoutMessage(target: DeviceOrientation, timeout: Double, platform: DevicePlatform, device: String) -> String {
        let seconds = DeviceSettingsReport.number(timeout)
        switch platform {
        case .ios:
            let app = target.isLandscape ? "supports portrait only" : "does not support \(target.rawValue)"
            return "The simulator did not turn to \(target.rawValue) within \(seconds) s. This iOS runtime may ignore the orientation event Offsider sends, or the frontmost app \(app). Check with `offsider orientation --device \(device)`."
        case .android:
            return "The emulator did not turn to \(target.rawValue) within \(seconds) s. The foreground app may lock its orientation. Check with `offsider orientation --device \(device)`."
        }
    }

    private func report(_ current: DeviceOrientation, previous: DeviceOrientation?, backend: any DeviceBackend, device: DeviceID) async throws {
        let screen = try? await backend.screenInfo(for: device)
        if json {
            print(DeviceSettingsReport.orientation(current, previous: previous, screen: screen))
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
