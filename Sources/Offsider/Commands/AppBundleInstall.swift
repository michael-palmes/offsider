import Foundation
import OffsiderCore

extension AppTarget {
    /// The iPhone, iPad or simulator backend, for installing a `.app` and removing an app.
    @MainActor
    static func bundles(_ route: DeviceRouter.Route, app: String) throws -> any AppBundleManaging {
        guard let backend = route.backend as? any AppBundleManaging else {
            throw CLIError(errorDescription: "Installing a .app is not available for \(route.device.rawValue).", reason: .notSupported)
        }
        (route.backend as? any AppTargetSelecting)?.selectApp(app, on: route.device)
        return backend
    }
}

/// An App Store or TestFlight copy on a phone in personal use holds a person's data and saved logins, so replacing or removing it waits for a person.
enum AppStoreCopyGate {
    enum Step {
        case install
        case uninstall

        var consequence: String {
            switch self {
            case .install: return "a build installed over it takes over its data and saved logins"
            case .uninstall: return "removing it deletes that data and lets any later build read its saved logins"
            }
        }

        func reason(_ app: String, on name: String) -> String {
            switch self {
            case .install: return "install a development build over the App Store or TestFlight copy of \(app) on \(name)"
            case .uninstall: return "remove the App Store or TestFlight copy of \(app), and its data, from \(name)"
            }
        }
    }

    /// `command` is the whole command a person runs in their own terminal, with nothing to fill in.
    static func confirm(_ copy: InstalledAppCopy, step: Step, route: DeviceRouter.Route, command: String, gate: DevicePolicyGate = .current) async throws {
        guard let allowance = route.allowance, !gate.policy().drivesWhole(allowance), !copy.builtByDeveloper else { return }
        let name = PromptScreen.label(allowance.name)
        guard PersonPresence.terminal() else {
            throw CLIError.personRequired(
                "\(copy.app) on \(allowance.name) (\(allowance.key)) came from the App Store or TestFlight, and \(step.consequence). Nothing was sent."
                    + ErrorAudience.current.personStep(command, agentTail: "; it asks for Touch ID or the password"),
                hint: command
            )
        }
        try await PersonPresence.confirm(reason: step.reason(copy.app, on: name))
    }

    static func installCommand(_ bundle: AppBundle, app: String, device: DeviceID) -> String {
        "offsider app install \(DeviceLeaseRules.shellQuoted(bundle.path)) --app \(app) --device \(device.rawValue)"
    }

    static func uninstallCommand(app: String, device: DeviceID) -> String {
        "offsider app uninstall --app \(app) --device \(device.rawValue)"
    }
}

extension AppInstallCommand {
    /// The bundle is read before routing, so a wrong file is refused without starting any device stack.
    @MainActor
    func installBundle(for destination: AppBundle.Destination) async throws {
        let bundle = try AppBundle.read(path, for: destination)
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppManagementSupport.installTarget(appOption, declared: bundle.bundleID, route: route)
        guard app == bundle.bundleID else { throw AppManagementSupport.mismatch(path, declared: bundle.bundleID, app: app) }
        try AppTarget.requirePinned(app, route: route, command: "install")
        let install = try await Console.current.progress("Installing \(app)") {
            let backend = try AppTarget.bundles(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.installBundle(bundle, as: app, on: id) { copy in
                try await AppStoreCopyGate.confirm(copy, step: .install, route: route, command: AppStoreCopyGate.installCommand(bundle, app: app, device: route.device))
            }
        }
        report(install, on: route.device)
    }
}

extension AppUninstallCommand {
    @MainActor
    func removeBundle() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "uninstall")
        try AppTarget.requirePinned(app, route: route, command: "uninstall")
        let result = try await Console.current.progress("Removing \(app)") {
            let backend = try AppTarget.bundles(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.removeBundle(app, on: id) { copy in
                try await AppStoreCopyGate.confirm(copy, step: .uninstall, route: route, command: AppStoreCopyGate.uninstallCommand(app: app, device: route.device))
            }
        }
        report(result, on: route.device)
    }
}
