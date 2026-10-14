import Foundation
import OffsiderCore

extension AndroidBackend {
    /// True when adb lists `serial` with a `usb:` property, as a USB device reporting an emulator's serial does. Reads the host-side device list only.
    public func isUSBRow(serial: String) async throws -> Bool {
        try await directory().client.devices().contains { $0.serial == serial && $0.properties["usb"] != nil }
    }
}

/// Whether a serial names a phone, from the adb server's device list alone; nothing is sent to any device.
public enum AndroidPhoneListing {
    /// True when the adb server lists `serial` as a phone rather than an emulator; false when no server answers. Never starts the server.
    public static func isListedPhone(serial: String, host: AndroidHost) async -> Bool {
        guard let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else { return false }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        return (try? await AndroidDeviceDirectory(client: client, host: host).connectedPhone(serial: serial)) != nil
    }

    /// True when an AVD of exactly this name is defined on this Mac; reads the AVD folder only.
    public static func isDefinedAVD(name: String, host: AndroidHost) -> Bool {
        AVDCatalog(host: host).info(named: name) != nil
    }
}
