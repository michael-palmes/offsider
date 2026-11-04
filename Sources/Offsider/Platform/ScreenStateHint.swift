import ArgumentParser
import Foundation
import OffsiderCore

/// After a failure that an off or locked Android screen explains, says so with `offsider wake` as the hint.
/// The failure keeps its reason and exit code, except a front-app refusal: there the screen is the cause, and what Android keeps in front of it says nothing.
enum ScreenStateHint {
    static let reasons: Set<FailureReason> = [.selectorNotFound, .selectorFilteredByType, .targetOffScreen, .noWindow, .notVerified, .conditionNotMet]

    /// One state read, only after these failures on a command that drove one Android device; a probe failure leaves `error` as it was.
    /// On a usable screen, `no_window` with an app in front (one foreground read) is `app_not_responding`.
    /// `wait`, `assert` and `screenshot --compare` have printed their own failure, so they get a `Note:` line on stderr instead.
    @MainActor
    static func annotate(
        _ error: any Error,
        routes: [DeviceRouter.Route],
        store: any UnlockCodeStoring = KeychainUnlockCodeStore(),
        ledger: UnlockAttemptLedger = UnlockAttemptLedger(),
        note: (String) -> Void = { writeNote($0) }
    ) async -> any Error {
        if let reported = error as? ReportedFailure {
            let inner = await annotate(reported.underlying, routes: routes, store: store, ledger: ledger, note: note)
            return inner is ScreenStateFailure ? ReportedFailure(underlying: inner, exitCode: reported.exitCode) : error
        }
        if let exit = error as? ExitCode, exit.rawValue == OffsiderExitCode.unverified.rawValue {
            if let state = await screenState(routes, store: store, ledger: ledger), !state.reading.isUsable {
                note("Note: " + state.sentence)
            }
            return error
        }
        guard let failure = error as? any OffsiderFailure, reasons.contains(failure.reason) || error.isOtherAppInFront,
              let state = await screenState(routes, store: store, ledger: ledger) else {
            return error
        }
        guard state.reading.isUsable else {
            return ScreenStateFailure(underlying: failure, sentence: state.sentence, hint: state.fix.hint, screenIsCause: error.isOtherAppInFront)
        }
        guard failure.reason == .noWindow, let package = await AppNotResponding.frontApp(on: state.route, awake: state.reading) else { return error }
        return AppNotResponding.failure(package: package, route: state.route)
    }

    struct State {
        let route: DeviceRouter.Route
        let reading: AwakeReading
        let fix: Fix
        let sentence: String
    }

    /// The reading, the device named as `wake` names it (one listing when the command read none) and the step that clears the screen.
    @MainActor
    private static func screenState(_ routes: [DeviceRouter.Route], store: any UnlockCodeStoring, ledger: UnlockAttemptLedger) async -> State? {
        guard routes.count == 1, let route = routes.first, route.device.platform == .android,
              let backend = route.backend as? any AwakeControlling,
              let reading = try? await backend.awakeState(on: route.device) else {
            return nil
        }
        let serial = route.device.rawValue
        var listed = backend.listedName(of: route.device)
        if !reading.isUsable, listed == nil, let booted = try? await route.backend.requireBootedDevice(route.device) {
            listed = booted.name
        }
        // An emulator's code is kept under its AVD name, a phone's under its serial.
        var key: String? = serial
        if case .androidSerial = DeviceIDClassifier.classify(serial) { key = listed == serial ? nil : listed }
        let name = DeviceName.android(serial: serial, listed: listed, maker: reading.maker)
        let step = fix(serial: serial, reading: reading, codeKey: key, store: store, ledger: ledger)
        return State(route: route, reading: reading, fix: step, sentence: sentence(name: name, reading: reading, fix: step))
    }

    /// What clears the screen, and the command a hint names.
    struct Fix: Equatable {
        let text: String
        let hint: String?
    }

    /// `wake` lights a dark screen and clears a swipe; a PIN or password needs its saved code typed, or a person, so `wake` alone would only loop.
    static func fix(serial: String, reading: AwakeReading, codeKey: String?, store: any UnlockCodeStoring, ledger: UnlockAttemptLedger) -> Fix {
        let wake = "offsider wake --device \(serial)"
        guard reading.screen == .on, reading.lockScreen == .secure else { return Fix(text: "Run `\(wake)`, then retry.", hint: wake) }
        let key = codeKey ?? serial
        // Attributes only, so the code itself is never read.
        let saved = (try? store.hasCode(for: key)) ?? false
        let report = LockReport(reading, savedCode: saved, lastAttempt: ledger.lastAttempt(key))
        let unlock = "offsider wake --unlock --device \(serial)"
        let hint = reading.credential == "pattern" ? nil : saved && report.blockingAttempt == nil ? unlock : UnlockCodeScreen.setCommand(key)
        return Fix(text: report.unlockHint(deviceID: serial, codeKey: key), hint: hint)
    }

    static func sentence(name: String, reading: AwakeReading, fix: Fix) -> String {
        let state: String
        switch (reading.screen, reading.lockScreen) {
        case (.on, .secure): state = "\(name) is showing its \(reading.credentialName) lock screen"
        case (.on, _): state = "\(name) is showing its lock screen"
        case (.dreaming, _): state = "\(name) is showing a screen saver"
        case (.off, _), (.dozing, _): state = "The screen of \(name) is off"
        }
        return "\(state), so input and screen reads do not reach the app. \(fix.text)"
    }

    static func writeNote(_ line: String) {
        Console.current.notice(notice(line))
    }

    /// The note `annotate` wrote, unchanged for an agent; a person reads its first sentence and the command as a `Try` line.
    static func notice(_ line: String) -> Notice {
        let prefix = "Note: "
        let sentence = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
        let (cause, _) = TerminalText.firstSentence(sentence)
        // The command is the sentence's own last span, so a device name holding backticks never stands in for it.
        let run = "Run `"
        let command = sentence.range(of: run, options: .backwards).flatMap { start in
            sentence[start.upperBound...].firstIndex(of: "`").map { String(sentence[start.upperBound..<$0]) }
        }
        return .note(command == nil ? sentence : cause, agent: sentence, mark: .lock, see: command, label: "Try")
    }
}

struct ScreenStateFailure: LocalizedError, UserFacingError, OffsiderFailure {
    let underlying: any OffsiderFailure
    let sentence: String
    let hint: String?
    var screenIsCause = false

    var reason: FailureReason { screenIsCause ? .screenOff : underlying.reason }
    var failureMessage: String { screenIsCause ? sentence : "\(underlying.failureMessage) \(sentence)" }
    var ask: String? { underlying.ask }
    var candidates: [FailureCandidate] { underlying.candidates }
    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
