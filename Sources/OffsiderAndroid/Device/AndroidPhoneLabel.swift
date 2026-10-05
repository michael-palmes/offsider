import Foundation
import OffsiderCore

/// Names a USB phone for people, such as `Motorola moto g`, where a serial alone says little.
public enum AndroidPhoneLabel {
    /// Reads the maker with one `getprop` when the phone is connected and authorised, else uses the model adb lists.
    /// Nil when no adb server answers or the serial is not a listed phone; it never starts the server.
    public static func label(serial: String, host: AndroidHost) async -> String? {
        guard let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else { return nil }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        guard let phone = try? await AndroidDeviceDirectory(client: client, host: host).connectedPhone(serial: serial) else { return nil }
        guard phone.kind == .usb, phone.state == .device,
              let result = try? await client.shell("getprop ro.product.manufacturer", on: serial, timeout: .seconds(3), label: "getprop ro.product.manufacturer"),
              result.status == 0 else {
            return phone.model
        }
        return DeviceName.label(maker: result.stdoutText, model: phone.model)
    }
}
