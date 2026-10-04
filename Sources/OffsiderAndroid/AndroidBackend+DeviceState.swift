import Foundation
import OffsiderCore

extension AndroidBackend: PermissionControlling {
    public func permissions(of app: String, on id: DeviceID) async throws -> AndroidPackagePermissions {
        let script = AndroidPermissionPlan.readScript(package: app)
        let result = try await requireClient().shell(script, on: id.rawValue, timeout: .seconds(20), label: "dumpsys package")
        if result.stdoutText.contains("Unable to find package") || (result.status != 0 && result.stderrText.contains("Unable to find package")) {
            throw AndroidError.appNotInstalled(app, serial: id.rawValue)
        }
        guard result.status == 0, result.stdoutText.contains("Package [\(app)]") else {
            if result.status == 0 { throw AndroidError.appNotInstalled(app, serial: id.rawValue) }
            throw AndroidError.adbCommandFailed(serial: id.rawValue, command: script, detail: Self.firstLine(result.stderrText, status: result.status))
        }
        return AndroidPackagePermissions.parse(dumpsysPackage: result.stdoutText)
    }

    /// One read and at most one script; nothing runs when every permission is already in place.
    public func applyPermission(_ action: PermissionAction, _ targets: [PermissionTarget], app: String, on id: DeviceID) async throws -> PermissionChange {
        try await prepare()
        let state = try await permissions(of: app, on: id)
        let plan: AndroidPermissionPlan
        do {
            plan = try AndroidPermissionPlan.make(action, targets, package: app, state: state)
        } catch let error as DeviceSettingsError {
            throw AndroidError(.notSupported, error.message)
        }
        if let script = plan.script {
            _ = try await settingsShell(script, on: id.rawValue, timeout: .seconds(30))
        }
        return plan.change
    }

    static func firstLine(_ text: String, status: Int32) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(status)"
    }
}

extension AndroidBackend: StatusBarControlling {
    public func statusBar(on id: DeviceID) async throws -> StatusBarReading {
        let output = try await settingsShell(StatusBarOverride.androidShowScript, on: id.rawValue)
        return StatusBarReading(demoAllowed: StatusBarOverride.parseDemoAllowed(output))
    }

    public func overrideStatusBar(_ override: StatusBarOverride, on id: DeviceID) async throws -> StatusBarReading {
        let output = try await settingsShell(override.androidEnterScript, on: id.rawValue, timeout: .seconds(30))
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return StatusBarReading(demoAllowed: StatusBarOverride.parseDemoAllowed(first))
    }

    public func clearStatusBar(on id: DeviceID) async throws {
        _ = try await settingsShell(StatusBarOverride.androidClearScript, on: id.rawValue)
    }
}

extension AndroidBackend: BiometricControlling {
    public func biometricEnrolled(on id: DeviceID) async throws -> Bool? {
        try requireEmulatorForBiometrics(id.rawValue)
        let output = try await settingsShell("dumpsys fingerprint", on: id.rawValue)
        return BiometricControl.parseAndroidEnrolled(output)
    }

    /// Enrolling needs a screen lock PIN, a security change Offsider does not make; removal is left to Settings.
    public func setBiometricEnrolment(_ enrolled: Bool, on id: DeviceID) async throws {
        let serial = id.rawValue
        try requireEmulatorForBiometrics(serial)
        guard enrolled else {
            throw AndroidError(.notSupported, "unenrol is not supported on Android: remove the fingerprint in Settings > Security.")
        }
        throw AndroidError(
            .notSupported,
            "Enrolling a fingerprint on Android needs a screen lock, which Offsider does not set. Set a screen lock and add a fingerprint in Settings > Security; when it asks for the sensor, run `offsider biometric match --device \(serial)`."
        )
    }

    public func defaultBiometricModality(on id: DeviceID) async throws -> BiometricModality { .finger }

    /// Touches the emulator's sensor with the finger id, then lifts it, through the SDK's adb and the emulator console.
    public func sendBiometric(_ outcome: BiometricOutcome, modality: BiometricModality, fingerID: Int?, on id: DeviceID) async throws -> String {
        let serial = id.rawValue
        try requireEmulatorForBiometrics(serial)
        let finger = fingerID ?? (outcome == .match ? BiometricControl.androidMatchFinger : BiometricControl.androidNoMatchFinger)
        let adb = try await adbExecutable()
        for arguments in [BiometricControl.androidTouchArguments(serial: serial, fingerID: finger), BiometricControl.androidRemoveArguments(serial: serial)] {
            var environment = host.environment
            environment["ADB_MDNS"] = "0"
            let result = try await host.processes.capture(executable: adb.path, arguments: arguments, environment: environment, timeout: 5)
            let output = result.stdout + result.stderr
            if result.status != 0 || output.contains("KO") {
                let detail = output.split(whereSeparator: \.isNewline).first { $0.contains("KO") }.map(String.init) ?? Self.firstLine(output, status: result.status)
                throw AndroidError.adbCommandFailed(serial: serial, command: "adb " + arguments.joined(separator: " "), detail: detail)
            }
        }
        return "finger touch \(finger)"
    }

    private func requireEmulatorForBiometrics(_ serial: String) throws {
        guard case .androidSerial = DeviceIDClassifier.classify(serial) else {
            throw AndroidError.emulatorOnly(
                "Biometric input",
                serial: serial,
                model: phones[serial]?.model,
                alternative: "Use an Android emulator or an iOS simulator for biometric checks."
            )
        }
    }
}
