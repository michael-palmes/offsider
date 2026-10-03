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
