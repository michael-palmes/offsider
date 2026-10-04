import FBSimulatorControl
import Foundation
import OffsiderCore

extension IOSBackend: PermissionControlling {
    func permissions(of app: String, on id: DeviceID) async throws -> AndroidPackagePermissions {
        throw CLIError(errorDescription: "iOS simulators offer no way to read privacy settings; grant, revoke or reset sets them.", reason: .notSupported)
    }

    /// `simctl privacy` takes one service per call, so several run in turn and the first failure stops the rest.
    func applyPermission(_ action: PermissionAction, _ targets: [PermissionTarget], app: String, on id: DeviceID) async throws -> PermissionChange {
        let services = try targets.map { target -> PermissionService in
            guard case .service(let service) = target, service.iosName != nil else {
                throw CLIError(errorDescription: "\(target.name) is not offered on iOS simulators. Run `offsider permission services --platform ios` to list them.", reason: .notSupported)
            }
            return service
        }
        for service in services {
            try await xcrun(IOSPermissionArguments.arguments(action, service: service, udid: id.rawValue, bundleID: app), "\(action.rawValue) \(service.rawValue) for \(app) on", id)
        }
        return IOSPermissionArguments.change(action, services: services)
    }

    /// Stdout of one `xcrun` call; a non-zero exit is an error quoting the first stderr line and naming the simulator.
    @discardableResult
    func xcrun(_ arguments: [String], _ action: String, _ id: DeviceID) async throws -> String {
        let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: arguments, timeout: 30)
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(result.status)"
            throw CLIError(errorDescription: "Offsider could not \(action) simulator \(id.rawValue): \(detail)")
        }
        return result.stdout
    }
}

extension IOSBackend: StatusBarControlling {
    func statusBar(on id: DeviceID) async throws -> StatusBarReading {
        let output = try await xcrun(StatusBarOverride.iosListArguments(udid: id.rawValue), "read the status bar of", id)
        var overrides: [String: String] = [:]
        for pair in StatusBarOverride.parseIOSList(output) { overrides[pair.key] = pair.value }
        return StatusBarReading(overrides: overrides)
    }

    func overrideStatusBar(_ override: StatusBarOverride, on id: DeviceID) async throws -> StatusBarReading {
        let previous = try await statusBar(on: id)
        try await xcrun(override.iosOverrideArguments(udid: id.rawValue), "override the status bar of", id)
        return previous
    }

    func clearStatusBar(on id: DeviceID) async throws {
        try await xcrun(StatusBarOverride.iosClearArguments(udid: id.rawValue), "clear the status bar of", id)
    }
}

extension IOSBackend: BiometricControlling {
    func biometricEnrolled(on id: DeviceID) async throws -> Bool? {
        let output = try await xcrun(BiometricControl.iosReadEnrolmentArguments(udid: id.rawValue), "read biometric enrolment of", id)
        return DoctorRules.parseNotifyFlag(output).map { $0 != 0 }
    }

    func setBiometricEnrolment(_ enrolled: Bool, on id: DeviceID) async throws {
        for arguments in BiometricControl.iosSetEnrolmentArguments(udid: id.rawValue, enrolled: enrolled) {
            try await xcrun(arguments, "set biometric enrolment of", id)
        }
    }

    func defaultBiometricModality(on id: DeviceID) async throws -> BiometricModality {
        let simulator = try await simulator(for: id)
        return BiometricControl.defaultModality(deviceTypeName: simulator.deviceType.model.rawValue)
    }

    func sendBiometric(_ outcome: BiometricOutcome, modality: BiometricModality, fingerID: Int?, on id: DeviceID) async throws -> String {
        let notification = BiometricControl.notification(outcome, modality: modality)
        try await xcrun(BiometricControl.iosPostArguments(udid: id.rawValue, notification: notification), "send \(modality.displayName) to", id)
        return notification
    }
}
