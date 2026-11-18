import Foundation
import OffsiderCore

extension AdbClient {
    /// One getprop round trip; false when it cannot be read.
    func bootPINPromptShowing(on serial: String) async -> Bool {
        guard let result = try? await shell(BootPINPrompt.script, on: serial, timeout: .seconds(5), label: "getprop ro.crypto.state; getprop vold.decrypt") else { return false }
        return BootPINPrompt.isShowing(result.stdoutText)
    }
}

extension EmulatorBooter {
    /// For `boot`: the emulator waits at full-disk encryption's boot PIN prompt; false when unreadable.
    public func bootPINPromptShowing(serial: String) async -> Bool {
        guard let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else { return false }
        return await AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing).bootPINPromptShowing(on: serial)
    }
}

extension AndroidBackend {
    /// For `lease set`: an emulator waits at its boot PIN prompt; an AVD name is matched by discovery file alone, so a shut-down AVD never starts adb, and a phone is sent nothing.
    public func bootPINPromptShowing(_ id: String) async -> Bool {
        let serial: String
        if case .androidSerial = DeviceIDClassifier.classify(id) {
            serial = id
        } else {
            guard let port = EmulatorDiscovery.live(host: host).first(where: { $0.avdID == id })?.consolePort else { return false }
            serial = "emulator-\(port)"
        }
        guard let client = try? await directory().client, let row = try? await client.devices().first(where: { $0.serial == serial }),
              row.consolePort != nil, row.properties["usb"] == nil else {
            return false
        }
        return await client.bootPINPromptShowing(on: serial)
    }
}
