import ArgumentParser
import Foundation
import OffsiderCore

enum ButtonType: String, CaseIterable, ExpressibleByArgument {
    case applePay = "apple-pay"
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"
    case back = "back"
    case appSwitch = "app-switch"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case menu = "menu"

    var hardwareButton: HardwareButton {
        switch self {
        case .applePay: return .applePay
        case .home: return .home
        case .lock: return .lock
        case .sideButton: return .sideButton
        case .siri: return .siri
        case .back: return .back
        case .appSwitch: return .appSwitch
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .menu: return .menu
        }
    }

    var description: String {
        switch self {
        case .applePay: return "Apple Pay button"
        case .home: return "Home button"
        case .lock: return "Lock/Power button"
        case .sideButton: return "Side button"
        case .siri: return "Siri button"
        case .back: return "Back button"
        case .appSwitch: return "App switch button"
        case .volumeUp: return "Volume up button"
        case .volumeDown: return "Volume down button"
        case .menu: return "Menu button"
        }
    }

    /// What a person's receipt calls it: `Pressed Home`.
    var personName: String {
        switch self {
        case .applePay: return "Apple Pay"
        case .home: return "Home"
        case .lock: return "Lock"
        case .sideButton: return "the side button"
        case .siri: return "Siri"
        case .back: return "Back"
        case .appSwitch: return "App switch"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .menu: return "Menu"
        }
    }

    /// Where the button can be pressed; an iOS simulator has no app switcher button, so app-switch presses Home twice there.
    var platforms: Set<DevicePlatform> {
        self == .appSwitch ? [.ios, .android] : hardwareButton.platforms
    }

    /// Whether a physical iPhone or iPad can press it: it has no Apple Pay button, and its app switcher needs a gesture.
    var isOnIOSDevice: Bool {
        platforms.contains(.ios) && self != .applePay && self != .appSwitch
    }

    /// The buttons an iOS simulator or an Android device has.
    static func names(on platform: DevicePlatform) -> String {
        switch platform {
        case .ios: return "apple-pay, app-switch, home, lock, side-button, siri"
        case .android: return "back, app-switch, home, lock, menu, volume-up, volume-down"
        }
    }

    static let iosDeviceNames = "home, lock, side-button, siri"
}

struct Button: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button on the device.",
        discussion: """
        iOS simulator buttons: apple-pay, app-switch, home, lock, side-button, siri
        iPhone and iPad buttons: home, lock, side-button, siri
        Android buttons: back, app-switch, home, lock (the power key), menu, volume-up, volume-down

        app-switch opens the app switcher: on an iOS simulator it presses Home twice, \(Button.appSwitchGapMilliseconds) ms apart, \
        so it takes no --duration there. A physical iPhone or iPad refuses it. With --verify it is not retried by \
        default, since a second press closes the switcher.

        Examples:
          offsider button home --device DEVICE_ID
          offsider button app-switch --device DEVICE_ID
          offsider button lock --duration 2.0 --device DEVICE_ID
          offsider button back --device emulator-5554
          offsider button menu --device emulator-5554    # opens a React Native debug build's dev menu

        Android home: Offsider checks that the launcher came to the front, sending the HOME intent once when the
        key was ignored, and still sends the key when it cannot read the foreground. --verify reports that check,
        and --verify-timeout sets how long it waits for the launcher (default 2 s). It verifies by the foreground
        activity, so --verify-id and --verify-ignore-text are refused and --retries does not apply.

        iOS simulator home with --verify: Offsider checks what answers at the screen's centre, so it returns as soon \
        as SpringBoard is in front; --verify-id or --verify-ignore-text compare the tree instead.
        """
    )

    @Argument(help: "The button to press.")
    var buttonType: ButtonType

    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds (optional).")
    var duration: Double?

    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    func validate() throws {
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
        let classification = DeviceIDClassifier.classify(deviceOption.id)
        if let platform = classification.platform {
            var physicalIOS = false
            if case .iosDevice = classification { physicalIOS = true }
            try Self.checkAvailability(buttonType, on: platform, device: deviceOption.id, physicalIOS: physicalIOS)
            try Self.checkDuration(buttonType, duration: duration, on: platform)
        }
        if classification.platform == .android, Self.isShortHome(buttonType, duration: duration), verification.verifyID != nil || verification.ignoreText {
            throw ValidationError("button home on Android verifies by the foreground activity (the launcher coming to the front), so it does not take --verify-id or --verify-ignore-text. Use --verify.")
        }
    }

    /// A usage error (exit 64) when the device has no such button.
    static func checkAvailability(_ button: ButtonType, on platform: DevicePlatform, device: String, physicalIOS: Bool = false) throws {
        if platform == .ios, physicalIOS, !button.isOnIOSDevice {
            throw ValidationError(physicalIOSRefusal(button, device: device))
        }
        guard !button.platforms.contains(platform) else { return }
        switch platform {
        case .android:
            throw ValidationError("The \(button.rawValue) button is iOS only, and \(device) is an Android emulator. Android buttons: \(ButtonType.names(on: .android)).")
        case .ios:
            throw ValidationError("The \(button.rawValue) button is Android only, and \(device) is an iOS simulator. iOS buttons: \(ButtonType.names(on: .ios)).")
        }
    }

    private static func physicalIOSRefusal(_ button: ButtonType, device: String) -> String {
        let listed = "iPhone and iPad buttons: \(ButtonType.iosDeviceNames)."
        switch button {
        case .applePay:
            return "The apple-pay button needs an iOS simulator, and \(device) is a physical iPhone or iPad. \(listed)"
        case .appSwitch:
            return "The app-switch button needs an iOS simulator or an Android device, and \(device) is a physical iPhone or iPad. \(listed)"
        default:
            return "The \(button.rawValue) button is Android only, and \(device) is a physical iPhone or iPad. \(listed)"
        }
    }

    /// app-switch on an iOS simulator is two Home presses, which cannot be held.
    static func checkDuration(_ button: ButtonType, duration: Double?, on platform: DevicePlatform) throws {
        guard button == .appSwitch, platform == .ios, duration != nil else { return }
        throw ValidationError("app-switch on an iOS simulator presses Home twice, so it does not take --duration. Leave out --duration.")
    }

    static let appSwitchGapMilliseconds = 180

    /// A second app-switch press closes the switcher the first one opened.
    static func verifyRetries(_ button: ButtonType, _ verification: VerificationOptions) -> Int {
        verification.retries ?? (button == .appSwitch ? 0 : verification.resolvedRetries)
    }

    /// The press as one event: down, the hold and up with --duration; on an iOS simulator app-switch is two Home presses.
    static func pressEvent(_ button: ButtonType, duration: Double?, on platform: DevicePlatform) -> InputEvent {
        if button == .appSwitch, platform == .ios {
            return .composite([.shortButtonPress(.home), .delay(Double(appSwitchGapMilliseconds) / 1000), .shortButtonPress(.home)])
        }
        guard let duration else { return .shortButtonPress(button.hardwareButton) }
        return .composite([
            .button(direction: .down, button: button.hardwareButton),
            .delay(duration),
            .button(direction: .up, button: button.hardwareButton)
        ])
    }

    /// A short Android `home` press checks the foreground activity instead of the tree.
    static func isShortHome(_ button: ButtonType, duration: Double?) -> Bool {
        button == .home && duration == nil
    }

    func run() async throws {
        if Self.isShortHome(buttonType, duration: duration), DeviceIDClassifier.classify(deviceOption.id).platform == .android {
            // With --verify, pressAndroidHome prints the verify report itself.
            try await InputOutput.reporting(command: "button", target: buttonType.rawValue, json: verification.json && !verification.verify) { _ in
                try await pressAndroidHome()
            }
            return
        }
        guard verification.verify else {
            try await InputOutput.reporting(command: "button", target: buttonType.rawValue, json: verification.json) { _ in
                try await execute(progress: nil)
                Console.current.show(InputPersonView.receipt("Pressed \(buttonType.personName)", aside: duration.map(InputPersonView.held)))
            }
            return
        }
        try await VerifyOutput.reportingFailures(command: "button", target: buttonType.rawValue, options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    /// Prints the verify report: exit 0 once SpringBoard answers at the screen's centre, exit 5 when it never does.
    /// Lines go to `writeOutput` and `writeError` as an agent reads them; without them, through `Console`, which shows a person their own view.
    @MainActor
    static func pressSimulatorHome(
        on backend: any PresentationProbing,
        device: DeviceID,
        centre: UIPoint,
        verification: VerificationOptions,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        processPath: (Int) -> String? = { Int32(exactly: $0).flatMap(ProcessPath.of(pid:)) },
        writeOutput: ((String) -> Void)? = nil,
        writeError: ((String) -> Void)? = nil
    ) async throws {
        let outcome = try await SimulatorHomePress.run(
            isHome: {
                guard let hit = try? await backend.probe(at: centre, on: device), case .ios(let native) = hit.native,
                      let pid = native.pid, let path = processPath(pid) else { return nil }
                return SimulatorHomePress.isSpringBoard(path: path)
            },
            press: { try await backend.performTracked(.shortButtonPress(.home), on: device) },
            sleep: sleep,
            now: now,
            attempts: 1 + verifyRetries(.home, verification),
            window: verification.verifyTimeout ?? SimulatorHomePress.window
        )
        let attempts: Int
        let reached: Bool
        let line: String
        let detail: String
        switch outcome {
        case .reached(let presses):
            (attempts, reached, detail) = (presses, true, "SpringBoard came to the front")
            line = "✓ Home button verified: SpringBoard is in front, attempt \(presses) of \(presses)"
        case .notReached(let presses):
            (attempts, reached, detail) = (presses, false, "SpringBoard did not come to the front")
            line = "✗ Home button not verified: SpringBoard did not come to the front after \(presses) press\(presses == 1 ? "" : "es")."
        case .unreadable(let presses):
            (attempts, reached, detail) = (presses, false, "Could not read what is in front")
            line = "✗ Home button not verified: Offsider sent \(presses) press\(presses == 1 ? "" : "es") but could not read what is in front. Run offsider doctor --device \(device.rawValue)."
        }
        let report = VerifyReport(command: "button", target: "home", dispatched: .yes, verified: reached, attempts: attempts, change: reached ? .activity : .none)
        let console = Console.current
        if verification.json {
            if let writeError { writeError(line) } else { console.data(line + "\n", to: .err) }
            let json = String(decoding: try report.jsonData(), as: UTF8.self)
            if let writeOutput { writeOutput(json) } else { console.data(json + "\n") }
        } else if reached {
            if let writeOutput { writeOutput(line) } else {
                console.show(Page([.person([.outcome(.done("Home button verified", details: [detail]))]), .agent(line + "\n")]))
            }
        } else if let writeError {
            writeError(line)
        } else {
            console.line(line, person: .failed("Home button not verified", details: [detail], try: ["offsider describe-ui --summary --device \(device.rawValue)"]))
        }
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }

    /// Android `home` confirms the launcher came to the front, sending the HOME intent once when the key was ignored.
    @MainActor
    private func pressAndroidHome() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        try await route.backend.prepare()
        guard let backend = route.backend as? any ForegroundReading else {
            try await route.backend.performTracked(.shortButtonPress(.home), on: route.device)
            Console.current.show(InputPersonView.receipt("Pressed Home"))
            return
        }
        let device = route.device
        let run = { try await Console.current.progress("Pressing Home") { try await Self.pressHome(on: backend, device: device, verification: verification) } }
        guard verification.verify else {
            try await run()
            return
        }
        try await VerifyOutput.reportingFailures(command: "button", target: buttonType.rawValue, options: verification) { progress in
            progress.attempts = 1
            try await run()
        }
    }

    /// Without --verify a launcher that never came up is a warning; with it, exit 5 (`not_verified`) and a report with `change: activity`.
    /// Lines go to `writeOutput` and `writeError` as an agent reads them; without them, through `Console`, which shows a person their own view.
    @MainActor
    static func pressHome(
        on backend: any ForegroundReading,
        device: DeviceID,
        verification: VerificationOptions,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        writeOutput: ((String) -> Void)? = nil,
        writeError: ((String) -> Void)? = nil
    ) async throws {
        let outcome = try await HomePress.run(
            read: { try await backend.foreground(on: device) },
            sendKey: { try await backend.performTracked(.shortButtonPress(.home), on: device) },
            sendIntent: { try await backend.startHomeIntent(on: device) },
            sleep: sleep,
            window: verification.verifyTimeout.map { .milliseconds(Int(($0 * 1000).rounded())) } ?? HomePress.window
        )
        let console = Console.current
        // Each line goes to its seam when a test gives one; otherwise a person reads the second argument in its place.
        func out(_ line: String, person: Outcome) {
            if let writeOutput { return writeOutput(line) }
            console.show(Page([.person([.outcome(person)]), .agent(line + "\n")]))
        }
        func err(_ line: String, person: Notice?) {
            if let writeError { return writeError(line) }
            if let person { return console.line(line, person: person) }
            if console.err.profile == .agent { console.data(line + "\n", to: .err) }
        }
        func failed(_ line: String, person: Outcome) {
            if let writeError { return writeError(line) }
            var person = person
            person.commands = ["offsider describe-ui --summary --device \(device.rawValue)"]
            console.line(line, person: person)
        }
        func receipt(_ details: [String] = []) {
            if writeOutput == nil { console.show(InputPersonView.receipt("Pressed Home", details: details)) }
        }
        let launcher = outcome.after?.home ?? "the launcher"
        let top = outcome.after?.top ?? "the app"
        let stillInFront = "\(outcome.after?.top.map { TerminalText.field($0, profile: .person) } ?? "The app") is still in front after the home key and the HOME intent"
        let reached = ["The launcher came to the front"] + (outcome.via == .intent ? ["The home key was ignored, so Offsider sent the HOME intent"] : [])
        let viaIntent = outcome.via == .intent ? " (the home key was ignored, so Offsider sent the HOME intent)" : ""
        let unchecked = outcome.unreadable.map { "the home key was sent, but Offsider could not check that the launcher came to the front (\($0))." }
        let uncheckedShort = outcome.unreadable.map { "Could not check the launcher came to the front (\(TerminalText.field($0, profile: .person)))" }
        guard verification.verify else {
            if let unchecked {
                receipt()
                err("Warning: \(unchecked)", person: .warning(uncheckedShort ?? unchecked))
            } else if outcome.reached {
                receipt(reached)
                if !viaIntent.isEmpty { err("Note: Home button reached \(launcher)\(viaIntent).", person: nil) }
            } else {
                err("Warning: the home key and the HOME intent were sent, but \(top) is still in front.", person: .warning(stillInFront))
            }
            return
        }
        let report = VerifyReport(
            command: "button",
            target: "home",
            dispatched: .yes,
            verified: outcome.reached,
            attempts: 1,
            change: outcome.reached ? .activity : .none,
            note: outcome.via == .intent ? .homeIntent : nil
        )
        let line = outcome.reached
            ? "✓ Home button verified: \(launcher) came to the front\(viaIntent), attempt 1 of 1"
            : unchecked.map { "✗ Home button not verified: \($0)" }
                ?? "✗ Home button not verified: \(top) is still in front after the home key and the HOME intent."
        if verification.json {
            if let writeError { writeError(line) } else { console.data(line + "\n", to: .err) }
            let json = String(decoding: try report.jsonData(), as: UTF8.self)
            if let writeOutput { writeOutput(json) } else { console.data(json + "\n") }
        } else if outcome.reached {
            out(line, person: .done("Home button verified", details: reached))
        } else {
            failed(line, person: .failed("Home button not verified", details: [uncheckedShort ?? stillInFront]))
        }
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        await appOption.apply(to: route)
        try await Console.current.progress("Pressing \(buttonType.personName)") { try await execute(on: route, progress: progress, logger: logger) }
    }

    /// Presses the button on `route`; tests pass a fake backend here.
    @MainActor
    func execute(on route: DeviceRouter.Route, progress: VerifyProgress?, logger: OffsiderLogger) async throws {
        let backend = route.backend
        let device = route.device
        try Self.checkAvailability(buttonType, on: device.platform, device: deviceOption.id, physicalIOS: device.isPhysicalIOSDevice)
        try Self.checkDuration(buttonType, duration: duration, on: device.platform)
        try await backend.prepare()

        logger.info().log("Pressing \(buttonType.description)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let buttonEvent = Self.pressEvent(buttonType, duration: duration, on: device.platform)

        if let progress {
            if Self.isShortHome(buttonType, duration: duration), verification.verifyID == nil, !verification.ignoreText,
               let prober = backend as? any PresentationProbing, let size = try? await backend.screenSize(for: device), size.width > 0, size.height > 0 {
                progress.attempts = 1
                try await Self.pressSimulatorHome(on: prober, device: device, centre: UIPoint(x: size.width / 2, y: size.height / 2), verification: verification)
                return
            }
            let request = VerifyRequest(
                command: "button",
                subject: buttonType.description,
                target: buttonType.rawValue,
                backend: backend,
                device: device,
                options: verification,
                styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: Self.verifyRetries(buttonType, verification)))
            )
            try await VerifyOutput.perform(request, progress: progress) { _, session in
                try await session.perform(buttonEvent)
            }
            return
        }

        try await backend.performTracked(buttonEvent, on: device)

        logger.info().log("\(buttonType.description) press completed successfully")
    }
}
