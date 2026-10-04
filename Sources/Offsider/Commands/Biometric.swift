import ArgumentParser
import Foundation
import OffsiderCore

struct BiometricCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "biometric",
        abstract: "Enrol Face ID or Touch ID, or send a matching or non-matching face or finger.",
        discussion: """
        match and no-match are events: an app must be asking for biometrics when they arrive, and nothing \
        confirms the app saw them, so check the app's screen. iOS simulators: Face ID, or Touch ID on the iPhone SE \
        and iPads other than iPad Pro (override with --modality). Android emulators: the fingerprint sensor through \
        the emulator console; match touches finger 1 and no-match finger 10, which is not enrolled (--finger-id \
        overrides). Enrolling on Android needs a screen lock, so enrol there is manual. Not available on phones.

        Examples:
          offsider biometric enrol --device DEVICE_ID
          offsider biometric match --device DEVICE_ID
          offsider biometric no-match --device emulator-5554
          offsider biometric status --device DEVICE_ID --json
        """
    )

    @Argument(help: ArgumentHelp("enrol, unenrol, match, no-match or status.", valueName: "action"))
    var action: String

    @Option(name: .customLong("modality"), help: ArgumentHelp("face or finger (iOS; default from the device type).", valueName: "face|finger"))
    var modality: String?

    @Option(name: .customLong("finger-id"), help: ArgumentHelp("The finger id to touch (Android match and no-match).", valueName: "n"))
    var fingerID: Int?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        _ = try plan()
    }

    func plan() throws -> (BiometricAction, BiometricModality?) {
        guard let parsed = BiometricAction.parse(action) else {
            throw ValidationError("Unknown action '\(action)'. Use enrol, unenrol, match, no-match or status.")
        }
        let platform = DeviceIDClassifier.classify(deviceOption.id).platform
        if let fingerID {
            if platform == .ios { throw ValidationError("--finger-id is Android only; on iOS use --modality.") }
            guard parsed == .match || parsed == .noMatch else { throw ValidationError("--finger-id goes with match or no-match.") }
            guard (0...100).contains(fingerID) else { throw ValidationError("--finger-id takes 0 to 100; got \(fingerID).") }
        }
        guard let modality else { return (parsed, nil) }
        if platform == .android { throw ValidationError("--modality is iOS only: Android emulators have a fingerprint sensor.") }
        guard let value = BiometricModality(rawValue: modality.lowercased()) else {
            throw ValidationError("--modality takes face or finger; got \(modality).")
        }
        return (parsed, value)
    }

    func run() async throws {
        let (action, modality) = try plan()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger, locking: action != .status)
        try await route.backend.prepare()
        let id = try await route.backend.requireBootedDevice(route.device).id
        guard let backend = route.backend as? any BiometricControlling else {
            throw CLIError(errorDescription: "biometric is not available for \(id.rawValue).", reason: .notSupported)
        }
        let report = try await Self.report(action, modality: modality, fingerID: fingerID, json: json, on: id, backend: backend)
        if let warning = report.warning {
            FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
        }
        print(report.output)
    }

    @MainActor
    static func report(_ action: BiometricAction, modality: BiometricModality?, fingerID: Int?, json: Bool, on device: DeviceID, backend: any BiometricControlling) async throws -> (output: String, warning: String?) {
        let defaultModality = modality == nil ? try await backend.defaultBiometricModality(on: device) : nil
        let modality = modality ?? defaultModality ?? .face
        let name = device.platform == .android ? "Fingerprint" : modality.displayName
        switch action {
        case .enrol, .unenrol:
            let enrolled = action == .enrol
            try await backend.setBiometricEnrolment(enrolled, on: device)
            let output = json
                ? DeviceStateReport.biometric(action, modality: modality, enrolled: enrolled, sent: nil, on: device)
                : "\(name): \(enrolled ? "enrolled" : "not enrolled")"
            return (output, nil)
        case .status:
            let enrolled = try await backend.biometricEnrolled(on: device)
            let output = json
                ? DeviceStateReport.biometric(action, modality: modality, enrolled: enrolled, sent: nil, on: device)
                : "\(name): \(enrolled.map { $0 ? "enrolled" : "not enrolled" } ?? "enrolment unknown")"
            return (output, nil)
        case .match, .noMatch:
            let outcome: BiometricOutcome = action == .match ? .match : .noMatch
            let enrolled = try? await backend.biometricEnrolled(on: device)
            let sent = try await backend.sendBiometric(outcome, modality: modality, fingerID: fingerID, on: device)
            let warning = enrolled == false && device.platform == .ios
                ? "\(name) is not enrolled, so apps see no biometrics. Run `offsider biometric enrol --device \(device.rawValue)` first."
                : nil
            if json {
                return (DeviceStateReport.biometric(action, modality: modality, enrolled: enrolled ?? nil, sent: sent, on: device), warning)
            }
            let what: String
            if device.platform == .android {
                what = "touched the sensor with \(sent.replacingOccurrences(of: "finger touch ", with: "finger "))\(outcome == .noMatch ? ", which is not enrolled" : "")"
            } else {
                what = "sent a \(outcome == .match ? "matching" : "non-matching") \(modality == .face ? "face" : "finger")"
            }
            return ("\(name): \(what) (an app must be asking for it)", warning)
        }
    }
}
