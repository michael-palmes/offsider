import ArgumentParser
import Foundation
import OffsiderCore

struct BiometricCommand: AsyncParsableCommand, DeclaresEffect, AuditsAction {
    static let configuration = CommandConfiguration(
        commandName: "biometric",
        abstract: "Enrol or read Face ID, Touch ID or a fingerprint, or send a matching or non-matching face or finger.",
        discussion: """
        match and no-match are events: an app must be asking for biometrics when they arrive, and nothing \
        confirms the app saw them, so check the app's screen. iOS simulators: Face ID, or Touch ID on the iPhone SE \
        and iPads other than iPad Pro (override with --modality). Android emulators: the fingerprint sensor through \
        the emulator console; match touches finger 1 and no-match finger 10, which is not enrolled (--finger-id \
        overrides). Enrolling on Android needs a screen lock, so enrol there is manual. On an allowed Android phone only status \
        works, read only. Not available on iPhones or iPads.

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

    /// `status` sends nothing and reads no tree, so it leaves the tree cache alone.
    var effect: CommandEffect {
        BiometricAction.parse(action) == .status ? .none : .input
    }

    var auditedAction: String? {
        BiometricAction.parse(action)?.rawValue
    }

    func plan() throws -> (BiometricAction, BiometricModality?) {
        try CLIError.refuseOnPhone(deviceOption.id, command: "biometric", alternative: "Authenticate on the device itself, or use an iOS simulator.")
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

    @MainActor
    func run() async throws {
        let (action, modality) = try plan()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger(), locking: false)
        let console = Console.current
        let report = try await Self.perform(action, modality: modality, fingerID: fingerID, json: json, on: route, console: console)
        if let warning = report.warning {
            console.notice(Self.unenrolled(warning, name: report.name, on: report.device))
        }
        DevicePersonView.emit(report.output, json: json, person: report.person, notices: Self.notices(action, on: report.device), console: console)
    }

    /// Everything after routing: the run's line, the phone check and the lock, then the action itself.
    @MainActor
    static func perform(
        _ action: BiometricAction, modality: BiometricModality?, fingerID: Int?, json: Bool, on route: DeviceRouter.Route, console: Console,
        claims: DeviceClaims = .current
    ) async throws -> (output: String, warning: String?, name: String, person: [Block], device: DeviceID) {
        let recorder = EvidenceRecorder.current
        let token = try recorder.begin(device: route.device, kind: "biometric")
        try refuseOnAndroidPhone(action, device: route.device)
        if action != .status {
            try await claims.claim(route.device)
        }
        let labels: [BiometricAction: String] = [.enrol: "Enrolling", .unenrol: "Removing enrolment", .status: "Reading enrolment"]
        return try await console.progress(labels[action] ?? "Sending to the sensor") {
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            guard let backend = route.backend as? any BiometricControlling else {
                throw CLIError(errorDescription: "biometric is not available for \(id.rawValue).", reason: .notSupported)
            }
            let report = try await report(action, modality: modality, fingerID: fingerID, json: json, on: id, backend: backend)
            recorder.update(token) { $0.enrolled = report.enrolled }
            return (report.output, report.warning, report.name, report.person, id)
        }
    }

    /// Only `status` reads a phone; the others would change it or need the emulator console, so nothing is sent.
    static func refuseOnAndroidPhone(_ action: BiometricAction, device: DeviceID) throws {
        guard action != .status, device.isPhysicalAndroidDevice else { return }
        throw CLIError(
            errorDescription: "biometric \(action.rawValue) needs an Android emulator, and \(device.rawValue) is a phone, so nothing was sent. On a phone, `offsider biometric status --device \(device.rawValue)` reads enrolment; use an emulator or an iOS simulator for enrol, match and no-match.",
            reason: .notSupported
        )
    }

    /// The warning before a match on a simulator with nothing enrolled, its words unchanged for an agent.
    static func unenrolled(_ warning: String, name: String, on device: DeviceID) -> Notice {
        .warning("\(name) is not enrolled", agent: warning, try: "offsider biometric enrol --device \(device.rawValue)")
    }

    /// Enrolment outlives the command, so a person reads how to undo it.
    static func notices(_ action: BiometricAction, on device: DeviceID) -> [Notice] {
        guard action == .enrol || action == .unenrol else { return [] }
        let undo = "offsider biometric \(action == .enrol ? "unenrol" : "enrol") --device \(device.rawValue)"
        return [DevicePersonView.lasting("Stays \(action == .enrol ? "enrolled" : "unenrolled") after this command", undo: undo)]
    }

    @MainActor
    static func report(_ action: BiometricAction, modality: BiometricModality?, fingerID: Int?, json: Bool, on device: DeviceID, backend: any BiometricControlling) async throws -> (output: String, warning: String?, name: String, person: [Block], enrolled: Bool?) {
        let defaultModality = modality == nil ? try await backend.defaultBiometricModality(on: device) : nil
        let modality = modality ?? defaultModality ?? .face
        let name = device.platform == .android ? "Fingerprint" : modality.displayName
        func person(enrolled: Bool?, sent: String?) -> [Block] {
            DevicePersonView.biometric(action, name: name, modality: modality, enrolled: enrolled, sent: sent, platform: device.platform)
        }
        switch action {
        case .enrol, .unenrol:
            let enrolled = action == .enrol
            try await backend.setBiometricEnrolment(enrolled, on: device)
            let output = json
                ? DeviceStateReport.biometric(action, modality: modality, enrolled: enrolled, sent: nil, on: device)
                : "\(name): \(enrolled ? "enrolled" : "not enrolled")"
            return (output, nil, name, person(enrolled: enrolled, sent: nil), enrolled)
        case .status:
            let enrolled = try await backend.biometricEnrolled(on: device)
            let output = json
                ? DeviceStateReport.biometric(action, modality: modality, enrolled: enrolled, sent: nil, on: device)
                : "\(name): \(enrolled.map { $0 ? "enrolled" : "not enrolled" } ?? "enrolment unknown")"
            return (output, nil, name, person(enrolled: enrolled, sent: nil), enrolled)
        case .match, .noMatch:
            let outcome: BiometricOutcome = action == .match ? .match : .noMatch
            let enrolled = try? await backend.biometricEnrolled(on: device)
            let sent = try await backend.sendBiometric(outcome, modality: modality, fingerID: fingerID, on: device)
            let warning = enrolled == false && device.platform == .ios
                ? "\(name) is not enrolled, so apps see no biometrics. Run `offsider biometric enrol --device \(device.rawValue)` first."
                : nil
            if json {
                return (DeviceStateReport.biometric(action, modality: modality, enrolled: enrolled ?? nil, sent: sent, on: device), warning, name, [], enrolled ?? nil)
            }
            let what: String
            if device.platform == .android {
                what = "touched the sensor with \(sent.replacingOccurrences(of: "finger touch ", with: "finger "))\(outcome == .noMatch ? ", which is not enrolled" : "")"
            } else {
                what = "sent a \(outcome == .match ? "matching" : "non-matching") \(modality == .face ? "face" : "finger")"
            }
            return ("\(name): \(what) (an app must be asking for it)", warning, name, person(enrolled: enrolled ?? nil, sent: sent), enrolled ?? nil)
        }
    }
}
