import ArgumentParser
import Foundation
import OffsiderCore

struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "displays",
        abstract: "List the device's built-in displays, which one is active, and a foldable's posture.",
        discussion: """
        A device with one display lists `main`. A foldable lists `cover` and `inner`, with the active one marked; \
        describe-ui, tap and the other input commands use the active display. Sizes are points (dp on Android), \
        the active display's in its current orientation. ROTATION is degrees anticlockwise from the display's \
        natural orientation, or - when the device does not say.

        Examples:
          offsider displays --device DEVICE_ID
          offsider displays --device DEVICE_ID --json
        """
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: ReadDeviceOption

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        try await route.backend.prepare()
        let device = try await route.backend.requireBootedDevice(route.device).id
        let console = Console.current
        let list = try await console.progress("Reading the displays") { try await Self.list(on: device, backend: route.backend, deviceName: deviceOption.id) }
        if json {
            console.data(DisplayReport.json(list) + "\n")
        } else {
            console.show(DisplayReport.page(list, platform: device.platform))
        }
    }

    @MainActor
    static func report(json: Bool, on device: DeviceID, backend: any DeviceBackend, deviceName: String) async throws -> String {
        let list = try await list(on: device, backend: backend, deviceName: deviceName)
        return json ? DisplayReport.json(list) : DisplayReport.table(list, platform: device.platform)
    }

    @MainActor
    static func list(on device: DeviceID, backend: any DeviceBackend, deviceName: String) async throws -> DisplayList {
        guard let displays = backend as? any DisplayControlling else {
            throw CLIError(errorDescription: "displays is not available for \(deviceName) yet.", reason: .notSupported)
        }
        return try await displays.displays(of: device)
    }
}
