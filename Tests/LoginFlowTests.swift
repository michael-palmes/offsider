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

    @Test("a form the tree shows in front makes no hit-test")
    func frontFormNoHitTest() async throws {
        let script = script(buttonEnabled: true)
        _ = try await run(script)
        #expect(script.hitTests == 0)
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
    var hides = 0
    var advanceOnHide = false
    var advanceOnSleep = false
    var advanceOnTap = false
    var time: TimeInterval = 0
    /// What a hit-test at each point reaches; nil where nothing answers.
    var hit: (UIPoint) -> UINode? = { _ in nil }
    var hitTests = 0

    init(trees: [UITree]) {
        self.trees = trees
    }

    func read() -> UITree { trees[min(index, trees.count - 1)] }

    func type(_ text: String, _: UINode) {
        typed.append(text)
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
            }
        )
    }
}
