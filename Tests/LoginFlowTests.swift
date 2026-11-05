import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@MainActor
@Suite("Login flow")
struct LoginFlowTests {
    private let username = "ada@example.com"
    private let password = "s3cret-token"

    @Test("a widget that already passed is left alone, and the report hides the credential")
    func alreadyPassed() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.passed]
        let report = try await run(script)
        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
        #expect(report.turnstile == .passed)
        #expect(!report.textLine().contains(password))
        #expect(!report.textLine().contains(username))
        #expect(!report.jsonLine().contains(password))
        #expect(report.jsonLine().contains("\"password\":\"filled\""))
        #expect(report.jsonLine().contains("\"turnstile\":\"passed\""))
        #expect(report.textLine().contains("The submit button was tapped."))
        #expect(report.textLine().contains("does not mean the server accepted the login."))
    }

    @Test("a checkbox or challenge before typing stops with turnstile_required and types nothing", arguments: [0, 1, 2])
    func widgetBeforeTyping(index: Int) async throws {
        let phases: [TurnstilePhase] = [.ready(square), .visualChallenge, .ambiguous(2)]
        let script = script(buttonEnabled: true)
        script.phases = [phases[index]]
        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })
        #expect(error.reason == .turnstileRequired)
        #expect(error.exitCode == .failure)
        #expect(error.userFacingDescription.contains("Nothing was typed."))
        #expect(error.userFacingDescription.contains("never ticks Turnstile"))
        #expect(script.typed.isEmpty)
        #expect(script.taps.isEmpty)
    }

    @Test("a checkbox after typing stops before submit with submitted false and both fields filled")
    func widgetAfterTyping() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .ready(square)]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(stopped.reason == .turnstileRequired)
        #expect(!stopped.report.submitted)
        #expect(stopped.report.password == .filled)
        #expect(stopped.failureMessage.contains("The submit button was not tapped."))
        #expect(script.typed == [username, password])
        #expect(script.taps.isEmpty)
    }

    @Test("a widget still checking is read again without input until --timeout, then turnstile_required")
    func checkingWaitsThenHandsBack() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .checking]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script, timeout: 2) })
        #expect(stopped.reason == .turnstileRequired)
        #expect(stopped.failureMessage.contains("still checking after 2 s"))
        #expect(script.taps.isEmpty)
        #expect(script.typed == [username, password])
        #expect(script.phaseIndex > 3)
    }

    @Test("a widget that passes while it is read again lets submit go ahead")
    func checkingThenPassed() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .checking, .checking, .passed]
        let report = try await run(script)
        #expect(report.turnstile == .passed)
        #expect(script.taps.count == 1)
    }

    @Test("a widget after the submit tap stops with turnstile_required and submitted true, read once after 750 ms")
    func widgetAfterSubmit() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .absent, .visualChallenge, .visualChallenge]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(stopped.reason == .turnstileRequired)
        #expect(stopped.report.submitted)
        #expect(stopped.report.turnstile == .absent)
        #expect(stopped.failureMessage.hasPrefix("The submit button was tapped, and then"))
        #expect(script.taps.count == 1)
        #expect(script.phaseIndex == 3)
        #expect(script.time >= 0.75)
        #expect(stopped.report.jsonLine().contains("\"submitted\":true"))
        #expect(stopped.report.jsonLine().contains("\"reason\":\"turnstile_required\""))
    }

    @Test("a widget that stops the login asks for the step it needs, and suggests the wait", arguments: [
        (TurnstilePhase.ready(TurnstileTarget(frame: UIFrame(x: 18, y: 400, width: 30, height: 30))), PersonAsk.tickTurnstile),
        (TurnstilePhase.visualChallenge, PersonAsk.solveTurnstile),
        (TurnstilePhase.ambiguous(2), PersonAsk.tickTurnstiles),
    ])
    func widgetAsksForItsStep(phase: TurnstilePhase, ask: String) async throws {
        let script = script(buttonEnabled: true)
        script.phases = [phase]
        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })
        #expect(error.ask == ask)
        #expect(error.hint == "offsider turnstile --wait 600 --device <DEVICE_ID>")
        #expect(!error.userFacingDescription.contains("hand the device"))
    }

    @Test("the device's name is read only when a widget stops the login")
    func deviceNameIsReadOnlyOnARefusal() async throws {
        let working = script(buttonEnabled: true)
        working.phases = [.checking, .passed]
        _ = try await run(working)
        #expect(working.deviceNotes == 0)

        let stopped = script(buttonEnabled: true)
        stopped.phases = [.ready(square)]
        await #expect(throws: CLIError.self) { try await self.run(stopped) }
        #expect(stopped.deviceNotes == 1)
    }

    @Test("a widget still checking at the timeout asks to finish it")
    func checkingAsksToFinish() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .checking]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script, timeout: 2) })
        let payload = ErrorReporter.payload(for: stopped, deviceName: "iPhone 17")
        #expect(payload.ask == "Can you finish the Turnstile check on iPhone 17?")
        #expect(script.deviceNotes == 1)
    }

    @Test("a challenge found after typing asks to solve it, through the report login prints")
    func challengeAfterTypingAsksToSolve() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .visualChallenge]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        let payload = ErrorReporter.payload(for: stopped, deviceName: "iPhone 17")
        #expect(payload.ask == "Can you solve the Turnstile challenge on iPhone 17?")
    }

    @Test("before submit, login may run once more after it passes; after submit it must not")
    func whatToDoNextDependsOnSubmit() {
        let before = LoginFlow.turnstileRequired(.ready(square), stage: .beforeSubmit, audience: .agent)
        #expect(before.userFacingDescription.contains("Run login once more after it passes."))
        let after = LoginFlow.turnstileRequired(.ready(square), stage: .afterSubmit, audience: .agent)
        #expect(after.userFacingDescription.contains("Do not run login again"))
    }

    @Test("a person at the terminal is told to do the step, never to hand the device to a person", arguments: [
        LoginFlow.TurnstileStage.beforeTyping, .beforeSubmit, .afterSubmit,
    ])
    func personIsTheOneToTick(stage: LoginFlow.TurnstileStage) {
        let error = LoginFlow.turnstileRequired(.ready(square), stage: stage, audience: .person)
        #expect(error.userFacingDescription.contains("Tick it on the device"))
        #expect(!error.userFacingDescription.contains("a person to"))
        #expect(error.hint == nil)
    }

    @Test("a person at the terminal finishes a widget still checking themselves")
    func personFinishesChecking() {
        let error = LoginFlow.turnstileStillChecking(after: 15, watch: Turnstile.waitCommand(), audience: .person)
        #expect(error.userFacingDescription.contains("Finish it on the device, then run login again."))
        #expect(error.hint == nil)
    }

    @Test("another app in front before the password stops with foreground_changed; the password is never typed")
    func foregroundChangesBeforePassword() async throws {
        let script = script(buttonEnabled: true)
        script.foregrounds = ["com.other.app"]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(stopped.reason == .foregroundChanged)
        #expect(stopped.failureMessage.contains("com.other.app is in front now, not com.example.app, so the password was not typed."))
        #expect(script.typed == [username])
        #expect(script.taps.isEmpty)
    }

    @Test("another app in front before submit stops with foreground_changed and no tap")
    func foregroundChangesBeforeSubmit() async throws {
        let script = script(buttonEnabled: true)
        script.foregrounds = ["com.example.app", "com.other.app"]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(stopped.reason == .foregroundChanged)
        #expect(stopped.failureMessage.contains("so the submit button was not tapped"))
        #expect(script.typed == [username, password])
        #expect(script.taps.isEmpty)
    }

    @Test("only the password is typed as a secret")
    func passwordIsSecret() async throws {
        let script = script(buttonEnabled: true)
        _ = try await run(script)
        #expect(script.secrecy == [false, true])
    }

    @Test("a password field in a web view types nothing unless both the project file and the saved login opt in")
    func webViewNeedsBothOptIns() async throws {
        let web = { SignInFixture.tree(pid: 200) }
        let filled = SignInFixture.tree(
            emailValue: username, passwordValue: String(repeating: String(SecureText.bullet), count: password.count), submitEnabled: true, pid: 200
        )
        let projectOnly = LoginProfile(bundleID: "com.example.app", webLogin: true)
        for (profile, saved) in [(nil, false), (projectOnly, false), (LoginProfile(bundleID: "com.example.app"), true)] {
            let script = LoginScript(trees: [web(), SignInFixture.tree(emailValue: username, pid: 200), filled])
            let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script, profile: profile, webLogin: saved) })
            #expect(error.reason == .appNotAllowed)
            #expect(error.userFacingDescription.hasPrefix("The password field is inside a web view; nothing was typed."))
            #expect(error.userFacingDescription.contains("offsider credential describe dev --web-login --app com.example.app"))
            #expect(script.typed.isEmpty)
        }
        let both = LoginScript(trees: [web(), SignInFixture.tree(emailValue: username, pid: 200), filled])
        _ = try await run(both, profile: projectOnly, webLogin: true)
        #expect(both.typed == [username, password])
    }

    @Test("a profile for another app types nothing")
    func profileMismatch() async {
        let script = script(buttonEnabled: true)
        let profile = LoginProfile(bundleID: "com.other.app")
        await #expect(throws: CLIError.self) { try await self.run(script, profile: profile) }
        #expect(script.typed.isEmpty)
        #expect(script.taps.isEmpty)
    }

    @Test("a profile that names the app in front as its package types, even when its bundle id is another app")
    func profileForEitherID() async throws {
        let script = script(buttonEnabled: true)
        let profile = LoginProfile(bundleID: "com.example.ios", package: "com.example.app")
        _ = try await run(script, profile: profile)
        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
    }

    @Test("a disabled submit button is not tapped")
    func disabledSubmit() async {
        let script = script(buttonEnabled: false)
        await #expect(throws: LoginFailure.self) { try await self.run(script, timeout: 0) }
        #expect(script.sleeps == 0)
        #expect(script.taps.isEmpty)
    }

    @Test("an off-screen input assistant does not block the submit tap")
    func assistantDoesNotBlockSubmit() async throws {
        let script = script(buttonEnabled: true, assistant: true)
        script.phases = [.passed]
        let report = try await run(script)
        #expect(script.taps.count == 1)
        #expect(report.turnstile == .passed)
    }

    @Test("a keyboard hiding the submit button is dismissed before typing")
    func keyboardHidesSubmit() async throws {
        let email = FakeUI.node(.textField, id: "email-field", label: "Email", frame: FakeUI.frame(17, 212, 367, 45))
        let passwordField = FakeUI.node(.secureTextField, id: "password-field", label: "Password", frame: FakeUI.frame(17, 316, 367, 45))
        let key = FakeUI.node(.button, label: "q", frame: FakeUI.frame(10, 700, 40, 40))
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 0, 402, 874), children: [key])
        let covered = FakeUI.tree([email, passwordField, keyboard])
        let open = SignInFixture.tree()
        let filledEmail = SignInFixture.tree(emailValue: username)
        let filled = SignInFixture.tree(
            emailValue: username,
            passwordValue: String(repeating: String(SecureText.bullet), count: password.count),
            submitEnabled: true
        )
        let script = LoginScript(trees: [covered, open, filledEmail, filled])
        script.advanceOnHide = true
        script.phases = [.passed]
        let report = try await run(script)
        #expect(script.hides == 1)
        #expect(script.typed == [username, password])
        #expect(report.turnstile == .passed)
    }

    @Test("on a tree that names no focused field, the keyboard goes before the password, so its return can prove the tap landed")
    func keyboardGoesBeforeThePassword() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username, lowKeyboard: true),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnTap = true
        _ = try await run(script)
        #expect(script.typed == [username, password])
        #expect(script.tapsBeforeType == [0, 1])
    }

    @Test("a keyboard one tap does not clear before the password gets another point, clear of the form's fields")
    func keyboardGoesAtSecondPoint() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let up = SignInFixture.tree(emailValue: username, lowKeyboard: true)
        let script = LoginScript(trees: [
            SignInFixture.tree(), up, up,
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnTap = true
        _ = try await run(script)
        #expect(script.tapsBeforeType == [0, 2])
        #expect(script.taps[0].x != script.taps[1].x || script.taps[0].y != script.taps[1].y)
        for tap in script.taps.prefix(2) {
            #expect(!FakeUI.frame(17, 196, 367, 181).contains(tap), "\(tap)")
        }
    }

    @Test("a keyboard with a focused text field named stays up for the password, as the field's own focus will prove the tap")
    func keyboardStaysWithFocusNamed() async throws {
        var email = SignInFixture.tree(emailValue: username, lowKeyboard: true)
        let field = try #require(email.roots[0].children.firstIndex { $0.id == "email-field" })
        email.roots[0].children[field].state.focused = true
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(), email,
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        _ = try await run(script)
        #expect(script.tapsBeforeType == [0, 0])
    }

    @Test("keys still sliding away after the dismiss tap are waited for, not taken for a keyboard that stayed")
    func keyboardLeavesSlowly() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: true),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnSleep = true
        let report = try await run(script)
        #expect(script.hides == 0)
        #expect(script.taps.count == 2)
        #expect(report.submitLabel == "Log in")
    }

    @Test("a layout still shifting after the keys go is read until submit holds still, so the tap goes where it ended up")
    func submitMovesAfterDismiss() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        func filled(submitY: Double?, keyboard: Bool = false) -> UITree {
            var tree = SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: keyboard)
            if let submitY {
                tree.roots[0].children = tree.roots[0].children.map { node in
                    guard node.id == "login-button" else { return node }
                    var moved = node
                    moved.frame = FakeUI.frame(16, submitY, 370, 44)
                    return moved
                }
            }
            return tree
        }
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            filled(submitY: nil, keyboard: true),
            filled(submitY: 500),
            filled(submitY: 600),
            filled(submitY: 700),
            filled(submitY: 700),
        ])
        script.advanceOnSleep = true
        script.advanceOnTap = true

        _ = try await run(script)

        #expect(script.taps.count == 2)
        #expect(script.taps.last?.y == 722, "\(script.taps)")
    }

    @Test("with submit unmatched after the dismiss tap, no settle is spent on it")
    func unmatchedSubmitSpendsNoSettle() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: true),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnTap = true
        _ = try await run(script)
        #expect(script.time < 1, "\(script.time)")
    }

    @Test("a username the field shows a read late is waited for, not refused")
    func usernameShowsLate() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnSleep = true
        let report = try await run(script)
        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
        #expect(report.submitLabel == "Log in")
    }

    @Test("a read with no form while the keyboard animates away is read again, not taken for a changed form")
    func formMissingForAMomentAfterDismiss() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: true),
            FakeUI.tree([]),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnTap = true
        script.advanceOnSleep = true
        let report = try await run(script)
        #expect(script.taps.count == 2)
        #expect(report.submitLabel == "Log in")
    }

    @Test("a read that misses the submit button while it waits to be enabled is read again, not taken for a changed form")
    func submitMissingForAMoment() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets),
            FakeUI.tree([]),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnSleep = true
        let report = try await run(script)
        #expect(script.taps.count == 1)
        #expect(report.submitLabel == "Log in")
    }

    @Test("a keyboard that stays after the first dismiss tap is tapped away at a second point, then submit is tapped")
    func keyboardLeavesAfterSecondTap() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let raised = SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: true)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            raised,
            raised,
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
        ])
        script.advanceOnTap = true
        let report = try await run(script)
        try #require(script.taps.count == 3)
        #expect(script.taps[0] != script.taps[1])
        #expect(script.taps[0].y < 212)
        #expect(script.hides == 0)
        #expect(report.submitLabel == "Log in")
    }

    @Test("a keyboard no dismiss tap clears gets three distinct taps, then target_under_keyboard and no submit")
    func keyboardStaysAfterThreeTaps() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: true),
        ])
        let error = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(error.reason == .targetUnderKeyboard)
        try #require(script.taps.count == 3)
        #expect(script.taps[0] != script.taps[1] && script.taps[1] != script.taps[2] && script.taps[0] != script.taps[2])
        #expect(script.taps.allSatisfy { $0.y < 560 })
        #expect(script.hides == 1)
        #expect(script.phaseIndex == 1)
    }

    @Test("a keyboard with no safe point does not reach Turnstile or submit")
    func keyboardCoversSubmit() async {
        let script = script(buttonEnabled: true, keyboard: true)
        await #expect(throws: LoginFailure.self) { try await self.run(script) }
        #expect(script.taps.isEmpty)
        #expect(script.phaseIndex == 1)
    }

    @Test("under --json, a login that stops after both fields were filled prints its report with submitted false, and keeps exit 1")
    func stoppedAfterBothFields() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, lowKeyboard: true),
        ])
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        var written: [String] = []
        let thrown = await LoginCommand.failure(stopped, json: true, scope: CommandScope(), write: { written.append($0) })

        let message = "The keyboard covers the next control, so Turnstile was not checked and the submit button was not tapped. Both fields were filled."
        #expect(written == [
            #"{"version":1,"ok":false,"app":"com.example.app","key":"dev","identity":"filled","password":"filled","submitted":false,"name":"dev","tags":[],"turnstile":null,"exitCode":1,"#
                + #""error":{"reason":"target_under_keyboard","message":"\#(message)","hint":null,"dispatched":null,"candidates":[]},"untrusted":["error.message"]}"#,
        ])
        #expect(try expectUntrustedPathsResolve(written[0]) == ["error.message"])
        #expect((thrown as? ReportedFailure)?.exitCode.rawValue == 1)
        #expect(!written.joined().contains(username))
        #expect(!written.joined().contains(password))

        let text = await LoginCommand.failure(stopped, json: false, scope: CommandScope(), write: { written.append($0) })
        #expect(written.count == 1)
        #expect((text as? LoginFailure)?.userFacingDescription == message)
    }

    @Test("a login that stops after the email or username says so, and reports the password not_filled")
    func stoppedAfterIdentity() async throws {
        let script = LoginScript(trees: [SignInFixture.tree(), SignInFixture.tree(emailValue: username)])
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        var written: [String] = []
        let thrown = await LoginCommand.failure(stopped, json: true, scope: CommandScope(), write: { written.append($0) })

        #expect(written == [
            #"{"version":1,"ok":false,"app":"com.example.app","key":"dev","identity":"filled","password":"not_filled","submitted":false,"name":"dev","tags":[],"turnstile":null,"exitCode":5,"#
                + #""error":{"reason":"text_not_accepted","message":"The password field did not show one bullet per character. The submit button was not tapped. The email or username was filled.","hint":null,"dispatched":null,"candidates":[]},"untrusted":["error.message"]}"#,
        ])
        #expect((thrown as? ReportedFailure)?.exitCode.rawValue == 5)
    }

    @Test("a failure before typing prints no login report under --json and keeps the error envelope")
    func failureBeforeTypingKeepsTheEnvelope() async throws {
        let script = LoginScript(trees: [FakeUI.tree([])])
        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })
        var written: [String] = []
        let thrown = await LoginCommand.failure(error, json: true, scope: CommandScope(), write: { written.append($0) })

        #expect(written.isEmpty)
        #expect(script.typed.isEmpty)
        #expect(ErrorEnvelope(command: "login", error: ErrorReporter.payload(for: thrown)).jsonLine()
            == #"{"version":1,"ok":false,"command":"login","exitCode":2,"error":{"reason":"selector_not_found","message":"No email or username field is in front. Nothing was typed.","hint":null,"dispatched":null,"candidates":[]}}"#)
    }

    @Test("a login that stops after typing exits with the code and reason of what stopped it, with or without --json")
    func stoppedKeepsExitCodes() async {
        let causes: [any Error] = [
            CLIError(errorDescription: "Keys over submit.", reason: .targetUnderKeyboard),
            CLIError(errorDescription: "No bullets.", reason: .textNotAccepted),
            CLIError(errorDescription: "Form gone.", reason: .selectorNotFound),
            CLIError(errorDescription: "Two boxes.", reason: .selectorAmbiguous),
            CLIError(errorDescription: "Still disabled.", reason: .conditionNotMet),
            CLIError(errorDescription: "A challenge.", reason: .turnstileRequired),
            CocoaError(.fileNoSuchFile),
        ]
        for cause in causes {
            let stopped = LoginFailure(report: .stopped(app: "com.example.app", key: "dev", identity: .filled, password: .filled), underlying: cause)
            let before = ErrorReporter.status(for: cause)
            let after = ErrorReporter.status(for: stopped)
            #expect(after.exit == before.exit)
            #expect(after.reason == before.reason)
            let reported = await LoginCommand.failure(stopped, json: true, scope: CommandScope(), write: { _ in })
            #expect((reported as? ReportedFailure)?.exitCode.rawValue == before.exit)
        }
        #expect(ErrorReporter.status(for: causes[0]).exit == 1)
        #expect(ErrorReporter.status(for: causes[1]).exit == 5)
    }

    @Test("with no form in front, the error names who Offsider last signed in here and how to switch; with no record it is unchanged")
    func missingFormNote() async throws {
        let since = Date(timeIntervalSince1970: 1_791_712_931)
        func failure(_ last: LoginFlow.LastSignIn?) async -> CLIError? {
            let script = LoginScript(trees: [FakeUI.tree([])])
            return await #expect(throws: CLIError.self) { try await self.run(script, lastSignIn: { last }) }
        }
        let plain = try #require(await failure(nil))
        let noted = try #require(await failure(LoginFlow.LastSignIn(key: "qa-admin", since: since, restarted: true, deviceID: "emulator-5554")))
        let fresh = try #require(await failure(LoginFlow.LastSignIn(key: "*", since: since, restarted: false, deviceID: "emulator-5554")))

        #expect(plain.reason == .selectorNotFound)
        #expect(noted.exitCode == .selectorNotFound)
        #expect(plain.hint == nil)
        #expect(!plain.userFacingDescription.contains("Offsider last signed in"))
        #expect(noted.reason == plain.reason)
        #expect(noted.userFacingDescription == plain.userFacingDescription
            + " Offsider last signed in as qa-admin here (2026-10-11T10:02:11Z, before the device restarted), so the app may still be signed in."
            + " To switch users, sign out in the app, run `offsider credential signed-out --device emulator-5554`, then run login again.")
        #expect(noted.hint == "offsider credential signed-out --device emulator-5554")
        #expect(fresh.userFacingDescription.contains("Offsider last signed in as the default login here (2026-10-11T10:02:11Z), so the app"))

        var reads = 0
        _ = try await run(script(buttonEnabled: true), lastSignIn: {
            reads += 1
            return nil
        })
        #expect(reads == 0)
    }

    @Test("a covered or unmatched pinned field, or a missing password field, is not a missing form: no switch note and no record read")
    func otherFailuresHaveNoNote() async throws {
        let last = LoginFlow.LastSignIn(key: "qa-admin", since: Date(timeIntervalSince1970: 1_791_712_931), restarted: false, deviceID: "emulator-5554")
        let emailOnly = FakeUI.tree([FakeUI.node(.textField, id: "email-field", label: "Email", frame: FakeUI.frame(17, 212, 367, 45))])
        let cases: [(UITree, LoginProfile?)] = [
            (SignInFixture.tree(coverPassword: true), LoginProfile(bundleID: "com.example.app", password: LoginField(id: "password-field"))),
            (SignInFixture.tree(), LoginProfile(bundleID: "com.example.app", identity: LoginField(id: "account-field"))),
            (FakeUI.tree([]), LoginProfile(bundleID: "com.example.app", identity: LoginField(id: "email-field"))),
            (emailOnly, nil),
        ]
        for (tree, profile) in cases {
            var reads = 0
            var failure: CLIError?
            do {
                _ = try await run(LoginScript(trees: [tree]), profile: profile, lastSignIn: {
                    reads += 1
                    return last
                })
            } catch let error as CLIError {
                failure = error
            }
            let error = try #require(failure)
            #expect(error.reason == .selectorNotFound)
            #expect(error.exitCode == .selectorNotFound)
            #expect(error.hint == nil)
            #expect(!error.userFacingDescription.contains("Offsider last signed in"), "\(error.userFacingDescription)")
            #expect(reads == 0)
        }
    }

    /// A web widget's content from another process, listed last, with a frame that reaches over the whole form.
    private func underWidget(_ tree: UITree) -> UITree {
        var tree = tree
        tree.roots[0].children.append(FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), pid: 200, children: [
            FakeUI.node(.text, label: "Confirm you are here", frame: FakeUI.frame(16, 405, 370, 64), pid: 200),
        ]))
        return tree
    }

    @Test("a web widget the tree lists over the form does not hide fields a hit-test at their own points reaches")
    func widgetOverFormHitTested() async throws {
        let script = script(buttonEnabled: true)
        script.trees = script.trees.map(underWidget)
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in controls.last { $0.role != .application && $0.frame?.contains(point) == true } }

        let report = try await run(script)

        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
        #expect(report.submitLabel == "Log in")
        #expect(script.hitTests <= 12)
    }

    @Test("with no hit-test, or one that reaches the widget, the covered form is still refused with nothing typed")
    func widgetOverFormRefused() async throws {
        for answersWidget in [false, true] {
            let script = script(buttonEnabled: true)
            script.trees = script.trees.map(underWidget)
            if answersWidget {
                script.hit = { _ in FakeUI.node(.text, label: "Confirm you are here", frame: FakeUI.frame(16, 405, 370, 64), pid: 200) }
            }
            let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })
            #expect(error.reason == .selectorNotFound)
            #expect(script.typed.isEmpty)
        }
    }

    @Test("a widget that opens over the submit button after typing is hit-tested again, and the covered submit is not tapped")
    func widgetOverSubmitAfterTyping() async throws {
        let script = script(buttonEnabled: true)
        script.trees = script.trees.map(underWidget)
        let controls = SignInFixture.tree().roots[0].flattened()
        let challenge = FakeUI.node(.text, label: "Confirm you are here", frame: FakeUI.frame(16, 405, 370, 64), pid: 200)
        script.hit = { point in
            if script.typed.count == 2, point.y > 700 { return challenge }
            return controls.last { $0.role != .application && $0.frame?.contains(point) == true }
        }

        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })

        #expect(stopped.reason == .selectorNotFound)
        #expect(script.typed == [username, password])
        #expect(script.taps.allSatisfy { $0.y < 700 })
    }

    /// A form under a full-screen window around a small icon, as a simulator answers it: the fields themselves, and the button's own label.
    private func underWindow(_ script: LoginScript, _ window: UINode = SignInFixture.toolsButtonWindow()) {
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.append(window)
            return tree
        }
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in
            if FakeUI.frame(16, 732, 370, 44).contains(point) {
                return FakeUI.node(.text, label: "Log in", frame: FakeUI.frame(180, 744, 42, 18))
            }
            return controls.last { $0.role != .application && $0.frame?.contains(point) == true }
        }
    }

    @Test("with Expo's Tools button window on, the form is filled and submit tapped, with the hit-tests bounded")
    func toolsButtonSignsIn() async throws {
        let script = script(buttonEnabled: true)
        underWindow(script)

        let report = try await run(script)

        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
        #expect(script.taps.first == UIPoint(x: 201, y: 754))
        #expect(report.submitLabel == "Log in")
        #expect(script.hitTests <= 1)
    }

    @Test("under a window the tree cannot settle, hit-tests at each control's own point reach the form, its submit by its label")
    func iconOverlaySignsIn() async throws {
        let script = script(buttonEnabled: true)
        underWindow(script, SignInFixture.iconOverlayWindow())

        let report = try await run(script)

        #expect(script.typed == [username, password])
        #expect(report.submitLabel == "Log in")
        #expect(script.hitTests > 0 && script.hitTests <= 12)
    }

    @Test("with the Tools button on, a keyboard hiding submit is still dismissed before typing, as the credentials count as visible")
    func toolsButtonRevealsSubmit() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let hidden = SignInFixture.tree(lowKeyboard: true, omitSubmit: true, toolsButton: true)
        let script = LoginScript(trees: [
            hidden,
            SignInFixture.tree(toolsButton: true),
            SignInFixture.tree(emailValue: username, toolsButton: true),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true, toolsButton: true),
        ])
        script.advanceOnTap = true
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in
            if FakeUI.frame(16, 732, 370, 44).contains(point) {
                return FakeUI.node(.text, label: "Log in", frame: FakeUI.frame(180, 744, 42, 18))
            }
            return controls.last { $0.role != .application && $0.frame?.contains(point) == true }
        }

        _ = try await run(script)

        #expect(script.typed == [username, password])
        #expect(script.tapsBeforeType.first == 1)
        let first = try #require(script.taps.first)
        #expect(!controls.contains { $0.isActionable && $0.frame?.contains(first) == true }, "\(first)")
    }

    @Test("Turnstile's web content over the form leaves the form reachable, the button's own label included, and a prefilled email is replaced")
    func webContentOverPrefilledForm() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        let script = LoginScript(trees: [
            underWidget(SignInFixture.tree(emailValue: "earlier@example.com")),
            underWidget(SignInFixture.tree(emailValue: username)),
            underWidget(SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true)),
        ])
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in
            if FakeUI.frame(16, 732, 370, 44).contains(point) {
                return FakeUI.node(.text, label: "Log in", frame: FakeUI.frame(180, 744, 42, 18))
            }
            return controls.last { $0.role != .application && $0.frame?.contains(point) == true }
        }

        let report = try await run(script)

        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
        #expect(report.submitted)
    }

    @Test("many sign-in buttons on a screen beneath do not use up the hit-tests before the form's own controls")
    func hitTestsReachTheForm() async throws {
        let beneath = (0..<8).map { index in
            FakeUI.node(.button, id: "beneath-\(index)", label: "Continue", frame: FakeUI.frame(16, 480 + Double(index) * 20, 370, 18))
        }
        let script = script(buttonEnabled: true)
        underWindow(script, SignInFixture.iconOverlayWindow())
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.insert(contentsOf: beneath, at: 0)
            return tree
        }
        let hit = script.hit
        script.hit = { point in
            if (480..<640).contains(point.y) { return FakeUI.node(.text, label: "Welcome", frame: FakeUI.frame(16, 480, 370, 160)) }
            return hit(point)
        }

        _ = try await run(script)

        #expect(script.typed == [username, password])
        #expect(script.hitTests <= 12)
    }

    @Test("a real backdrop around a sheet over the password field is refused, with the sheet named, and nothing typed")
    func modalBackdropRefused() async throws {
        let script = script(buttonEnabled: true)
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.append(SignInFixture.modalSheet())
            return tree
        }
        let sheet = FakeUI.node(.text, label: "Choose a region", frame: FakeUI.frame(16, 300, 370, 80))
        let backdrop = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874))
        script.hit = { point in sheet.frame?.contains(point) == true ? sheet : backdrop }

        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })

        #expect(error.reason == .selectorNotFound)
        #expect(script.typed.isEmpty)
        #expect(error.userFacingDescription.contains("Choose a region"), "\(error.userFacingDescription)")
        #expect(error.coveredBy?.role == "group")
    }

    @Test("a pinned field under a backdrop is refused with coveredBy filled")
    func pinnedCoverNamesTheCover() async throws {
        let script = script(buttonEnabled: true)
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.append(SignInFixture.modalSheet())
            return tree
        }
        let sheet = FakeUI.node(.text, label: "Choose a region", frame: FakeUI.frame(16, 300, 370, 80))
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in
            if sheet.frame?.contains(point) == true { return sheet }
            return controls.last { $0.role != .application && $0.frame?.contains(point) == true }
        }
        let profile = LoginProfile(bundleID: "com.example.app", password: LoginField(id: "password-field"))

        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script, profile: profile) })

        #expect(error.userFacingDescription.contains("is covered by"))
        #expect(error.userFacingDescription.contains("Choose a region"), "\(error.userFacingDescription)")
        #expect(error.coveredBy?.label == "Choose a region")
        #expect(script.typed.isEmpty)
    }

    /// React Native's toast as the tree gives it, its count and message in one label.
    private func toast(y: Double, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(.button, label: "3, [SIGNIN] widget expired", frame: FakeUI.frame(10, y, 382, 48), platform: platform)
    }

    @Test("a LogBox toast whose message holds a submit word is not a second submit button")
    func logBoxToastIsNotSubmit() async throws {
        let script = script(buttonEnabled: true)
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.append(toast(y: 800))
            return tree
        }
        let report = try await run(script)
        #expect(script.typed == [username, password])
        #expect(script.taps == [UIPoint(x: 201, y: 754)])
        #expect(report.submitted)
    }

    /// An edge-to-edge Android form whose toast's list takes touches a status bar above its own frame, over a submit button drawn clear of the frame.
    private func androidFormUnderToast(email: String? = nil, password value: String? = nil, enabled: Bool = false) -> UITree {
        var field = FakeUI.node(.secureTextField, id: "password-field", label: "Password", value: value, frame: FakeUI.frame(16, 306, 379, 44), platform: .android, drawingOrder: 3)
        field.native = .android(AndroidNativeAttributes(package: "com.example.app", drawingOrder: 3))
        var tree = FakeUI.tree(platform: .android, height: 923, [
            FakeUI.node(.text, label: "Sign in", frame: FakeUI.frame(16, 10, 200, 30), platform: .android, drawingOrder: 1),
            FakeUI.node(.textField, id: "email-field", label: "Email", value: email, frame: FakeUI.frame(16, 217, 379, 44), platform: .android, drawingOrder: 2),
            field,
            FakeUI.node(.button, id: "login-button", label: "Log in", frame: FakeUI.frame(16, 780, 379, 44), enabled: enabled, platform: .android, drawingOrder: 4),
            toast(y: 840, platform: .android),
        ])
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 1, title: "Playground", active: true, focused: true, package: "com.example.app", bounds: FakeUI.frame(0, 0, 411, 923)),
            UIWindowInfo(id: 2, kind: "system", layer: 2, title: "StatusBar", active: false, focused: false, package: "com.android.systemui", bounds: FakeUI.frame(0, 0, 411, 54)),
        ]
        return tree
    }

    @Test("a toast whose touch area takes submit's point stops before typing, naming the fix, and nothing is tapped")
    func logBoxTakesSubmitsPoint() async throws {
        let script = LoginScript(trees: [androidFormUnderToast()])

        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })

        #expect(error.reason == .targetCovered)
        #expect(error.userFacingDescription.contains("Nothing was typed."))
        #expect(error.hint == "offsider rn logbox dismiss --device <DEVICE_ID>")
        #expect(error.coveredBy?.evidence == .logBoxTouchArea)
        #expect(script.typed.isEmpty)
        #expect(script.taps.isEmpty)
    }

    @Test("a toast that appears while typing stops before submit: no tap, submitted false")
    func logBoxAppearsWhileTyping() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        func clear(_ tree: UITree) -> UITree {
            var tree = tree
            tree.roots[0].children.removeAll { $0.label == "3, [SIGNIN] widget expired" }
            return tree
        }
        let script = LoginScript(trees: [
            clear(androidFormUnderToast()),
            clear(androidFormUnderToast(email: username)),
            androidFormUnderToast(email: username, password: bullets, enabled: true),
        ])

        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })

        #expect(stopped.reason == .targetCovered)
        #expect(!stopped.report.submitted)
        #expect(script.taps.isEmpty)
        #expect(stopped.hint == "offsider rn logbox dismiss --device <DEVICE_ID>")
    }

    @Test("a submit tap that opens LogBox's inspector reports submitted false, never ok")
    func tapOpensLogBoxInspector() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        func withToast(_ tree: UITree) -> UITree {
            var tree = tree
            tree.roots[0].children.append(toast(y: 800))
            return tree
        }
        var inspector = withToast(SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true))
        inspector.roots[0].children.append(FakeUI.node(.text, label: "Log 1 of 3", frame: FakeUI.frame(100, 60, 200, 24)))
        let script = LoginScript(trees: [
            withToast(SignInFixture.tree()),
            withToast(SignInFixture.tree(emailValue: username)),
            withToast(SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true)),
            inspector,
        ])
        script.advanceOnTap = true

        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })

        #expect(!stopped.report.submitted)
        #expect(stopped.report.exitCode != .success || stopped.report.jsonLine().contains("\"submitted\":false"))
        #expect(stopped.failureMessage.contains("never reached the form"))
        #expect(stopped.hint == "offsider rn logbox dismiss --device <DEVICE_ID>")
        #expect(script.taps.count == 1)
    }

    @Test("a submit tap that opens the dev menu reports submitted false, and names the command that closes it")
    func tapOpensDevMenu() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        func withGear(_ tree: UITree) -> UITree {
            var tree = tree
            tree.roots[0].children.append(SignInFixture.toolsButtonWindow())
            return tree
        }
        var menu = withGear(SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true))
        menu.roots[0].children += [
            FakeUI.node(.button, label: "Reload", frame: FakeUI.frame(20, 400, 170, 54)),
            FakeUI.node(.button, label: "Go home", frame: FakeUI.frame(210, 400, 170, 54)),
            FakeUI.node(.button, label: "Toggle performance monitor", frame: FakeUI.frame(20, 470, 360, 44)),
        ]
        let script = LoginScript(trees: [
            withGear(SignInFixture.tree()),
            withGear(SignInFixture.tree(emailValue: username)),
            withGear(SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true)),
            menu,
        ])
        script.advanceOnTap = true
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in controls.last { $0.role != .application && $0.frame?.contains(point) == true } }

        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })

        #expect(!stopped.report.submitted)
        #expect(stopped.failureMessage.contains("opened the dev menu"))
        #expect(stopped.hint == "offsider rn devmenu close --device <DEVICE_ID>")
    }

    @Test("an inspector that opens after a tap with no toast up is the app's own error, and the tap stands")
    func inspectorWithNoToastIsNotAStrayTap() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        var inspector = SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true)
        inspector.roots[0].children.append(FakeUI.node(.text, label: "Log 1 of 1", frame: FakeUI.frame(100, 60, 200, 24)))
        let script = LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: true),
            inspector,
        ])
        script.advanceOnTap = true

        let report = try await run(script)

        #expect(report.submitted)
    }

    @Test("the Tools button over submit's centre moves the tap to a part a hit-test finds, and a label read there still counts")
    func toolsButtonOverSubmit() async throws {
        let gear = FakeUI.node(.image, id: "gearshape.fill", label: "gearshape.fill", frame: FakeUI.frame(188, 741, 26, 26))
        let window = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [gear])
        let script = script(buttonEnabled: true)
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.append(window)
            return tree
        }
        let controls = SignInFixture.tree().roots[0].flattened()
        script.hit = { point in
            if FakeUI.frame(16, 732, 370, 44).contains(point) {
                return FakeUI.node(.text, label: "Log in", frame: FakeUI.frame(180, 744, 42, 18))
            }
            return controls.last { $0.role != .application && $0.frame?.contains(point) == true }
        }

        let report = try await run(script)

        #expect(report.submitted)
        let tap = try #require(script.taps.last)
        #expect(!KnownOverlays.devMenuButton(gear, takes: tap), "\(tap)")
        #expect(FakeUI.frame(16, 732, 370, 44).contains(tap))
    }

    @Test("Gboard's floating toolbar is no keys: login makes no dismiss tap, and submit is tapped")
    func floatingToolbarNeedsNoDismiss() async throws {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        func form(email: String? = nil, password value: String? = nil, enabled: Bool = false) -> UITree {
            var field = FakeUI.node(.secureTextField, id: "password-field", label: "Password", value: value, frame: FakeUI.frame(16, 306, 379, 44), platform: .android, drawingOrder: 2)
            field.native = .android(AndroidNativeAttributes(package: "com.example.app", drawingOrder: 2))
            var tree = FakeUI.tree(platform: .android, height: 923, [
                FakeUI.node(.textField, id: "email-field", label: "Email", value: email, frame: FakeUI.frame(16, 217, 379, 44), platform: .android, drawingOrder: 1),
                field,
                FakeUI.node(.button, id: "login-button", label: "Log in", frame: FakeUI.frame(16, 362, 379, 44), enabled: enabled, platform: .android, drawingOrder: 3),
            ])
            tree.roots.append(FakeUI.node(.keyboard, label: "Gboard", frame: FakeUI.frame(12, 456, 48, 48), platform: .android, children: [
                FakeUI.node(.button, label: "More keyboard options", frame: FakeUI.frame(12, 456, 48, 48), platform: .android),
            ]))
            return tree
        }
        let script = LoginScript(trees: [form(), form(email: username), form(email: username, password: bullets, enabled: true)])

        let report = try await run(script)

        #expect(script.typed == [username, password])
        #expect(script.taps.count == 1)
        #expect(script.hides == 0)
        #expect(report.submitted)
    }

    @Test("a web view with no widget that stays that way types nothing and asks for the tick, naming what else it may be")
    func unknownBeforeTyping() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.noWidget]
        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script) })
        #expect(error.reason == .turnstileRequired)
        #expect(error.ask == PersonAsk.tickTurnstile)
        #expect(error.userFacingDescription.contains("Nothing was typed."))
        #expect(error.userFacingDescription.contains("If no box shows"))
        #expect(script.typed.isEmpty)
        #expect(script.taps.isEmpty)
        #expect(script.time >= LoginFlow.widgetLoad)
        let payload = ErrorReporter.payload(for: error, deviceName: "iPhone 17")
        #expect(payload.ask == "Can you tick the Turnstile checkbox on iPhone 17?")
    }

    @Test("a web view whose widget loads a moment later is read again, not refused")
    func unknownWhileLoading() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.noWidget, .noWidget, .passed]
        let report = try await run(script)
        #expect(script.typed == [username, password])
        #expect(report.turnstile == .passed)
    }

    @Test("a web view with no widget after typing does not tap submit")
    func unknownAfterTyping() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .noWidget]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(stopped.reason == .turnstileRequired)
        #expect(stopped.failureMessage.contains("The submit button was not tapped."))
        #expect(!stopped.report.submitted)
        #expect(script.taps.isEmpty)
    }

    @Test("a web view with no widget after the submit tap is no refusal: the tap stands")
    func unknownAfterSubmit() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.absent, .absent, .noWidget]
        let report = try await run(script)
        #expect(report.submitted)
        #expect(script.taps.count == 1)
    }

    @Test("a failed widget retries by itself, so login reads again and goes on when it passes")
    func failedThenPassed() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.failed, .failed, .checking, .passed]
        let report = try await run(script)
        #expect(report.turnstile == .passed)
        #expect(script.taps.count == 1)
    }

    @Test("a widget still failed at the timeout stops before submit, saying so")
    func failedAtTheTimeout() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.failed]
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script, timeout: 2) })
        #expect(stopped.reason == .turnstileRequired)
        #expect(stopped.failureMessage.contains("still showed Verification failed after 2 s"))
        #expect(script.taps.isEmpty)
    }

    @Test("a reached field's twin on a screen beneath, with the same id, does not make the field ambiguous")
    func twinBeneathIsNotReached() async throws {
        let script = script(buttonEnabled: true)
        underWindow(script, SignInFixture.iconOverlayWindow())
        script.trees = script.trees.map { tree in
            var tree = tree
            tree.roots[0].children.insert(FakeUI.node(.textField, id: "email-field", label: "Email", frame: FakeUI.frame(17, 600, 367, 45)), at: 0)
            return tree
        }
        let hit = script.hit
        script.hit = { point in point.y > 590 && point.y < 650 ? FakeUI.node(.textField, id: "email-field", label: "Email", frame: FakeUI.frame(17, 212, 367, 45)) : hit(point) }

        _ = try await run(script)

        #expect(script.typed == [username, password])
    }

    @Test("a form the tree shows in front makes no hit-test for its fields, and at most one where the submit tap goes")
    func frontFormNoHitTest() async throws {
        let script = script(buttonEnabled: true)
        _ = try await run(script)
        #expect(script.hitTests <= 1)
    }

    private var square: TurnstileTarget {
        TurnstileTarget(frame: UIFrame(x: 18, y: 400, width: 30, height: 30))
    }

    private func script(buttonEnabled: Bool, keyboard: Bool = false, assistant: Bool = false) -> LoginScript {
        let empty = SignInFixture.tree()
        let email = SignInFixture.tree(emailValue: username)
        let filled = SignInFixture.tree(
            emailValue: username,
            passwordValue: String(repeating: String(SecureText.bullet), count: password.count),
            submitEnabled: buttonEnabled,
            fullKeyboard: keyboard,
            assistantChrome: assistant,
            emptyCover: assistant
        )
        return LoginScript(trees: [empty, email, filled])
    }

    private func run(
        _ script: LoginScript, profile: LoginProfile? = nil, webLogin: Bool = false, timeout: TimeInterval = 15,
        lastSignIn: () -> LoginFlow.LastSignIn? = { nil }
    ) async throws -> LoginReport {
        let credential = try #require(LoginCredential(username: username, password: password))
        return try await LoginFlow.run(
            app: "com.example.app",
            key: "dev",
            credential: credential,
            profile: profile,
            webLogin: webLogin,
            timeout: timeout,
            services: script.services,
            lastSignIn: lastSignIn
        )
    }
}

@MainActor
final class LoginScript {
    var trees: [UITree]
    var index = 0
    var typed: [String] = []
    var taps: [UIPoint] = []
    var phases: [TurnstilePhase] = [.passed]
    var phaseIndex = 0
    var sleeps = 0
    /// The app in front at each foreground check; the last repeats.
    var foregrounds = ["com.example.app"]
    var foregroundIndex = 0
    /// `InputSecrecy.isSecret` at each type call.
    var secrecy: [Bool] = []
    /// How many taps came before each type call.
    var tapsBeforeType: [Int] = []
    var hides = 0
    var advanceOnHide = false
    var advanceOnSleep = false
    var advanceOnTap = false
    var time: TimeInterval = 0
    /// What a hit-test at each point reaches; nil where nothing answers.
    var hit: (UIPoint) -> UINode? = { _ in nil }
    var hitTests = 0
    var deviceNotes = 0

    init(trees: [UITree]) {
        self.trees = trees
    }

    func read() -> UITree { trees[min(index, trees.count - 1)] }

    func type(_ text: String, _: UINode) {
        typed.append(text)
        tapsBeforeType.append(taps.count)
        secrecy.append(InputSecrecy.isSecret)
        if index + 1 < trees.count { index += 1 }
    }

    func hide() {
        hides += 1
        if advanceOnHide, index + 1 < trees.count { index += 1 }
    }

    var services: LoginFlow.Services {
        LoginFlow.Services(
            readTree: { self.read() },
            typeText: { text, field in self.type(text, field) },
            tap: { point, _ in
                self.taps.append(point)
                if self.advanceOnTap, self.index + 1 < self.trees.count { self.index += 1 }
            },
            readTurnstile: { _ in
                let phase = self.phases[min(self.phaseIndex, self.phases.count - 1)]
                self.phaseIndex += 1
                return phase
            },
            hideKeyboard: { self.hide() },
            clock: PollClock(
                now: { self.time },
                sleep: { duration in
                    self.sleeps += 1
                    if self.advanceOnSleep, self.index + 1 < self.trees.count { self.index += 1 }
                    let parts = duration.components
                    self.time += Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                }
            ),
            foregroundApp: { _ in
                let app = self.foregrounds[min(self.foregroundIndex, self.foregrounds.count - 1)]
                self.foregroundIndex += 1
                return app
            },
            bundleForPID: { $0 == 100 ? "com.example.app" : nil },
            hitTest: { point in
                self.hitTests += 1
                return self.hit(point)
            },
            noteDevice: { self.deviceNotes += 1 }
        )
    }
}
