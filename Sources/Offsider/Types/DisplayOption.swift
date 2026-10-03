import ArgumentParser
import OffsiderCore

struct DisplayOption: ParsableArguments {
    @Option(
        name: .customLong("display"),
        help: ArgumentHelp("A display from `offsider displays`: main, cover, inner or external, or its platform ID. Defaults to the active display.", valueName: "id")
    )
    var id: String?

    /// The named display and the device's posture; nil when no `--display` was given.
    @MainActor
    func resolve(on backend: any DeviceBackend, device: DeviceID, deviceName: String) async throws -> (display: DisplayInfo, list: DisplayList)? {
        guard let id else { return nil }
        guard let displays = backend as? any DisplayControlling else {
            throw CLIError(errorDescription: "--display is not available for \(deviceName) yet. Omit it to use the active display.")
        }
        let list = try await displays.displays(of: device)
        do {
            return (try list.resolve(id, device: deviceName), list)
        } catch let error as DeviceSettingsError {
            throw CLIError(errorDescription: error.message)
        }
    }
}
