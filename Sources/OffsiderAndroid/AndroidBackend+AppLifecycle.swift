import Foundation
import OffsiderCore

extension AndroidBackend: AppLifecycleControlling {
    public func appInfo(_ app: String, on id: DeviceID) async throws -> AppInfo {
        let package = try ExpoDevClient.validate(appID: app)
        try await prepare()
        let result = try await requireClient().shell(AndroidAppPackage.infoScript(package: package), on: id.rawValue, timeout: .seconds(20), label: "dumpsys package")
        guard let info = AndroidAppPackage.info(result.stdoutText, package: package) else {
            throw AndroidError.appNotInstalled(package, serial: id.rawValue, adb: adbPath)
        }
        return info
    }

    public func launchApp(_ app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch {
        let package = try ExpoDevClient.validate(appID: app)
        let output = try await lifecycleShell(AndroidAppPackage.launchScript(package: package, restart: restart), package: package, on: id, label: "am start")
        let running = try requireInstalled(output, package: package, on: id)
        if AndroidAppPackage.hasNoLauncher(output) {
            throw AppLifecycleError(.noLauncher, "\(package) on \(id.rawValue) has no launcher activity, so it cannot be launched by itself. Open it with `offsider app open <link> --app \(package)`.")
        }
        let reply = try requireStarted(AndroidAppPackage.startReply(output), package: package, on: id, what: "launch")
        return AppLaunch(
            app: package, start: AndroidAppPackage.start(launchState: reply.launchState, wasRunning: running, restarted: restart),
            restarted: restart, milliseconds: reply.totalTime
        )
    }

    /// `am force-stop` also cancels the app's notifications and alarms, as a person's Force stop does.
    public func terminateApp(_ app: String, on id: DeviceID) async throws -> AppStop {
        let package = try ExpoDevClient.validate(appID: app)
        let output = try await lifecycleShell(AndroidAppPackage.stopScript(package: package), package: package, on: id, label: "am force-stop")
        return AppStop(app: package, wasRunning: try requireInstalled(output, package: package, on: id))
    }

    public func openLink(_ url: String, in app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch {
        let package = try ExpoDevClient.validate(appID: app)
        let link = try AppLink.validate(url)
        let output = try await lifecycleShell(AndroidAppPackage.openScript(url: link, package: package, restart: restart), package: package, on: id, label: "am start")
        let running = try requireInstalled(output, package: package, on: id)
        let reply = AndroidAppPackage.startReply(output)
        if reply.unresolved {
            throw AppLifecycleError(.linkNotHandled, "\(package) on \(id.rawValue) has no screen for this link, so Android opened nothing. Check the link's scheme and host against the app's intent filters.")
        }
        let started = try requireStarted(reply, package: package, on: id, what: "open the link in")
        return AppLaunch(
            app: package, start: AndroidAppPackage.start(launchState: started.launchState, wasRunning: running, restarted: restart),
            restarted: restart, milliseconds: started.totalTime
        )
    }

    private func lifecycleShell(_ script: String, package: String, on id: DeviceID, label: String) async throws -> String {
        try await prepare()
        let result = try await requireClient().shell(script, on: id.rawValue, timeout: .seconds(30), label: label)
        return result.stdoutText + result.stderrText
    }

    /// Whether the app was running before the script stopped or started it.
    private func requireInstalled(_ output: String, package: String, on id: DeviceID) throws -> Bool {
        switch AndroidAppPackage.state(in: output) {
        case .notInstalled: throw AndroidError.appNotInstalled(package, serial: id.rawValue, adb: adbPath)
        case .installed(let running): return running
        case nil: throw AndroidError.adbCommandFailed(serial: id.rawValue, command: "pm path \(package)", detail: Self.firstLine(output))
        }
    }

    private func requireStarted(_ reply: AndroidAppPackage.StartReply, package: String, on id: DeviceID, what: String) throws -> AndroidAppPackage.StartReply {
        guard reply.error == nil, reply.status == "ok" else {
            let detail = reply.error ?? "status \(reply.status ?? "unknown")"
            throw AppLifecycleError(.failed, "Android did not \(what) \(package) on \(id.rawValue): \(TerminalText.line(detail, cap: 300)).")
        }
        return reply
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
    }
}
