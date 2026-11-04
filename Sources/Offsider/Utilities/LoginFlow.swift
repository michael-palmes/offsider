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
        /// Optional extra dismiss after a tap above the keys. The login command leaves this empty: Back can leave the sign-in screen.
        var hideKeyboard: () async throws -> Void = {}
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
    }

    /// How long after the submit tap Turnstile is read once more.
    static let afterSubmitRead: Duration = .milliseconds(750)

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
        try await requireNoWidget(try await readingPastLoad(tree, services: services), stage: .beforeTyping, services: services)
        var identityProgress = LoginFieldProgress.notFilled
        var passwordProgress = LoginFieldProgress.notFilled
        var report: LoginReport
        let tapped: UITree
        do {
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
            let step = try await settleTurnstile(in: tree, timeout: timeout, services: services)
            (report, tapped) = try await waitUntilEnabled(filled.submit, app: app, key: key, turnstile: step, timeout: timeout, services: services)
        } catch {
            throw LoginFailure(report: .stopped(app: app, key: key, identity: identityProgress, password: passwordProgress), underlying: error)
        }
        // One read after the tap; a read that fails cannot show a widget, and the submit already happened.
        try await services.clock.sleep(afterSubmitRead)
        let screenAfter = try? await services.readTree()
        if let screenAfter, let stray = strayTap(before: tapped, after: screenAfter, services: services) {
            var stopped = report
            stopped.submitted = false
            throw LoginFailure(report: stopped, underlying: stray)
        }
        let after: TurnstilePhase? = if let screenAfter { try? await services.readTurnstile(screenAfter) } else { nil }
        if let after {
            do {
                try await requireNoWidget(after, stage: .afterSubmit, services: services)
            } catch {
                var submitted = report
                submitted.error = ErrorReporter.payload(for: error)
                throw LoginFailure(report: submitted, underlying: error)
            }
        }
        return report
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
    private static func requireNoWidget(_ phase: TurnstilePhase, stage: TurnstileStage, services: Services) async throws {
        switch phase {
        case .absent, .passed, .checking, .failed:
            return
        case .noWidget where stage == .afterSubmit:
            return
        case .ready, .visualChallenge, .ambiguous, .noWidget:
            await services.noteDevice()
            throw turnstileRequired(phase, stage: stage, watch: services.turnstileWatch)
        }
    }

    /// After typing: absent or passed goes on; checking is read again until `timeout`; anything else hands back.
    private static func settleTurnstile(in tree: UITree, timeout: TimeInterval, services: Services) async throws -> LoginTurnstileStep {
        let deadline = services.clock.now() + timeout
        var phase = try await readingPastLoad(tree, services: services)
        while true {
            switch phase {
            case .absent:
                return .absent
            case .passed:
                return .passed
            case .ready, .visualChallenge, .ambiguous, .noWidget:
                await services.noteDevice()
                throw turnstileRequired(phase, stage: .beforeSubmit, watch: services.turnstileWatch)
            case .checking, .failed:
                if services.clock.now() >= deadline {
                    await services.noteDevice()
                    throw phase == .failed ? turnstileFailed(after: timeout, watch: services.turnstileWatch) : turnstileStillChecking(after: timeout, watch: services.turnstileWatch)
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
    private static func requireForeground(_ app: String, in tree: UITree, services: Services, stopped: String) throws {
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

    private static func masked(_ value: String?, length: Int) -> Bool {
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
    private static func hideKeysForFocusProof(in tree: UITree, fields: [UINode], services: Services) async throws -> UITree {
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
            try await services.hideKeyboard()
            current = try await readUntil(gone, services: services)
        }
        return current
    }

    static let keyboardSettle: TimeInterval = 1.5

    /// The keys can still be sliding away when the tree is read straight after a dismiss.
    private static func readUntil(_ done: (UITree) -> Bool, services: Services) async throws -> UITree {
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
        try await services.hideKeyboard()
        current = try await readUntil(clear, services: services)
        if !clear(current) { throw keyboardError() }
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

    private static func keyboardError() -> CLIError {
        CLIError(
            errorDescription: "The keyboard covers the next control, so Turnstile was not checked and the submit button was not tapped.",
            reason: .targetUnderKeyboard
        )
    }

    private static func waitUntilEnabled(
        _ sample: UINode,
        app: String,
        key: String,
        turnstile: LoginTurnstileStep,
        timeout: TimeInterval,
        services: Services
    ) async throws -> (report: LoginReport, tapped: UITree) {
        let deadline = services.clock.now() + timeout
        var missingUntil: TimeInterval?
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
                try await services.tap(try await submitPoint(submit, frame: frame, in: tree, services: services), tree)
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
            try await services.clock.sleep(.milliseconds(250))
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
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
