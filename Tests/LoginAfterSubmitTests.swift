import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// What `login` does once it has tapped submit, and how it waits for a person's Turnstile step.
@MainActor
@Suite("Login after submit and the Turnstile wait")
struct LoginAfterSubmitTests {
    private let username = "ada@example.com"
    private let password = "s3cret-token"
    private let notNow = SavePrompt(title: "Save Password?", declineLabel: "Not Now", decline: UIPoint(x: 201, y: 800))

    @Test("a form that leaves after submit is reported as gone, and the report keeps its usual caveat")
    func formLeaves() async throws {
        let script = script()
        let report = try await run(script)
        #expect(report.formStillInFront == false)
        #expect(report.jsonLine().contains(#""formStillInFront":false,"savePrompt":null,"waitedForTurnstile":false"#))
        #expect(report.textLine().contains("This does not mean the server accepted the login."))
        #expect(script.time - (try #require(script.submittedAt)) < LoginFlow.afterSubmitWatch)
    }

    @Test("a form still in front when the watch ends is flagged, exits 0 and says the app may have refused it")
    func formStays() async throws {
        let script = script()
        script.signedIn = nil
        let report = try await run(script)
        #expect(report.formStillInFront == true)
        #expect(report.submitted)
        #expect(report.exitCode == .success)
        #expect(report.jsonLine().contains(#""ok":true"#))
        #expect(report.jsonLine().contains(#""formStillInFront":true"#))
        #expect(report.textLine().contains("may have refused the login"))
        #expect(!report.textLine().contains("does not mean the server accepted"))
        let watched = script.time - (try #require(script.submittedAt))
        #expect(watched >= LoginFlow.afterSubmitWatch && watched < LoginFlow.afterSubmitWatch + 1, "\(watched)")
    }

    @Test("a sign-in that takes a few seconds is not flagged once its form leaves")
    func slowSignIn() async throws {
        let script = script()
        script.signInDelay = 3
        let report = try await run(script)
        #expect(report.formStillInFront == false)
    }

    @Test("a form the tree still lists is not in front when a touch on its password field reaches another element")
    func formBeneathIsNotInFront() async throws {
        let script = script()
        script.signedIn = nil
        script.hit = { _ in script.submittedAt == nil ? nil : FakeUI.node(.header, id: "home-title", label: "Home", frame: FakeUI.frame(0, 0, 402, 874)) }
        let report = try await run(script)
        #expect(report.formStillInFront == false)
    }

    @Test("a save-password prompt is declined by one tap on its decline control, and nothing else is tapped")
    func declinesSavePrompt() async throws {
        let script = script()
        script.prompt = notNow
        let report = try await run(script)
        #expect(report.savePrompt == .declined)
        #expect(script.taps.count == 2)
        #expect(script.taps.last == notNow.decline)
        #expect(report.exitCode == .success)
        #expect(report.jsonLine().contains(#""savePrompt":"declined""#))
        #expect(report.textLine().contains("declined the system's save-password prompt"))
        #expect(script.asks.isEmpty)
    }

    @Test("a prompt with no decline control is never tapped: the login ends with the ask, submitted true")
    func noDeclineControlTapsNothing() async throws {
        let script = script()
        script.prompt = SavePrompt(title: "Save Password?")
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(script.taps.count == 1)
        #expect(stopped.reason == .systemPromptInFront)
        #expect(stopped.report.submitted)
        #expect(stopped.report.savePrompt == .open)
        #expect(stopped.failureMessage.contains("never taps Save"))
        #expect(stopped.failureMessage.contains("Do not run login again"))
        #expect(stopped.ask == "Can you tap Not Now on the \"Save Password?\" prompt on \(PersonAsk.devicePlaceholder)?")
        #expect(stopped.report.jsonLine().contains(#""savePrompt":"open""#))
        #expect(script.deviceNotes == 1)
    }

    @Test("a decline tap that is refused, as the app guard may, leaves the prompt to a person and says why")
    func refusedDeclineHandsOver() async throws {
        let script = script()
        script.prompt = notNow
        script.tapError = CLIError(errorDescription: "The rule guards this spot.", reason: .guardedControl)
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script) })
        #expect(script.taps.count == 1)
        #expect(stopped.report.savePrompt == .open)
        #expect(stopped.failureMessage.contains("could not decline it: The rule guards this spot."))
    }

    @Test("on a phone in personal use the prompt is never tapped: the person is asked, and the login goes on once it closes")
    func personalPhoneAsksAndWatches() async throws {
        let script = script()
        script.prompt = notNow
        script.declinesPrompts = false
        script.promptClosesAt = 6
        let report = try await run(script)
        #expect(report.savePrompt == .closed)
        #expect(script.taps.count == 1)
        #expect(script.asks == [notNow.ask])
        #expect(script.shownSteps.contains { $0.hasPrefix("Waiting up to 15 s for a person to close") })
        #expect(script.time >= 6)
    }

    @Test("on a phone in personal use a prompt nobody closes ends the login with the ask after --timeout, nothing tapped")
    func personalPhoneEndsWithAsk() async throws {
        let script = script()
        script.prompt = notNow
        script.declinesPrompts = false
        let stopped = try #require(await #expect(throws: LoginFailure.self) { try await self.run(script, timeout: 4) })
        #expect(script.taps.count == 1)
        #expect(stopped.reason == .systemPromptInFront)
        #expect(stopped.report.savePrompt == .open)
        #expect(stopped.report.submitted)
        #expect(stopped.ask == notNow.ask)
        #expect(stopped.failureMessage.contains("the person's to answer"))
        let watched = script.time - (try #require(script.submittedAt))
        #expect(watched >= 4 && watched < 8, "\(watched)")
    }

    @Test("a read the prompt stops, as on a phone held to one app, still names the prompt and waits for it to close")
    func promptThatStopsReads() async throws {
        let script = script()
        script.prompt = SavePrompt(savesPassword: false, title: "Autofill")
        script.declinesPrompts = false
        script.promptStopsReads = CLIError(errorDescription: "A system window covers the app.", reason: .commandFailed)
        script.promptClosesAt = 4
        let report = try await run(script)
        #expect(report.savePrompt == .closed)
        #expect(script.asks == ["Can you answer the \"Autofill\" prompt on \(PersonAsk.devicePlaceholder)?"])
        #expect(script.taps.count == 1)
    }

    @Test("--wait-turnstile asks for the tick, types nothing until it passes, never taps the box, then signs in")
    func waitsForTickBeforeTyping() async throws {
        let script = script()
        script.phases = [.ready(square), .ready(square), .ready(square), .passed]
        script.typedAtPhase = true
        let report = try await run(script, waitTurnstile: 60)
        #expect(report.waitedForTurnstile)
        #expect(report.turnstile == .passed)
        #expect(script.asks == [PersonAsk.tickTurnstile])
        #expect(script.typed == [username, password])
        #expect(script.phaseAtFirstType >= 3)
        #expect(script.taps.count == 1)
        #expect(script.shownSteps.contains("Waiting up to 60 s for a person to finish Turnstile"))
        #expect(report.jsonLine().contains(#""waitedForTurnstile":true"#))
    }

    @Test("--wait-turnstile that runs out stops as before, with nothing typed, and says how long it waited")
    func waitRunsOut() async throws {
        let script = script()
        script.phases = [.ready(square)]
        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script, waitTurnstile: 3) })
        #expect(error.reason == .turnstileRequired)
        #expect(error.userFacingDescription.contains("Nothing was typed."))
        #expect(error.userFacingDescription.hasPrefix("The Cloudflare Turnstile checkbox was still unticked after 3 s (--wait-turnstile)."))
        #expect(error.hint == "offsider turnstile --wait 600 --device <DEVICE_ID>")
        #expect(error.ask == PersonAsk.tickTurnstile)
        #expect(script.typed.isEmpty)
        #expect(script.taps.isEmpty)
        #expect(script.time >= 3 && script.time < 6, "\(script.time)")
    }

    @Test("a wait that ends on a widget still checking says so, and asks to finish it")
    func waitEndsStillChecking() async throws {
        let script = script()
        script.phases = [.ready(square), .ready(square), .checking]
        let error = try #require(await #expect(throws: CLIError.self) { try await self.run(script, waitTurnstile: 3) })
        #expect(error.userFacingDescription.hasPrefix("Cloudflare Turnstile was still checking after 3 s (--wait-turnstile). Nothing was typed."))
        #expect(error.ask == PersonAsk.finishTurnstile)
    }

    @Test("a box that asks for a tick after typing is waited for too, on the same budget, then submit is tapped once")
    func waitsBeforeSubmit() async throws {
        let script = script()
        script.phases = [.absent, .ready(square), .ready(square), .passed]
        let report = try await run(script, waitTurnstile: 60)
        #expect(report.waitedForTurnstile)
        #expect(script.asks == [PersonAsk.tickTurnstile])
        #expect(script.taps.count == 1)
        #expect(report.turnstile == .passed)
    }

    @Test("without --wait-turnstile nobody is asked mid-run, and the report says no wait happened")
    func noWaitByDefault() async throws {
        let script = script()
        let report = try await run(script)
        #expect(!report.waitedForTurnstile)
        #expect(script.asks.isEmpty)
    }

    @Test("a wait on a checking widget or a disabled submit button is named once, with its bound")
    func waitsAreNamed() async throws {
        let checking = script()
        checking.phases = [.absent, .checking]
        await #expect(throws: LoginFailure.self) { try await self.run(checking, timeout: 2) }
        #expect(checking.shownSteps == ["Waiting up to 2 s for Turnstile to finish checking"])

        let disabled = script(buttonEnabled: false)
        await #expect(throws: LoginFailure.self) { try await self.run(disabled, timeout: 2) }
        #expect(disabled.shownSteps == ["Waiting up to 2 s for the submit button to enable"])
    }

    @Test("the check before the saved login is read stops on an unticked box and passes a clear screen")
    func preflight() async throws {
        let stopped = script()
        stopped.phases = [.ready(square)]
        let error = try #require(await #expect(throws: CLIError.self) { try await LoginFlow.preflight(stopped.read(), wait: nil, services: stopped.services) })
        #expect(error.reason == .turnstileRequired)
        #expect(error.userFacingDescription.contains("Nothing was typed."))

        let clear = script()
        clear.phases = [.absent]
        try await LoginFlow.preflight(clear.read(), wait: nil, services: clear.services)
        #expect(clear.typed.isEmpty)
    }

    @Test("the watchdog's bound covers a person's wait, and a login with none stays near a minute")
    func boundCoversTheWait() {
        #expect(LoginCommand.bound(timeout: 15, waitTurnstile: nil) < 90)
        #expect(LoginCommand.bound(timeout: 15, waitTurnstile: 300) == LoginCommand.bound(timeout: 15, waitTurnstile: nil) + 300)
    }

    private var square: TurnstileTarget {
        TurnstileTarget(frame: UIFrame(x: 18, y: 400, width: 30, height: 30))
    }

    private func script(buttonEnabled: Bool = true) -> LoginScript {
        let bullets = String(repeating: String(SecureText.bullet), count: password.count)
        return LoginScript(trees: [
            SignInFixture.tree(),
            SignInFixture.tree(emailValue: username),
            SignInFixture.tree(emailValue: username, passwordValue: bullets, submitEnabled: buttonEnabled),
        ])
    }

    private func run(_ script: LoginScript, timeout: TimeInterval = 15, waitTurnstile: TimeInterval? = nil) async throws -> LoginReport {
        let credential = try #require(LoginCredential(username: username, password: password))
        return try await LoginFlow.run(
            app: "com.example.app", key: "dev", credential: credential, profile: nil, timeout: timeout,
            turnstileWait: waitTurnstile.map(LoginFlow.TurnstileWait.init(seconds:)), services: script.services
        )
    }
}
