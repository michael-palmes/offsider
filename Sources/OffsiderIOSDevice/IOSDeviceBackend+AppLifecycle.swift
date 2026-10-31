import Foundation
import OffsiderCore

/// Each call reaches the device through `devicectl` alone, so no runner or session broker starts; USB is checked first, as for input.
extension IOSDeviceBackend: AppLifecycleControlling {
    public func appInfo(_ app: String, on id: DeviceID) async throws -> AppInfo {
        try await requireApp(app, on: id).info
    }

    public func launchApp(_ app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch {
        try await launch(app, restart: restart, url: nil, on: id)
    }

    public func terminateApp(_ app: String, on id: DeviceID) async throws -> AppStop {
        let installed = try await requireApp(app, on: id)
        switch try await running(installed, on: id) {
        case .unknown:
            throw AppLifecycleError(.failed, "`devicectl` did not say where \(app) is installed on \(id.rawValue), so Offsider cannot find its process and stopped nothing. Restart it with `offsider app launch --restart --app \(app) --device \(id.rawValue)`.")
        case .notRunning:
            return AppStop(app: app, wasRunning: false)
        case .pid(let pid):
            _ = try await devicectl(DevicectlAppProcess.terminateArguments(udid: id.rawValue, pid: pid), label: "device process terminate", on: id, app: app)
            return AppStop(app: app, wasRunning: true)
        }
    }

    /// `devicectl` reports only that it delivered the link, so `linkHandled` stays nil: no reply says a screen took it.
    public func openLink(_ url: String, in app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch {
        try await launch(app, restart: restart, url: try AppLink.validate(url), on: id)
    }

    private func launch(_ app: String, restart: Bool, url: String?, on id: DeviceID) async throws -> AppLaunch {
        let installed = try await requireApp(app, on: id)
        let before: Running = restart ? .notRunning : try await running(installed, on: id)
        let output = try await devicectl(
            DevicectlAppProcess.launchArguments(udid: id.rawValue, bundleID: app, restart: restart, url: url),
            label: "device process launch", on: id, app: app
        )
        let pid = DevicectlAppProcess.launchedPID(Data(output.utf8))
        let start: AppStart?
        switch before {
        case .unknown: start = nil
        case .notRunning: start = .cold
        case .pid(let earlier): start = pid == nil || pid == earlier ? .warm : .cold
        }
        return AppLaunch(app: app, start: start, restarted: restart, pid: pid)
    }

    private func requireApp(_ app: String, on id: DeviceID) async throws -> DevicectlAppProcess.App {
        try await requireWired(id)
        let output = try await devicectl(DevicectlAppProcess.infoArguments(udid: id.rawValue, bundleID: app), label: "device info apps", on: id, app: app)
        let found: DevicectlAppProcess.App?
        do {
            found = try DevicectlAppProcess.app(Data(output.utf8), bundleID: app)
        } catch let error as DevicectlDeviceList.ParseError {
            throw IOSDeviceError.devicectlFailed("device info apps", udid: id.rawValue, detail: error.detail)
        }
        guard let found else {
            throw AppLifecycleError(.notInstalled, "\(app) is not installed on \(id.rawValue). Install it from Xcode, TestFlight or the App Store, then retry.")
        }
        return found
    }

    /// `unknown` when `devicectl` names no bundle location, as a process is matched by that alone.
    private enum Running {
        case pid(Int)
        case notRunning
        case unknown
    }

    private func running(_ app: DevicectlAppProcess.App, on id: DeviceID) async throws -> Running {
        guard let bundleURL = app.bundleURL else { return .unknown }
        let output = try await devicectl(DevicectlAppProcess.processesArguments(udid: id.rawValue), label: "device info processes", on: id, app: app.info.app)
        do {
            return try DevicectlAppProcess.pid(Data(output.utf8), bundleURL: bundleURL).map { .pid($0) } ?? .notRunning
        } catch let error as DevicectlDeviceList.ParseError {
            throw IOSDeviceError.devicectlFailed("device info processes", udid: id.rawValue, detail: error.detail)
        }
    }

    /// A locked device refuses a launch; that is `device_locked`, never a prompt Offsider answers.
    private func devicectl(_ arguments: [String], label: String, on id: DeviceID, app: String) async throws -> String {
        do {
            return try await directory.run(arguments, label: label, udid: id.rawValue, timeout: IOSDeviceDirectory.infoTimeout + 10)
        } catch let error as IOSDeviceError where error.kind == .devicectlFailed && Self.saysLocked(error.message) {
            throw IOSDeviceError(.locked, "\(id.rawValue) is locked, so iOS did not run `devicectl \(label)` for \(app). Unlock it and retry; Offsider never types a passcode. It said: \(TerminalText.line(error.message, cap: 300))")
        }
    }

    /// The word itself: not "blocked", and not a name such as `com.example.locked`.
    static func saysLocked(_ message: String) -> Bool {
        message.range(of: #"(?<![\w.-])(un)?locked(?![\w-])"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
