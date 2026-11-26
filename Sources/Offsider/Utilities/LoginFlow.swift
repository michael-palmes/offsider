import Foundation
import OffsiderCore

/// Fills a sign-in form and taps submit once. Turnstile is only read: a widget waiting for a person stops the login.
/// The secret stays in the injected type call.
@MainActor
enum LoginFlow {
    struct Services {
        var readTree: () async throws -> UITree
        var typeText: (_ text: String, _ field: UINode) async throws -> Void
        var tap: (_ point: UIPoint, _ tree: UITree) async throws -> Void
        /// Turnstile's state on the screen `tree` shows. Never taps.
        var readTurnstile: (_ tree: UITree) async throws -> TurnstilePhase
        /// The keyboard's own way out, tried when taps above the keys left it up: its hide key on iOS, Back on Android over docked keys. Sends nothing where neither is safe.
        var hideKeyboard: (_ tree: UITree) async throws -> Void = { _ in }
        var clock: PollClock
        /// The app in front, from a tree already read.
        var foregroundApp: (_ tree: UITree) throws -> String
        /// The bundle id of an iOS process, for the web-content check.
        var bundleForPID: (Int) -> String? = { _ in nil }
        /// The element a touch at a point reaches, as the platform reports it; nil where it cannot say.
        var hitTest: (_ point: UIPoint) async -> UINode? = { _ in nil }
        /// Reads the device's name for the ask, just before a widget stops the login.
        var noteDevice: () async -> Void = {}
        /// The command that watches for a person to finish the widget.
        var turnstileWatch: String = Turnstile.waitCommand()
        /// The device's id, for a refusal's command.
        var device = "<DEVICE_ID>"
        /// A save-password prompt over the app on the screen `tree` shows; nil when none is up.
        var savePrompt: (_ tree: UITree) async -> SavePrompt? = { _ in nil }
        /// The system prompt that made a read fail, on a phone held to one app; nil when the read failed for another reason.
        var promptBehind: (_ error: any Error) async -> SavePrompt? = { _ in nil }
        /// False on a phone in personal use, where a system prompt is the person's to answer.
        var declinesPrompts = true
        /// What the login is doing now, for a run that is stopped from outside; `shown` when it is a wait worth a line.
        var step: (_ what: String, _ shown: Bool) -> Void = { _, _ in }
        /// Passes a request on to the person while the login waits for them.
        var ask: (String) -> Void = { _ in }
        /// Throws while a recording runs on the device, read again before each field `--fill` types into.
        var refuseRecording: () throws -> Void = {}
        /// Password fields the tree cache saw that may now show as plain text.
        var revealedSecrets: () async -> RevealedSecrets? = { nil }
    }

    /// The time `--wait-turnstile` gives a person, counted from the first wait and shared by every wait of one login.
    final class TurnstileWait {
        let seconds: TimeInterval
        private(set) var deadline: TimeInterval?
        private(set) var waited = false

        init(seconds: TimeInterval) {
            self.seconds = seconds
        }

        func remaining(now: TimeInterval) -> TimeInterval {
            guard let deadline else { return seconds }
            return max(0, deadline - now)
        }

        func begin(now: TimeInterval) {
            waited = true
            if deadline == nil { deadline = now + seconds }
        }
    }

    /// How long after the submit tap the screen is first read, and Turnstile once more.
    static let afterSubmitRead: Duration = .milliseconds(750)
    /// How often the screen is read after that, and for how long at most.
    static let afterSubmitInterval: Duration = .milliseconds(500)
    static let afterSubmitWatch: TimeInterval = 5
    /// Reads in a row without the form before it counts as gone: a save-password prompt shows a moment after the form leaves.
    static let formGoneReads = 3
    /// How long a declined prompt gets to leave the screen.
    static let promptLeaves: TimeInterval = 3

    /// Who Offsider last signed in to this app on the device, for the note when no form is in front.
    struct LastSignIn: Equatable {
        var key: String
        var since: Date
        var restarted: Bool?
        /// The id `credential signed-out --device` takes.
        var deviceID: String
    }

    /// `lastSignIn` is read only when no sign-in form is in front. `webLogin` is the saved login's own web-view consent.
    static func run(
        app: String,
        key: String,
        credential: LoginCredential,
        profile: LoginProfile?,
        webLogin: Bool = false,
        timeout: TimeInterval,
        turnstileWait: TurnstileWait? = nil,
        services: Services,
        lastSignIn: () -> LastSignIn? = { nil }
    ) async throws -> LoginReport {
        if let profile, !profile.isFor(app) {
            throw CLIError(
                errorDescription: "offsider.login.json is for \(profile.appIDs.joined(separator: " and ")), and the app in front is \(app). Nothing was typed.",
                reason: .commandFailed
            )
        }
        var tree = try await services.readTree()
        var hits: HitTests
        (tree, hits) = try await revealSubmit(in: tree, profile: profile, services: services)
        let origin = LoginForm.Origin(foreground: app, bundleForPID: services.bundleForPID)
        let form: LoginForm.Found
        do {
            await hits.read(LoginForm.unsettled(in: tree, profile: profile), services: services)
            do {
                form = try detect(in: tree, profile: profile, origin: origin, afterTyping: false, hits: hits, device: services.device)
            } catch {
                await hits.read(LoginForm.hiddenCandidates(in: tree, profile: profile), services: services)
                form = try detect(in: tree, profile: profile, origin: origin, afterTyping: false, hits: hits, device: services.device, lastSignIn: lastSignIn)
            }
        }
        let reachable = hits.reachable
        try refuseLogBoxOverSubmit(form.submit, in: tree, services: services)
        try refuseWebForm(form, app: app, key: key, profile: profile, webLogin: webLogin)
        try requireName(form.identity, what: "email or username")
        try requireName(form.password, what: "password")
        try await requireNoWidget(try await readingPastLoad(tree, services: services), stage: .beforeTyping, wait: turnstileWait, services: services)
        var identityProgress = LoginFieldProgress.notFilled
        var passwordProgress = LoginFieldProgress.notFilled
        var report: LoginReport
        let tapped: UITree
        do {
            services.step("typing the email or username", false)
            try await type(credential.username, into: form.identity, services: services)
            tree = try await readUntil({ LoginForm.match(form.identity, in: $0)?.value == credential.username }, services: services)
            guard let identity = LoginForm.match(form.identity, in: tree) else {
                throw CLIError(
                    errorDescription: "The email or username field left the screen. The password was not typed.",
                    reason: .selectorNotFound
                )
            }
            guard identity.value == credential.username else {
                throw CLIError(
                    errorDescription: "The email or username field did not keep the username that was typed. The password was not typed.",
                    reason: .textNotAccepted
                )
            }
            identityProgress = .filled
            try requireForeground(app, in: tree, services: services, stopped: "the password was not typed")
            tree = try await hideKeysForFocusProof(in: tree, fields: [form.identity, form.password], services: services)
            services.step("typing the password", false)
            try await InputSecrecy.$isSecret.withValue(true) {
                try await type(credential.password, into: form.password, services: services)
            }
            tree = try await readUntil({ LoginForm.match(form.password, in: $0).map { masked($0.value, length: credential.password.count) } == true }, services: services)
            guard let password = LoginForm.match(form.password, in: tree) else {
                throw CLIError(
                    errorDescription: "The password field left the screen. The submit button was not tapped.",
                    reason: .selectorNotFound
                )
            }
            guard masked(password.value, length: credential.password.count) else {
                throw CLIError(
                    errorDescription: "The password field did not show one bullet per character. The submit button was not tapped.",
                    reason: .textNotAccepted
                )
            }
            passwordProgress = .filled
            let submitNow = LoginForm.match(form.submit, in: tree) ?? form.submit
            services.step("closing the keyboard", false)
            tree = try await dismissKeyboard(in: tree, submit: submitNow, shell: form.turnstileShell, fields: [form.identity, form.password], services: services)
            if (try? LoginForm.detect(in: tree, profile: profile, reachable: reachable)) == nil {
                // A read taken while the keyboard animates away can miss the form for a moment.
                tree = try await readUntil({ (try? LoginForm.detect(in: $0, profile: profile, reachable: reachable)) != nil }, services: services)
            }
            // A widget can open over the form after typing, so what a hit-test reached before is checked again.
            var hitsNow = HitTests()
            await hitsNow.read(LoginForm.unsettled(in: tree, profile: profile), services: services)
            if (try? LoginForm.detect(in: tree, profile: profile, reachable: hitsNow.reachable)) == nil {
                await hitsNow.read(LoginForm.hiddenCandidates(in: tree, profile: profile), services: services)
            }
            let filled = try detect(in: tree, profile: profile, afterTyping: true, hits: hitsNow)
            let step = try await settleTurnstile(in: tree, timeout: timeout, wait: turnstileWait, services: services)
            (report, tapped) = try await waitUntilEnabled(
                filled.submit, app: app, key: key, turnstile: step, timeout: timeout, shell: form.turnstileShell, fields: [form.identity, form.password], services: services
            )
        } catch {
            var stopped = LoginReport.stopped(app: app, key: key, identity: identityProgress, password: passwordProgress)
            stopped.waitedForTurnstile = turnstileWait?.waited ?? false
            throw LoginFailure(report: stopped, underlying: error)
        }
        report.waitedForTurnstile = turnstileWait?.waited ?? false
        services.step("watching the screen after submit", false)
        return try await watchAfterSubmit(report, form: form, profile: profile, reachable: reachable, tapped: tapped, timeout: timeout, services: services)
    }

    /// The Turnstile check `login` makes before it reads the saved login, so a box nobody ticked never costs a Touch ID approval.
    static func preflight(_ tree: UITree, wait: TurnstileWait?, services: Services) async throws {
        try await requireNoWidget(try await readingPastLoad(tree, services: services), stage: .beforeTyping, wait: wait, services: services)
    }

    /// Reads the screen after the tap until the form has left, or `afterSubmitWatch` is over: the first read checks where the tap went and Turnstile, every read looks for a save-password prompt.
    private static func watchAfterSubmit(
        _ submitted: LoginReport, form: LoginForm.Found, profile: LoginProfile?, reachable: [UINode], tapped: UITree, timeout: TimeInterval, services: Services
    ) async throws -> LoginReport {
        var report = submitted
        let deadline = services.clock.now() + afterSubmitWatch
        var first = true
        var gone = 0
        try await services.clock.sleep(afterSubmitRead)
        while true {
            let screen: UITree
            do {
                screen = try await services.readTree()
            } catch {
                // A phone held to one app refuses the read under a system window, which is how a save prompt shows there.
                guard let prompt = await services.promptBehind(error) else { return report }
                report.savePrompt = try await settle(prompt, in: nil, report: report, timeout: timeout, services: services)
                return report
            }
            if first {
                first = false
                if let stray = strayTap(before: tapped, after: screen, services: services) {
                    report.submitted = false
                    throw LoginFailure(report: report, underlying: stray)
                }
                if let after = try? await services.readTurnstile(screen) {
                    do {
                        try await requireNoWidget(after, stage: .afterSubmit, wait: nil, services: services)
                    } catch {
                        report.error = ErrorReporter.payload(for: error)
                        throw LoginFailure(report: report, underlying: error)
                    }
                }
            }
            if let prompt = await services.savePrompt(screen) {
                report.formStillInFront = false
                report.savePrompt = try await settle(prompt, in: screen, report: report, timeout: timeout, services: services)
                return report
            }
            let present = await formInFront(form, profile: profile, reachable: reachable, in: screen, services: services)
            report.formStillInFront = present
            gone = present ? 0 : gone + 1
            if gone >= formGoneReads || services.clock.now() >= deadline { return report }
            try await services.clock.sleep(afterSubmitInterval)
        }
    }

    /// The form as `login` found it, still in front: where a hit-test can say, the password field must be what a touch on it reaches, as a page slid aside can stay in the tree. `reachable` holds the fields a hit-test found before typing.
    private static func formInFront(_ form: LoginForm.Found, profile: LoginProfile?, reachable: [UINode], in tree: UITree, services: Services) async -> Bool {
        guard let found = try? LoginForm.detect(in: tree, profile: profile, reachable: reachable), LoginForm.match(form.password, in: tree) != nil else { return false }
        guard let centre = found.password.frame?.center, let hit = await services.hitTest(centre) else { return true }
        return LoginForm.isHit(hit, on: found.password)
    }

    /// Declines a save-password prompt where no person's saved passwords are at stake, tapping its decline control and nothing else; on a phone in personal use it asks the person and reads until the prompt closes or `timeout` is over.
    private static func settle(_ prompt: SavePrompt, in tree: UITree?, report: LoginReport, timeout: TimeInterval, services: Services) async throws -> SavePromptOutcome {
        var why = prompt.savesPassword
            ? "Offsider found no decline control on it, and never taps Save."
            : "Offsider answers only a save-password prompt, and only by declining it."
        if !services.declinesPrompts {
            why = "On a phone in personal use that prompt is the person's to answer, so Offsider tapped nothing."
            await services.noteDevice()
            services.ask(prompt.ask)
            services.step("Waiting up to \(seconds(timeout)) for a person to close \(prompt.summary)", true)
            if await promptClosed(within: timeout, interval: .seconds(1), services: services) { return .closed }
        } else if prompt.savesPassword, let point = prompt.decline, let tree {
            do {
                try await services.tap(point, tree)
                if await promptClosed(within: promptLeaves, interval: afterSubmitInterval, services: services) { return .declined }
                why = "Offsider tapped \(prompt.declineLabel ?? "its decline control") and the prompt stayed."
            } catch {
                why = "Offsider could not decline it: \(OffsiderCommand.message(for: error))"
            }
            await services.noteDevice()
        } else {
            await services.noteDevice()
        }
        var open = report
        open.savePrompt = .open
        let failure = CLIError(
            errorDescription: "The submit button was tapped, and then \(prompt.summary) came up over the app. \(why) Do not run login again: the sign-in went ahead.",
            reason: .systemPromptInFront,
            hint: CommandScope.current.describeHint(device: services.device),
            ask: prompt.ask
        )
        open.error = ErrorReporter.payload(for: failure)
        throw LoginFailure(report: open, underlying: failure)
    }

    /// True once a read shows no prompt; a read the prompt still stops counts as open.
    static func promptClosed(within limit: TimeInterval, interval: Duration, services: Services) async -> Bool {
        let deadline = services.clock.now() + limit
        while true {
            try? await services.clock.sleep(interval)
            if let tree = try? await services.readTree(), await services.savePrompt(tree) == nil { return true }
            if services.clock.now() >= deadline { return false }
        }
    }

    /// The tap reached LogBox's toast or the dev menu's button, not the form: what it opened shows only after it, with that overlay there before it.
    private static func strayTap(before: UITree, after: UITree, services: Services) -> CLIError? {
        if LiveText.logBoxOpened(before: before, after: after), !KnownOverlays.logBoxToasts(in: before.roots, viewport: before.viewport).isEmpty {
            return CLIError(
                errorDescription: "The submit tap opened React Native's LogBox inspector, so it never reached the form. Clear LogBox, then run login again.",
                reason: .targetCovered,
                hint: logBoxDismiss(services)
            )
        }
        if DevMenu.read(before) == nil, DevMenu.read(after) != nil, let viewport = before.viewport, !KnownOverlays.devMenuButtons(in: before.roots, viewport: viewport).isEmpty {
            return CLIError(
                errorDescription: "The submit tap opened the dev menu, so it never reached the form. Close the menu, then run login again.",
                reason: .targetCovered,
                hint: "offsider rn devmenu close --device \(services.device)"
            )
        }
        return nil
    }

    private static func logBoxDismiss(_ services: Services) -> String {
        "offsider rn logbox dismiss --device \(services.device)"
    }

    /// A LogBox toast whose touch area takes submit's point stops the login before anything is typed, as the tap could never reach the form. With keys up the layout can still move, so the submit tap's own check decides.
    private static func refuseLogBoxOverSubmit(_ submit: UINode, in tree: UITree, services: Services) throws {
        guard !keyboardOnScreen(keyboards(in: tree), in: tree) else { return }
        guard let verdict = judging(submit, in: tree)?.judging.verdict(hit: nil), verdict.evidence == .logBoxTouchArea, verdict.isConfident else { return }
        throw CLIError(
            errorDescription: "A LogBox toast takes touches over the submit button, so its tap would open LogBox instead. Nothing was typed. Clear LogBox, then run login again.",
            reason: .targetCovered,
            hint: logBoxDismiss(services),
            coveredBy: CoverReport(verdict)
        )
    }

    /// What a tap on submit would be, and the cover check `tap` makes on it.
    private static func judging(_ submit: UINode, in tree: UITree) -> (resolution: TapResolution, judging: TapCover.Judging)? {
        guard let viewport = tree.viewport,
              let resolution = AccessibilityTargetResolver.resolution(of: submit, roots: tree.roots, viewport: viewport, stack: ScreenStack.build(roots: tree.roots, viewport: viewport)),
              let judging = TapCover.Judging(resolution, in: tree) else { return nil }
        return (resolution, judging)
    }

    /// The point the submit tap goes to, judged as `tap` judges a target: its own, or a part a cover leaves showing where a hit-test finds it. A sure cover refuses, so a tap that cannot reach the form is never reported as made.
    private static func submitPoint(_ submit: UINode, frame: UIFrame, in tree: UITree, services: Services) async throws -> UIPoint {
        guard let viewport = tree.viewport, let (resolution, judging) = judging(submit, in: tree) else { return frame.center }
        if judging.keyboard != nil { throw keyboardError() }
        guard judging.isContested else { return judging.point }
        let hit = tree.platform == .android ? nil : await services.hitTest(judging.point)
        guard let verdict = judging.verdict(hit: hit), verdict.isConfident else { return judging.point }
        if verdict.leavesPartShowing, tree.platform == .ios, let coverFrame = verdict.touchFrame {
            for moved in TapCover.clearParts(of: resolution, beside: coverFrame, in: tree).prefix(TapCover.partTries) {
                guard let part = TapCover.Judging(moved, in: tree, beneath: false), part.keyboard == nil,
                      let answer = await services.hitTest(part.point), LoginForm.isHit(answer, on: submit) else { continue }
                return part.point
            }
        }
        throw submitCovered(verdict, viewport: viewport, platform: tree.platform, services: services)
    }

    private static func submitCovered(_ verdict: CoverVerdict, viewport: UIFrame, platform: DevicePlatform, services: Services) -> CLIError {
        let cover = TapCover.describe(verdict)
        let device = DeviceID(rawValue: services.device, platform: platform)
        switch verdict.evidence {
        case .logBoxTouchArea:
            return CLIError(
                errorDescription: "A LogBox toast takes touches over the submit button, so the submit button was not tapped. Clear LogBox, then run login again.",
                reason: .targetCovered, hint: logBoxDismiss(services), coveredBy: CoverReport(verdict)
            )
        case .devMenuTouchArea:
            return CLIError(
                errorDescription: "The dev menu button is over the submit button, so the submit button was not tapped. Drag it clear, then run login again.",
                reason: .targetCovered, hint: TapCover.dragClear(verdict.cover, viewport: viewport, device: device), coveredBy: CoverReport(verdict)
            )
        default:
            return CLIError(
                errorDescription: "The submit button is under \(cover) (\(TapCover.evidence(verdict.evidence))), so it was not tapped.",
                reason: .targetCovered, hint: CommandScope.current.describeHint(device: services.device), coveredBy: CoverReport(verdict)
            )
        }
    }

    /// Where the login was when it read Turnstile, for the refusal's message.
    enum TurnstileStage {
        case beforeTyping
        case beforeSubmit
        case afterSubmit
    }

    /// How long a web view with no widget is read again: one still loading reads the same for a moment.
    static let widgetLoad: TimeInterval = 2

    /// Turnstile's phase, reading again for at most `widgetLoad` while a web view holds no widget yet.
    private static func readingPastLoad(_ tree: UITree, services: Services) async throws -> TurnstilePhase {
        var phase = try await services.readTurnstile(tree)
        let deadline = services.clock.now() + widgetLoad
        while phase == .noWidget, services.clock.now() < deadline {
            try await services.clock.sleep(.milliseconds(250))
            phase = try await services.readTurnstile(try await services.readTree())
        }
        return phase
    }

    /// A checkbox, a challenge, several checkboxes or a box the tree no longer shows are for a person; absent, passed, checking and a failed run that may retry are not. Past submit, a web view with no widget says nothing new.
    private static func requireNoWidget(_ phase: TurnstilePhase, stage: TurnstileStage, wait: TurnstileWait?, services: Services) async throws {
        switch phase {
        case .absent, .passed, .checking, .failed:
            return
        case .noWidget where stage == .afterSubmit:
            return
        case .ready, .visualChallenge, .ambiguous, .noWidget:
            try await handToPerson(phase, stage: stage, wait: wait, services: services)
        }
    }

    /// Without `--wait-turnstile` the widget stops the login. With it, the person is asked and the widget is read, never tapped, until it passes or leaves; time that runs out stops the login as before.
    private static func handToPerson(_ phase: TurnstilePhase, stage: TurnstileStage, wait: TurnstileWait?, services: Services) async throws {
        await services.noteDevice()
        let refusal = turnstileRequired(phase, stage: stage, watch: services.turnstileWatch)
        guard stage != .afterSubmit, let wait, !Unattended.isOn else { throw refusal }
        let left = wait.remaining(now: services.clock.now())
        guard left > 0 else { throw turnstileNotDone(TurnstileStatus(phase: phase, source: .tree)?.state ?? .checkbox, stage: stage, after: wait.seconds, watch: services.turnstileWatch) }
        wait.begin(now: services.clock.now())
        if let ask = refusal.ask { services.ask(ask) }
        services.step("Waiting up to \(seconds(left)) for a person to finish Turnstile", true)
        let status = try await Turnstile.waitForPerson(seconds: left, clock: services.clock) {
            let phase = try await services.readTurnstile(try await services.readTree())
            guard let status = TurnstileStatus(phase: phase, source: .tree) else {
                throw CLIError(errorDescription: "Several Turnstile checkboxes are on screen.", reason: .selectorAmbiguous)
            }
            return status
        }
        if status.state.awaitsPerson { throw turnstileNotDone(status.state, stage: stage, after: wait.seconds, watch: services.turnstileWatch) }
    }

    /// The refusal once `--wait-turnstile` ran out: what the widget showed at the end, and how long the person had.
    static func turnstileNotDone(_ state: TurnstileStatus.State, stage: TurnstileStage, after waited: TimeInterval, watch: String, audience: ErrorAudience = .current) -> CLIError {
        let what: String
        let ask: String
        switch state {
        case .challenge: (what, ask) = ("The Cloudflare Turnstile challenge was still unsolved", PersonAsk.solveTurnstile)
        case .verifying: (what, ask) = ("Cloudflare Turnstile was still checking", PersonAsk.finishTurnstile)
        case .failed: (what, ask) = ("Cloudflare Turnstile still showed Verification failed", PersonAsk.finishTurnstile)
        case .unknown: (what, ask) = ("A Turnstile web view was still up with no widget Offsider can read", PersonAsk.tickTurnstile)
        default: (what, ask) = ("The Cloudflare Turnstile checkbox was still unticked", PersonAsk.tickTurnstile)
        }
        let outcome = stage == .beforeTyping ? "Nothing was typed." : "The submit button was not tapped."
        let next = audience == .person ? "Finish it on the device, then run login again." : "Offsider never ticks Turnstile. Run login once more after it passes."
        return CLIError(
            errorDescription: "\(what) after \(seconds(waited)) (--wait-turnstile). \(outcome) \(next)",
            reason: .turnstileRequired, hint: audience == .person ? nil : watch, ask: ask
        )
    }

    /// After typing: absent or passed goes on; checking is read again until `timeout`; anything else is for a person.
    private static func settleTurnstile(in tree: UITree, timeout: TimeInterval, wait: TurnstileWait?, services: Services) async throws -> LoginTurnstileStep {
        var deadline = services.clock.now() + timeout
        var phase = try await readingPastLoad(tree, services: services)
        var noted = false
        while true {
            switch phase {
            case .absent:
                return .absent
            case .passed:
                return .passed
            case .ready, .visualChallenge, .ambiguous, .noWidget:
                try await handToPerson(phase, stage: .beforeSubmit, wait: wait, services: services)
                deadline = services.clock.now() + timeout
                phase = try await services.readTurnstile(try await services.readTree())
            case .checking, .failed:
                if services.clock.now() >= deadline {
                    await services.noteDevice()
                    throw phase == .failed ? turnstileFailed(after: timeout, watch: services.turnstileWatch) : turnstileStillChecking(after: timeout, watch: services.turnstileWatch)
                }
                if !noted {
                    noted = true
                    services.step("Waiting up to \(seconds(timeout)) for Turnstile to finish checking", true)
                }
                try await services.clock.sleep(.milliseconds(250))
                phase = try await services.readTurnstile(try await services.readTree())
            }
        }
    }

    static func turnstileStillChecking(after timeout: TimeInterval, watch: String, audience: ErrorAudience = .current) -> CLIError {
        let next = audience == .person ? "Finish it on the device, then run login again." : "Offsider never ticks Turnstile. Run login once more after it passes."
        return CLIError(
            errorDescription: "The Cloudflare Turnstile widget was still checking after \(seconds(timeout)), so the submit button was not tapped. \(next)",
            reason: .turnstileRequired,
            hint: audience == .person ? nil : watch,
            ask: PersonAsk.finishTurnstile
        )
    }

    static func turnstileFailed(after timeout: TimeInterval, watch: String, audience: ErrorAudience = .current) -> CLIError {
        CLIError(
            errorDescription: "Cloudflare Turnstile still showed Verification failed after \(seconds(timeout)), so the submit button was not tapped. A widget set to retry tries again by itself: run login again once it passes. If it stays, reopen the screen and check the app's log.",
            reason: .turnstileRequired,
            hint: audience == .person ? nil : watch,
            ask: PersonAsk.finishTurnstile
        )
    }

    /// An agent gets the ask and the command that watches for the tick; a person at the terminal is the one to tick it.
    static func turnstileRequired(_ phase: TurnstilePhase, stage: TurnstileStage, watch: String = Turnstile.waitCommand(), audience: ErrorAudience = .current) -> CLIError {
        let what: String
        let step: String
        let ask: String
        switch phase {
        case .visualChallenge:
            (what, step, ask) = ("A Cloudflare Turnstile challenge is on screen", "Solve it", PersonAsk.solveTurnstile)
        case .ambiguous(let count):
            (what, step, ask) = ("\(count) Cloudflare Turnstile checkboxes are on screen", "Tick them", PersonAsk.tickTurnstiles)
        case .noWidget:
            (what, step, ask) = ("A Turnstile web view is up with no widget Offsider can read", "Tick the box if one shows", PersonAsk.tickTurnstile)
        default:
            (what, step, ask) = ("A Cloudflare Turnstile checkbox is on screen", "Tick it", PersonAsk.tickTurnstile)
        }
        let person = audience == .person
        let message: String
        if stage == .afterSubmit {
            let next = person ? "\(step) on the device; do not run login again, as submit may have gone through." : "Offsider never ticks Turnstile. Do not run login again: read the screen after it passes."
            message = "The submit button was tapped, and then a Cloudflare Turnstile widget asked for a person. \(next)"
        } else {
            let outcome = stage == .beforeTyping ? "Nothing was typed." : "The submit button was not tapped."
            let next = person ? "\(step) on the device, then run login again." : "Offsider never ticks Turnstile. Run login once more after it passes."
            let noBox = phase == .noWidget ? " If no box shows, it failed to run or runs invisibly: check the app's log for a Turnstile error, and doctor for an old WebView." : ""
            message = "\(what). \(outcome) \(next)\(noBox)"
        }
        return CLIError(errorDescription: message, reason: .turnstileRequired, hint: person ? nil : watch, ask: ask)
    }

    /// Recomputes the app in front from a tree already read. A different app, or none, stops the login.
    static func requireForeground(_ app: String, in tree: UITree, services: Services, stopped: String) throws {
        let now = try? services.foregroundApp(tree)
        guard now != app else { return }
        let front = now.map { "\($0) is in front now" } ?? "The app in front can no longer be read"
        throw CLIError(
            errorDescription: "\(front), not \(app), so \(stopped). Bring \(app) back to the front, then run login again.",
            reason: .foregroundChanged
        )
    }

    /// A password field inside a web view is refused unless both the project file and the saved login opt in.
    private static func refuseWebForm(_ form: LoginForm.Found, app: String, key: String, profile: LoginProfile?, webLogin: Bool) throws {
        guard form.webContainer != nil, !(profile?.webLogin == true && webLogin) else { return }
        let name = key == LoginCredential.defaultAccountKey ? "default" : key
        throw CLIError(
            errorDescription: "The password field is inside a web view; nothing was typed. A person can allow web sign-in for this login with "
                + "`offsider credential describe \(name) --web-login --app \(app)` in their own terminal, together with \"webLogin\": true in offsider.login.json.",
            reason: .appNotAllowed
        )
    }

    /// Only `noForm` reads `lastSignIn`, to name who Offsider last signed in here.
    private static func detect(
        in tree: UITree, profile: LoginProfile?, origin: LoginForm.Origin? = nil, afterTyping: Bool, hits: HitTests = HitTests(), device: String = "<DEVICE_ID>",
        lastSignIn: () -> LastSignIn? = { nil }
    ) throws -> LoginForm.Found {
        do {
            return try LoginForm.detect(in: tree, profile: profile, origin: origin, reachable: hits.reachable, answers: hits.answers)
        } catch let error as LoginFormError {
            let reason: FailureReason = error.kind == .ambiguous ? .selectorAmbiguous : .selectorNotFound
            if afterTyping {
                throw CLIError(
                    errorDescription: "The form changed after typing. The submit button was not tapped.",
                    reason: reason,
                    coveredBy: error.coveredBy
                )
            }
            if let block = LogBoxBlock.hiding(tree, inspector: KnownOverlays.logBoxInspector(in: tree.roots, viewport: tree.viewport), subject: "the form") {
                let blocked = WaitBlockedError(block: block, gone: false)
                throw CLIError(errorDescription: "\(blocked.message) Nothing was typed.", reason: reason, hint: "offsider rn logbox dismiss --device \(device)")
            }
            guard error.kind == .noForm, let last = lastSignIn() else {
                throw CLIError(errorDescription: error.message, reason: reason, coveredBy: error.coveredBy)
            }
            throw CLIError(
                errorDescription: "\(error.message) \(switchNote(last))",
                reason: reason,
                hint: "offsider credential signed-out --device \(last.deviceID)",
                coveredBy: error.coveredBy
            )
        }
    }

    /// A hit-test at a control's own point, as `tap --fail-if-covered` makes, says what a touch there reaches. Each control is read once.
    struct HitTests {
        var answers: [LoginForm.HitAnswer] = []
        var reachable: [UINode] = []

        @MainActor
        mutating func read(_ nodes: [UINode], services: Services) async {
            for node in nodes where !answers.contains(where: { $0.node == node }) {
                guard let frame = node.frame else { continue }
                let hit = await services.hitTest(frame.center)
                answers.append(LoginForm.HitAnswer(node: node, hit: hit))
                if let hit, LoginForm.isHit(hit, on: node) { reachable.append(node) }
            }
        }
    }

    /// Names who Offsider last signed in here, and how to switch users.
    static func switchNote(_ last: LastSignIn) -> String {
        let who = last.key == LoginCredential.defaultAccountKey ? "the default login" : last.key
        let restart = last.restarted == true ? ", before the device restarted" : ""
        return "Offsider last signed in as \(who) here (\(ProcessStamp.timestamp(last.since))\(restart)), so the app may still be signed in. "
            + "To switch users, sign out in the app, run `offsider credential signed-out --device \(last.deviceID)`, then run login again."
    }

    private static func requireName(_ field: UINode, what: String) throws {
        let hasID = field.id?.isEmpty == false
        let hasLabel = field.label?.isEmpty == false
        guard hasID || hasLabel else {
            throw CLIError(
                errorDescription: "The \(what) field has no id or label, so it cannot be typed into. Nothing was typed.",
                reason: .selectorNotFound
            )
        }
    }

    private static func type(_ text: String, into field: UINode, services: Services) async throws {
        try await services.typeText(text, field)
    }

    static func masked(_ value: String?, length: Int) -> Bool {
        guard let value, value.count == length, length > 0 else { return false }
        return value.allSatisfy { $0 == SecureText.bullet }
    }

    /// The keys can be the only nodes below the password, so the submit button is missing until the keyboard goes. A hit-test settles fields only a container holds, as a backdrop must not count as clear; its answers come back while the tree is unchanged.
    private static func revealSubmit(in tree: UITree, profile: LoginProfile?, services: Services) async throws -> (UITree, HitTests) {
        var hits = HitTests()
        if (try? LoginForm.detect(in: tree, profile: profile)) != nil { return (tree, hits) }
        guard keyboardOnScreen(keyboards(in: tree), in: tree) else { return (tree, hits) }
        if !LoginForm.credentialsAreVisible(in: tree, profile: profile) {
            await hits.read(LoginForm.unsettled(in: tree, profile: profile), services: services)
        }
        guard LoginForm.credentialsAreVisible(in: tree, profile: profile, reachable: hits.reachable) else { return (tree, hits) }
        if (try? LoginForm.detect(in: tree, profile: profile, reachable: hits.reachable)) != nil { return (tree, hits) }
        return (try await hideKeys(in: tree, services: services), HitTests())
    }

    /// On an iOS tree that names no focused text field, only a keyboard coming up shows the password tap landed; one already up would prove nothing, and the password would go to the field that still has focus.
    static func hideKeysForFocusProof(in tree: UITree, fields: [UINode], services: Services) async throws -> UITree {
        guard tree.platform == .ios, keyboardOnScreen(keyboards(in: tree), in: tree),
              !tree.roots.flatMap({ $0.flattened() }).contains(where: { $0.state.focused == true && $0.role.isTextInput }) else {
            return tree
        }
        var current = tree
        let gone: (UITree) -> Bool = { !keyboardOnScreen(keyboards(in: $0), in: $0) }
        var tried: [UIPoint] = []
        while tried.count < KeyboardDismiss.attempts, !gone(current) {
            let frames = fields.compactMap { (LoginForm.match($0, in: current) ?? $0).frame }
            guard let point = KeyboardDismiss.points(in: current, fields: frames, tried: tried, limit: 1).first else { break }
            try await services.tap(point, current)
            tried.append(point)
            current = try await readUntil(gone, services: services)
        }
        return current
    }

    private static func hideKeys(in tree: UITree, services: Services) async throws -> UITree {
        var current = tree
        let gone: (UITree) -> Bool = { !keyboardOnScreen(keyboards(in: $0), in: $0) }
        if let point = KeyboardDismiss.point(in: tree) {
            try await services.tap(point, tree)
            current = try await readUntil(gone, services: services)
        }
        if !gone(current) {
            try await services.hideKeyboard(current)
            current = try await readUntil(gone, services: services)
        }
        return current
    }

    static let keyboardSettle: TimeInterval = 1.5

    /// The keys can still be sliding away when the tree is read straight after a dismiss.
    static func readUntil(_ done: (UITree) -> Bool, services: Services) async throws -> UITree {
        let deadline = services.clock.now() + keyboardSettle
        while true {
            let tree = try await services.readTree()
            if done(tree) || services.clock.now() >= deadline { return tree }
            try await services.clock.sleep(.milliseconds(250))
        }
    }

    private static func keyboards(in tree: UITree) -> [UINode] {
        tree.roots.flatMap { $0.flattened() }.filter { $0.role == .keyboard && ($0.frame?.height ?? 0) > 0 }
    }

    /// Up to `KeyboardDismiss.attempts` taps on distinct safe points, reading again after each, until submit is clear.
    private static func dismissKeyboard(in tree: UITree, submit: UINode, shell: UIFrame?, fields: [UINode], services: Services) async throws -> UITree {
        let keyboards = keyboards(in: tree)
        guard !keyboards.isEmpty else { return tree }
        let submitNow = LoginForm.match(submit, in: tree) ?? submit
        // A keyboard whose frame is below the screen is the input assistant's layout, and a hardware keyboard's toolbar is no keys; neither is over the form.
        if !keyboardOnScreen(keyboards, in: tree) || !KeyboardDismiss.showsKeys(in: tree), !covered(tree, submit: submitNow, shell: shell) {
            return tree
        }
        var current = tree
        let clear: (UITree) -> Bool = { !covered($0, submit: LoginForm.match(submit, in: $0) ?? submitNow, shell: shell) }
        var tried: [UIPoint] = []
        while tried.count < KeyboardDismiss.attempts {
            let frames = fields.compactMap { (LoginForm.match($0, in: current) ?? $0).frame }
            guard let point = KeyboardDismiss.points(in: current, fields: frames, tried: tried, limit: 1).first else { break }
            try await services.tap(point, current)
            tried.append(point)
            current = try await readUntil(clear, services: services)
            if clear(current) { return try await readUntilStill(submit, from: current, services: services) }
        }
        try await services.hideKeyboard(current)
        current = try await readUntil(clear, services: services)
        if !clear(current) { throw keyboardError(services: services) }
        return try await readUntilStill(submit, from: current, services: services)
    }

    /// A layout still shifting after the keys go can lose the tap, so submit's frame must agree across two reads, for at most `keyboardSettle`.
    private static func readUntilStill(_ submit: UINode, from tree: UITree, services: Services) async throws -> UITree {
        let deadline = services.clock.now() + keyboardSettle
        var current = tree
        while true {
            try await services.clock.sleep(.milliseconds(100))
            let next = try await services.readTree()
            guard let before = LoginForm.match(submit, in: current)?.frame, let after = LoginForm.match(submit, in: next)?.frame,
                  !before.isWithinTolerance(of: after), services.clock.now() < deadline else { return next }
            current = next
        }
    }

    private static func keyboardOnScreen(_ keyboards: [UINode], in tree: UITree) -> Bool {
        guard let viewport = tree.viewport else { return true }
        return keyboards.contains { $0.frame?.isVisible(in: viewport) == true }
    }

    private static func covered(_ tree: UITree, submit: UINode, shell: UIFrame?) -> Bool {
        if let frame = submit.frame, KeyboardDismiss.covers(frame.center, in: tree) { return true }
        if let shell, KeyboardDismiss.covers(shell.center, in: tree) { return true }
        return false
    }

    /// With `services`, raised only after taps above the keys and the keyboard's own way out both left the keys over the control.
    private static func keyboardError(services: Services? = nil) -> CLIError {
        guard let services else {
            return CLIError(
                errorDescription: "The keyboard covers the next control, so Turnstile was not checked and the submit button was not tapped.",
                reason: .targetUnderKeyboard
            )
        }
        return CLIError(
            errorDescription: "The keyboard covers the next control and nothing Offsider may send closed it, so Turnstile was not checked and the submit button was not tapped. "
                + "Close the keyboard in the app, or scroll the button above it, then run login again.",
            reason: .targetUnderKeyboard,
            hint: CommandScope.current.describeHint(device: services.device)
        )
    }

    private static func waitUntilEnabled(
        _ sample: UINode,
        app: String,
        key: String,
        turnstile: LoginTurnstileStep,
        timeout: TimeInterval,
        shell: UIFrame? = nil,
        fields: [UINode] = [],
        services: Services
    ) async throws -> (report: LoginReport, tapped: UITree) {
        let deadline = services.clock.now() + timeout
        var missingUntil: TimeInterval?
        var noted = false
        var keysReturned = false
        while true {
            let tree = try await services.readTree()
            guard let submit = LoginForm.match(sample, in: tree), let frame = submit.frame else {
                let now = services.clock.now()
                let until = missingUntil ?? now + keyboardSettle
                missingUntil = until
                if now < until {
                    try await services.clock.sleep(.milliseconds(250))
                    continue
                }
                throw CLIError(
                    errorDescription: "The form changed after typing. The submit button was not tapped.",
                    reason: .selectorNotFound
                )
            }
            missingUntil = nil
            if submit.enabled != false {
                try requireForeground(app, in: tree, services: services, stopped: "the submit button was not tapped")
                let point: UIPoint
                do {
                    point = try await submitPoint(submit, frame: frame, in: tree, services: services)
                } catch let error as CLIError where error.reason == .targetUnderKeyboard && !keysReturned {
                    // The keys can come back while Turnstile settles; they get one more dismissal before the login gives up.
                    keysReturned = true
                    _ = try await dismissKeyboard(in: tree, submit: submit, shell: shell, fields: fields, services: services)
                    continue
                }
                try await services.tap(point, tree)
                let label = submit.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = (label?.isEmpty == false) ? label : nil
                return (LoginReport(app: app, key: key, turnstile: turnstile, submitLabel: shown), tree)
            }
            if services.clock.now() >= deadline {
                throw CLIError(
                    errorDescription: "The submit button stayed disabled after \(seconds(timeout)). It was not tapped.",
                    reason: .conditionNotMet
                )
            }
            if !noted {
                noted = true
                services.step("Waiting up to \(seconds(timeout)) for the submit button to enable", true)
            }
            try await services.clock.sleep(.milliseconds(250))
        }
    }

    static func seconds(_ value: TimeInterval) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
        return "\(text) s"
    }
}

/// A login that stopped after it began typing: `report` says how far it got, and the message names the filled fields.
struct LoginFailure: LocalizedError, UserFacingError, OffsiderFailure {
    var report: LoginReport
    let underlying: any Error

    private var failure: (any OffsiderFailure)? { underlying as? any OffsiderFailure }

    var reason: FailureReason { failure?.reason ?? ErrorReporter.payload(for: underlying).reason }
    var failureMessage: String {
        let message = failure?.failureMessage ?? OffsiderCommand.message(for: underlying)
        return report.progressNote.map { "\(message) \($0)" } ?? message
    }
    var hint: String? { failure?.hint }
    var ask: String? { failure?.ask }
    var candidates: [FailureCandidate] { failure?.candidates ?? [] }
    var coveredBy: CoverReport? { failure?.coveredBy }
    var users: [FailureUser] { failure?.users ?? [] }
    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
