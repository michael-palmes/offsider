import ArgumentParser
import Foundation
import OffsiderCore

struct PermissionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission",
        abstract: "Grant, revoke or reset an app's permissions, or list the service names.",
        discussion: """
        Services are one vocabulary for both platforms: `simctl privacy` on iOS simulators, runtime permissions on \
        Android (also by literal android.permission.NAME). Granting a permission already granted changes nothing. \
        reset makes the app ask again on next use. Android stops the app when one of its permissions is revoked. \
        `show` lists an Android app's runtime permissions; iOS simulators offer no read. `services` needs no device.

        Examples:
          offsider permission grant camera notifications --app com.example.app --device DEVICE_ID
          offsider permission reset all --app com.example.app --device DEVICE_ID
          offsider permission show --app com.example.app --device emulator-5554
          offsider permission services --platform ios
        """
    )

    enum Plan: Equatable {
        case change(PermissionAction, [PermissionTarget], app: String, device: String)
        case show(app: String, device: String)
        case services(DevicePlatform?)
    }

    @Argument(help: ArgumentHelp("grant, revoke, reset, show or services.", valueName: "action"))
    var action: String

    @Argument(help: ArgumentHelp("Services such as camera, photos or all; on Android also android.permission.NAME.", valueName: "service"))
    var services: [String] = []

    @Option(name: .customLong("app"), help: ArgumentHelp("The app's bundle ID or Android package (required except for services).", valueName: "id"))
    var app: String?

    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices` (default OFFSIDER_DEVICE; required except for services).", valueName: "id"))
    var explicitDevice: String?

    /// `services` needs no device, so only it ignores `OFFSIDER_DEVICE`.
    var device: String? {
        isServices ? explicitDevice : DeviceDefault.resolve(explicit: explicitDevice)?.id
    }

    private var isServices: Bool { action.trimmingCharacters(in: .whitespaces).lowercased() == "services" }

    @Option(name: .customLong("platform"), help: ArgumentHelp("For services: list only what this platform offers.", valueName: "ios|android"))
    var platform: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var lock: WaitLockOption

    func validate() throws {
        _ = try plan()
    }

    func plan() throws -> Plan {
        if let device {
            try CLIError.refuseOnPhone(device, command: "permission", alternative: "Change the app's access in Settings on the device, or use an iOS simulator.")
        }
        let name = action.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "services" {
            guard services.isEmpty else { throw ValidationError("permission services takes no service names.") }
            guard let platform else { return .services(nil) }
            guard let parsed = DevicePlatform(rawValue: platform.lowercased()) else {
                throw ValidationError("--platform takes ios or android; got \(platform).")
            }
            return .services(parsed)
        }
        guard name == "show" || PermissionAction(rawValue: name) != nil else {
            throw ValidationError("Unknown action '\(action)'. Use grant, revoke, reset, show or services.")
        }
        if platform != nil { throw ValidationError("--platform is only for permission services.") }
        guard let device, !device.isEmpty else { throw ValidationError("permission \(name) needs --device or OFFSIDER_DEVICE.") }
        guard let app else {
            throw ValidationError("permission \(name) needs --app with the bundle ID or package; Offsider never changes every app's permissions at once.")
        }
        let appID: String
        do {
            appID = try ExpoDevClient.validate(appID: app)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        let devicePlatform = DeviceIDClassifier.classify(device).platform
        if name == "show" {
            guard services.isEmpty else { throw ValidationError("permission show takes no service names.") }
            if devicePlatform == .ios {
                throw ValidationError("permission show is Android only: iOS simulators offer no way to read privacy settings.")
            }
            return .show(app: appID, device: device)
        }
        guard !services.isEmpty else {
            throw ValidationError("Name at least one service, for example camera or all. Run `offsider permission services` to list them.")
        }
        do {
            let targets = try services.map { try PermissionTarget.parse($0, platform: devicePlatform) }
            return .change(PermissionAction(rawValue: name)!, targets, app: appID, device: device)
        } catch let error as DeviceSettingsError {
            throw ValidationError(error.message)
        }
    }

    func run() async throws {
        let plan = try plan()
        if case .services(let platform) = plan {
            print(json ? DeviceStateReport.services(Self.services(platform)) : Self.servicesTable(platform))
            return
        }
        let logger = OffsiderLogger()
        let isChange = if case .change = plan { true } else { false }
        let route = try await DeviceRouter.routeForInput(device ?? "", logger: logger, locking: isChange)
        try await route.backend.prepare()
        let id = try await route.backend.requireBootedDevice(route.device).id
        guard let backend = route.backend as? any PermissionControlling else {
            throw CLIError(errorDescription: "permission is not available for \(id.rawValue).", reason: .notSupported)
        }
        print(try await Self.report(plan, json: json, on: id, backend: backend))
    }

    @MainActor
    static func report(_ plan: Plan, json: Bool, on device: DeviceID, backend: any PermissionControlling) async throws -> String {
        switch plan {
        case .services(let platform):
            return json ? DeviceStateReport.services(services(platform)) : servicesTable(platform)
        case .show(let app, _):
            let state = try await backend.permissions(of: app, on: device)
            return json ? DeviceStateReport.permissionShow(state, app: app, on: device) : showLines(state, app: app)
        case .change(let action, let targets, let app, _):
            let change = try await backend.applyPermission(action, targets, app: app, on: device)
            return json ? DeviceStateReport.permissionChange(change, app: app, on: device) : changeLines(change, app: app, platform: device.platform)
        }
    }

    static func services(_ platform: DevicePlatform?) -> [PermissionService] {
        platform.map(PermissionService.offered(on:)) ?? PermissionService.allCases
    }

    static func servicesTable(_ platform: DevicePlatform?) -> String {
        let short: (String) -> String = { $0.replacingOccurrences(of: "android.permission.", with: "") }
        let rows = services(platform).map { service -> [String] in
            let ios = service.iosName ?? "not offered"
            let android = service.androidPermissions.map { $0.isEmpty ? "every runtime permission the app requests" : $0.map(short).joined(separator: ", ") } ?? "not offered"
            switch platform {
            case .ios: return [service.rawValue, ios]
            case .android: return [service.rawValue, android]
            case nil: return [service.rawValue, ios, android]
            }
        }
        let header: [String]
        switch platform {
        case .ios: header = ["Service", "iOS (simctl privacy)"]
        case .android: header = ["Service", "Android runtime permissions"]
        case nil: header = ["Service", "iOS (simctl privacy)", "Android runtime permissions"]
        }
        let table = [header] + rows
        let widths = (0..<header.count).map { column in table.map { $0[column].count }.max() ?? 0 }
        var lines = table.map { row in
            row.enumerated().map { column, cell in column == row.count - 1 ? cell : cell.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0) }.joined()
        }
        if platform != .ios {
            lines.append("On Android, android.permission.NAME also names a single runtime permission.")
        }
        return lines.joined(separator: "\n")
    }

    static func showLines(_ state: AndroidPackagePermissions, app: String) -> String {
        guard !state.runtime.isEmpty else { return "\(app) requests no runtime permissions." }
        let lines = state.runtime.map { permission -> String in
            let services = PermissionService.allCases.filter { $0 != .all && $0.androidPermissions?.contains(permission.name) == true }.map(\.rawValue)
            let suffix = services.isEmpty ? "" : " (\(services.joined(separator: ", ")))"
            return "  \(permission.name): \(permission.granted ? "granted" : "denied")\(suffix)"
        }
        return (["\(app) runtime permissions:"] + lines).joined(separator: "\n")
    }

    static func changeLines(_ change: PermissionChange, app: String, platform: DevicePlatform) -> String {
        let verb: String
        let preposition: String
        switch change.action {
        case .grant: (verb, preposition) = ("Granted", "to")
        case .revoke: (verb, preposition) = ("Revoked", "from")
        case .reset: (verb, preposition) = ("Reset", "for")
        }
        var lines: [String] = []
        for target in change.targets {
            let label: ([PermissionEntry]) -> String = { entries in
                let names = entries.map(\.name)
                return names == [target.target] ? target.target : "\(target.target) (\(names.joined(separator: ", ")))"
            }
            let done = target.permissions.filter { $0.changed != false }
            let same = target.permissions.filter { $0.changed == false }
            if !done.isEmpty {
                let tail = platform == .ios ? " (simctl privacy)" : ""
                let asks = change.action == .reset ? "; it asks again on next use" : ""
                lines.append("\(verb) \(label(done)) \(preposition) \(app)\(tail)\(asks)")
            }
            if !same.isEmpty {
                lines.append("\(label(same)) was already \(change.action == .grant ? "granted" : "denied")")
            }
        }
        if change.appStopped {
            lines.append("Android stopped \(app) because a permission was revoked.")
        }
        lines += change.notes.map { "Note: \($0)" }
        return lines.joined(separator: "\n")
    }
}
