import Foundation
import OffsiderCore

extension AndroidBackend: ExpoDevClientPreparing {
    /// Stops the app first: a running app keeps its preferences in memory and would write the old values back.
    public func prepareExpoDevClient(_ appID: String, on id: DeviceID) async throws {
        let serial = id.rawValue
        let package = try ExpoDevClient.validate(appID: appID)
        try await prepare()
        let client = try requireClient()

        let path = try await client.shell(ExpoDevClient.androidPathCommand(package: package), on: serial, label: "pm path")
        guard ExpoDevClient.androidIsInstalled(pmPathOutput: path.stdoutText) else {
            throw ExpoDevClient.androidNotInstalled(package: package, serial: serial)
        }
        let probe = try await client.shell("run-as \(package) true", on: serial, label: "run-as \(package)")
        if let error = ExpoDevClient.androidRunAsError(package: package, output: probe.stdoutText + probe.stderrText) {
            throw error
        }
        let dump = try await client.shell(ExpoDevClient.androidPackageDumpCommand(package: package), on: serial, timeout: .seconds(20), label: "dumpsys package")
        guard ExpoDevClient.androidIsDevClient(packageDump: dump.stdoutText) else {
            throw ExpoDevClient.androidNotDevClient(package: package)
        }
        _ = try await client.shell(ExpoDevClient.androidForceStopCommand(package: package), on: serial, label: "am force-stop")

        let write = try await client.shell(ExpoDevClient.androidWriteCommand(package: package), on: serial, label: "run-as \(package)")
        let output = write.stdoutText + write.stderrText
        if let error = ExpoDevClient.androidRunAsError(package: package, output: output) {
            throw error
        }
        guard write.status == 0, ExpoDevClient.androidPrefsConfirmed(write.stdoutText) else {
            let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(write.status)"
            throw ExpoDevClientError(.writeFailed, "Could not write the Expo dev menu preferences of \(package) on \(serial): \(line)")
        }
    }
}

extension AndroidBackend: ExpoDevClientOpening {
    public func devClientSchemes(_ appID: String, on id: DeviceID) async throws -> [String] {
        let package = try ExpoDevClient.validate(appID: appID)
        try await prepare()
        let client = try requireClient()
        let path = try await client.shell(ExpoDevClient.androidPathCommand(package: package), on: id.rawValue, label: "pm path")
        guard ExpoDevClient.androidIsInstalled(pmPathOutput: path.stdoutText) else {
            throw ExpoDevClient.androidNotInstalled(package: package, serial: id.rawValue)
        }
        let dump = try await client.shell(ExpoDevClient.androidPackageDumpCommand(package: package), on: id.rawValue, timeout: .seconds(20), label: "dumpsys package")
        return ExpoDevClient.schemes(fromPackageDump: dump.stdoutText)
    }

    /// Reads `adb reverse` (read-only); Offsider never sets one.
    public func metroHost(port: Int, on id: DeviceID) async throws -> String {
        try await prepare()
        let listing = (try? await requireClient().deviceQuery("reverse:list-forward", on: id.rawValue)) ?? ""
        let isEmulator: Bool
        if case .androidSerial = DeviceIDClassifier.classify(id.rawValue) { isEmulator = true } else { isEmulator = false }
        guard let host = ExpoDevClient.androidMetroHost(reverseList: listing, port: port, isEmulator: isEmulator) else {
            throw ExpoDevClientError(
                .noRoute,
                "\(id.rawValue) is a phone with no adb reverse for port \(port), so it cannot reach Metro on this Mac. Run `adb -s \(id.rawValue) reverse tcp:\(port) tcp:\(port)` yourself, then try again; Offsider never sets one."
            )
        }
        return host
    }

    public func openURL(_ url: String, appID: String, on id: DeviceID) async throws {
        let package = try ExpoDevClient.validate(appID: appID)
        try await prepare()
        let result = try await requireClient().shell(ExpoDevClient.androidOpenCommand(url: url, package: package), on: id.rawValue, timeout: .seconds(30), label: "am start")
        guard result.status == 0, !result.stdoutText.contains("Error:") else {
            let line = (result.stdoutText + result.stderrText).split(whereSeparator: \.isNewline).first { $0.contains("Error") }.map(String.init) ?? "exit status \(result.status)"
            throw ExpoDevClientError(.writeFailed, "Could not open the dev client link in \(package) on \(id.rawValue): \(line)")
        }
    }
}

extension AndroidBackend: ReactNativeDevMenuOpening {
    /// KEYCODE_MENU opens a debug build's dev menu.
    public func openDevMenu(_ id: DeviceID) async throws {
        try await prepare()
        let result = try await requireClient().shell("input keyevent 82", on: id.rawValue, label: "input keyevent 82")
        guard result.status == 0 else {
            throw AndroidError.inputFailed(serial: id.rawValue, detail: "`input keyevent 82` exited \(result.status)")
        }
    }
}
