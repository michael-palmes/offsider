import ArgumentParser
import Foundation
import OffsiderCore

/// After a failure that an off or locked Android screen explains, says so: same reason and exit code, `offsider wake` as the hint.
enum ScreenStateHint {
    static let reasons: Set<FailureReason> = [.selectorNotFound, .selectorFilteredByType, .targetOffScreen, .noWindow, .notVerified, .conditionNotMet]

    /// One state read, only after these failures on a command that drove one Android device; a probe failure leaves `error` as it was.
    /// `wait`, `assert` and `screenshot --compare` have printed their own failure, so they get a `Note:` line on stderr instead.
    @MainActor
    static func annotate(_ error: any Error, routes: [DeviceRouter.Route], note: (String) -> Void = { writeNote($0) }) async -> any Error {
        if let reported = error as? ReportedFailure {
            let inner = await annotate(reported.underlying, routes: routes, note: note)
            return inner is ScreenStateFailure ? ReportedFailure(underlying: inner, exitCode: reported.exitCode) : error
        }
        if let exit = error as? ExitCode, exit.rawValue == OffsiderExitCode.unverified.rawValue {
            if let (serial, name, reading) = await obstructed(routes) {
                note("Note: " + sentence(serial: serial, name: name, reading: reading))
            }
            return error
        }
        guard let failure = error as? any OffsiderFailure, reasons.contains(failure.reason),
              let (serial, name, reading) = await obstructed(routes) else {
            return error
        }
        return ScreenStateFailure(underlying: failure, device: serial, name: name, reading: reading)
    }

    /// The serial, the device's name from what the command already read (no extra round trip), and the reading.
    @MainActor
    private static func obstructed(_ routes: [DeviceRouter.Route]) async -> (String, String, AwakeReading)? {
        guard routes.count == 1, let route = routes.first, route.device.platform == .android,
              let backend = route.backend as? any AwakeControlling,
              let reading = try? await backend.awakeState(on: route.device), !reading.isUsable else {
            return nil
        }
        let serial = route.device.rawValue
        return (serial, DeviceName.android(serial: serial, listed: backend.listedName(of: route.device), maker: reading.maker), reading)
    }

    static func sentence(serial: String, name: String, reading: AwakeReading) -> String {
        let state: String
        switch (reading.screen, reading.lockScreen) {
        case (.on, .secure): state = "\(name) is showing its \(reading.credentialName) lock screen"
        case (.on, _): state = "\(name) is showing its lock screen"
        case (.dreaming, _): state = "\(name) is showing a screen saver"
        case (.off, _), (.dozing, _): state = "The screen of \(name) is off"
        }
        return "\(state), so input and screen reads do not reach the app. Run `offsider wake --device \(serial)`, then retry."
    }

    static func writeNote(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

struct ScreenStateFailure: LocalizedError, UserFacingError, OffsiderFailure {
    let underlying: any OffsiderFailure
    let device: String
    let name: String
    let reading: AwakeReading

    var reason: FailureReason { underlying.reason }
    var failureMessage: String { "\(underlying.failureMessage) \(ScreenStateHint.sentence(serial: device, name: name, reading: reading))" }
    var hint: String? { "offsider wake --device \(device)" }
    var candidates: [FailureCandidate] { underlying.candidates }
    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
