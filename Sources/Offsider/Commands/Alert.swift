import ArgumentParser
import Foundation
import OffsiderCore

struct AlertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "alert",
        abstract: "Read or answer the permission prompt the system shows for one app.",
        discussion: """
        For the prompt an app raises over itself: Android's runtime permission dialog, or an iOS alert such as \
        “App” Would Like to Send You Notifications. Only on a simulator, an emulator or a test device; on a phone \
        in personal use the prompt is the user's, and nothing is read or sent. An iPhone or iPad is not reached yet.

        `show` prints the prompt's text and each button, with the one `accept` and `deny` would pick, and changes \
        nothing. `deny` picks the declining button. `accept` picks the granting button with the narrowest grant that \
        lasts: While using the app on Android, never All the time, Only this time or a photo picker. `choose \
        "<label>"` picks the one button with exactly that text. Android buttons and iOS privacy prompts are told \
        apart by their ids, so a device language changes nothing; iOS notifications and location prompts by their \
        English labels, so in another language use `choose`.

        It acts only when the system says the prompt belongs to --app: on Android the app that started the dialog, \
        by name and uid; on an iOS simulator a SpringBoard alert over that app alone, whose title names the app \
        first. Anything else the system drew in front exits 7 \
        (system_prompt_in_front), naming it; no prompt exits 2 (alert_not_shown). A crash dialog, an update prompt, \
        a lock screen and a save-password sheet are never answered.

        `accept` and `choose` are held to the app's guard rules (offsider.guard.json): a `never` rule refuses, an \
        `ask` rule waits for a person at the Mac, and a rule that makes a screen look-only holds too, since the \
        screen beneath a prompt cannot be read. `deny` always passes. The answer outlives the command: reset it \
        with `offsider permission reset`. In an evidence run each answer is a line in the timeline.

        Examples:
          offsider alert show --app com.example.app --device DEVICE_ID
          offsider alert accept --app com.example.app --device DEVICE_ID
          offsider alert choose "Only this time" --app com.example.app --device emulator-5554
        """
    )

    enum Action: String, CaseIterable {
        case show, accept, deny, choose
    }

    @Argument(help: ArgumentHelp("show, accept, deny or choose.", valueName: "action"))
    var action: String

    @Argument(help: ArgumentHelp("For choose: the exact text of one button.", valueName: "label"))
    var label: String?

    @Option(name: .customLong("app"), help: ArgumentHelp("The app the prompt is for: its bundle ID or Android package (required).", valueName: "id"), transform: AppID.parse)
    var app: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    /// How long an answered prompt may take to leave the screen.
    static let leaveWait: TimeInterval = 4
    static let leavePoll: Duration = .milliseconds(250)

    func validate() throws {
        _ = try plan()
    }

    /// What to do with the prompt; nil only reads it.
    func plan() throws -> (app: String, choice: AppPrompt.Choice?) {
        guard let action = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(self.action)'. Use show, accept, deny or choose.")
        }
        guard let app else {
            throw ValidationError("alert \(action.rawValue) needs --app with the bundle ID or package of the app the prompt is for; Offsider never answers whatever is in front.")
        }
        if action != .choose, label != nil { throw ValidationError("Only choose takes a button's text; alert \(action.rawValue) takes none.") }
        switch action {
        case .show: return (app, nil)
        case .accept: return (app, .accept)
        case .deny: return (app, .deny)
        case .choose:
            guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("alert choose needs the exact text of one button, as `offsider alert show` prints it.")
            }
            return (app, .label(label))
        }
    }

    func run() async throws {
        let (app, choice) = try plan()
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        // `show` only reads: an Android tree read locks the device, as `wait` does; an iOS read never does.
        let locking = choice != nil || DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: locking)
        try await Self.requireDevice(route)
        let console = Console.current
        let outcome = try await console.progress(choice == nil ? "Reading the prompt" : "Answering the prompt") {
            try await watchdog.guardingTreeStart(on: route)
            return try await Self.perform(choice, app: app, on: route, watchdog: watchdog)
        }
        let device = route.device
        let text = json ? outcome.jsonLine(device: device) : outcome.textLines.joined(separator: "\n")
        var notices: [Notice] = []
        if outcome.chosen != nil {
            let service = device.isPhysicalAndroidDevice ? "<service>" : "all"
            let undo = "offsider permission reset \(service) --app \(app) --device \(device.rawValue)"
            notices.append(DevicePersonView.lasting("Stays after this command", undo: undo, label: "Reset", agent: "The answer stays after this command; `\(undo)` makes the app ask again."))
        }
        DevicePersonView.emit(text, json: json, person: Self.personBlocks(outcome), notices: notices, console: console)
    }

    /// A simulator, an emulator or a test device a person chose; a phone in personal use is refused before anything is read.
    @MainActor
    static func requireDevice(_ route: DeviceRouter.Route, gate: DevicePolicyGate = .current) throws {
        guard let allowance = route.allowance else { return }
        let device = route.device.rawValue
        guard gate.policy().drivesWhole(allowance) else {
            throw CLIError(
                errorDescription: "\(device) is in personal use, not a test device, and Offsider answers a system prompt only on a simulator, an emulator or a test device, so it read and sent nothing. The prompt is the user's to answer.",
                reason: .personRequired, ask: "Can you answer the prompt on \(PersonAsk.devicePlaceholder)?"
            )
        }
        guard route.backend is any AppPromptReading else {
            let read = "offsider describe-ui --summary --device \(device)"
            throw CLIError(
                errorDescription: "alert does not reach an iPhone or iPad yet. On this test device, read the prompt with `\(read)` and answer it with `offsider tap --label <button> --device \(device)`.",
                reason: .notSupported, hint: read
            )
        }
    }

    /// Reads the prompt for `app`, and with a `choice` answers it: guard first, then one more look at what is in front, then the tap.
    @MainActor
    static func perform(_ choice: AppPrompt.Choice?, app: String, on route: DeviceRouter.Route, watchdog: DeviceWatchdog = DeviceWatchdog(), clock: PollClock = .live) async throws -> AlertReport {
        let device = route.device
        guard let backend = route.backend as? any AppPromptReading else {
            throw CLIError(errorDescription: "alert is not available for \(device.rawValue).", reason: .notSupported)
        }
        try await route.backend.prepare()
        let read: (prompt: AppPrompt, tree: UITree)
        do {
            read = try await watchdog.guardingRead(of: device, extra: DeviceClaims.current.longestWait) { try await backend.appPrompt(for: app, on: device) }
        } catch let refusal as AppPromptRefusal {
            throw failure(refusal, app: app, device: device)
        }
        guard let choice else { return AlertReport(prompt: read.prompt) }
        let button = try Self.button(choice, in: read.prompt, device: device)
        guard read.prompt.frame.contains(button.frame.center) else {
            throw CLIError(
                errorDescription: "The button \(TerminalText.quoted(SelectorText.truncated(button.label, limit: 80))) is not wholly inside the prompt on \(device.rawValue), as on a prompt that scrolls, so a tap could miss it and nothing was sent. Turn the device upright, or answer it by hand.",
                reason: .targetOffScreen
            )
        }
        let recorder = EvidenceRecorder.current
        let token = try recorder.begin(device: device, kind: "alert")
        recorder.update(token) { $0.prompt = SelectorText.truncated(read.prompt.title, limit: 200) }
        if choice != .deny {
            try await AppGuard.check(answering: read.prompt, with: button, in: read.tree, device: device)
        }
        let point = try await watchdog.inputPoints([(x: button.frame.center.x, y: button.frame.center.y)], tree: read.tree, backend: route.backend, device: device)[0]
        guard try await watchdog.guardingInputRead(of: device, { try await backend.stillInFront(read.prompt, on: device) }) else {
            throw CLIError(
                errorDescription: "The prompt for \(app) left the screen on \(device.rawValue) before Offsider answered it, so nothing was sent. Run `offsider alert show --app \(app) --device \(device.rawValue)` to see what is there now.",
                reason: .foregroundChanged, hint: "offsider alert show --app \(app) --device \(device.rawValue)"
            )
        }
        try await route.backend.performTracked(.tapAt(x: point.x, y: point.y), on: device)
        recorder.update(token) { $0.button = SelectorText.truncated(button.label, limit: 80) }
        let next = try await Self.afterAnswer(read.prompt, on: backend, device: device, watchdog: watchdog, clock: clock)
        return AlertReport(prompt: read.prompt, action: choice.word, chosen: button, next: next)
    }

    /// Waits for the answered prompt to leave: nil when none follows, the next prompt when the app asks again, exit 5 when it never leaves.
    @MainActor
    static func afterAnswer(_ answered: AppPrompt, on backend: any AppPromptReading, device: DeviceID, watchdog: DeviceWatchdog = DeviceWatchdog(), clock: PollClock) async throws -> AppPrompt? {
        let deadline = clock.now() + leaveWait
        while true {
            try await clock.sleep(leavePoll)
            do {
                let now = try await watchdog.guardingRead(of: device) { try await backend.appPrompt(for: answered.app, on: device).prompt }
                if now.token != answered.token || now.title != answered.title || now.buttons.map(\.label) != answered.buttons.map(\.label) { return now }
            } catch is AppPromptRefusal {
                return nil
            } catch let error where error is CancellationError {
                throw error
            } catch {
                // A read that fails while the prompt animates away says nothing yet; the answer was sent, so keep looking.
            }
            guard clock.now() < deadline else { break }
        }
        let show = "offsider alert show --app \(answered.app) --device \(device.rawValue)"
        throw CLIError(
            errorDescription: "Offsider tapped the button, but the prompt for \(answered.app) is still on \(device.rawValue) after \(WaitLoop.seconds(leaveWait)). Check it with `\(show)`.",
            reason: .notVerified, hint: show
        )
    }

    static func button(_ choice: AppPrompt.Choice, in prompt: AppPrompt, device: DeviceID) throws -> AppPrompt.Button {
        do {
            return try prompt.button(for: choice)
        } catch let failure as AppPrompt.ChoiceFailure {
            let candidates = prompt.buttons.map { FailureCandidate(id: nil, label: $0.label, role: "button", frame: $0.frame, onScreen: true) }
            let listed = prompt.buttons.map { TerminalText.quoted(SelectorText.truncated($0.label, limit: 80)) }.joined(separator: ", ")
            let choose = "offsider alert choose \"<label>\" --app \(prompt.app) --device \(device.rawValue)"
            switch failure {
            case .noButton(let wanted):
                let what = wanted == .accept ? "grants the narrowest lasting access" : "declines"
                throw CLIError(
                    errorDescription: "Offsider cannot tell which button of this prompt \(what), so it sent nothing. Its buttons are \(listed): pick one with `\(choose)`.",
                    reason: .selectorAmbiguous, hint: choose, candidates: candidates
                )
            case .unknownLabel(let text):
                throw CLIError(
                    errorDescription: "The prompt has no button with the text \(TerminalText.quoted(SelectorText.truncated(text, limit: 80))), so nothing was sent. Its buttons are \(listed).",
                    reason: .selectorNotFound, hint: choose, candidates: candidates
                )
            case .ambiguousLabel(let text):
                throw CLIError(
                    errorDescription: "The prompt has more than one button with the text \(TerminalText.quoted(SelectorText.truncated(text, limit: 80))), so nothing was sent.",
                    reason: .selectorAmbiguous, candidates: candidates
                )
            }
        }
    }

    /// Names what is in front in place of a prompt `alert` may read; nothing was sent.
    static func failure(_ refusal: AppPromptRefusal, app: String, device: DeviceID) -> CLIError {
        let on = "on \(device.rawValue)"
        switch refusal {
        case .notShown(let front):
            let what = front.map { $0 == app ? ": \(app) itself is in front" : ": \(TerminalText.bareOrQuoted($0)) is in front" } ?? ""
            return CLIError(errorDescription: "No permission prompt for \(app) is in front \(on)\(what). Nothing was sent.", reason: .alertNotShown)
        case .otherApp(let requester, let why):
            let hint = requester.flatMap { (try? ExpoDevClient.validate(appID: $0)).map { "offsider alert show --app \($0) --device \(device.rawValue)" } }
            return CLIError(
                errorDescription: "A permission prompt is in front \(on), but \(TerminalText.line(why, cap: 200)), so Offsider cannot say it is \(app)'s and left it. Nothing was sent.",
                reason: .systemPromptInFront, hint: hint
            )
        case .notPermission(let what):
            return CLIError(
                errorDescription: "What is in front \(on) is \(TerminalText.line(what, cap: 200)), not a permission prompt \(app) raised, and alert answers only those. Nothing was sent.",
                reason: .systemPromptInFront
            )
        case .unreadable(let why):
            let read = "offsider describe-ui --summary --device \(device.rawValue)"
            return CLIError(
                errorDescription: "A permission prompt for \(app) is in front \(on), but Offsider does not know its layout (\(TerminalText.line(why, cap: 200))), so it names no button and sent nothing. Read it with `\(read)`.",
                reason: .notSupported, hint: read
            )
        }
    }

    static func personBlocks(_ outcome: AlertReport) -> [Block] {
        let buttons: (AppPrompt) -> [Field] = { prompt in
            prompt.buttons.map { Field($0.role == .other ? "Button" : InputPersonView.sentence($0.role.rawValue), Table.Cell($0.label, untrusted: true)) }
        }
        guard let chosen = outcome.chosen else {
            return [.fields([Field("Prompt", Table.Cell(outcome.prompt.title, untrusted: true, tag: outcome.prompt.app))] + buttons(outcome.prompt))]
        }
        var blocks: [Block] = [.outcome(.done("Answered the prompt", aside: outcome.prompt.app, details: [
            TerminalText.line(outcome.prompt.title, cap: 200), "Chose \(TerminalText.quoted(TerminalText.line(chosen.label, cap: 80)))",
        ]))]
        if let next = outcome.next {
            blocks.append(.fields([Field("Next prompt", Table.Cell(next.title, untrusted: true))] + buttons(next)))
        }
        return blocks
    }
}
