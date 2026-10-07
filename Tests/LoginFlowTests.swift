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
        let report = try await run(script, mode: .auto)
        #expect(script.typed == [username, password])
        #expect(script.performs == 0)
        #expect(script.taps.count == 1)
        #expect(report.turnstile == .passed)
        #expect(!report.textLine().contains(password))
        #expect(!report.textLine().contains(username))
        #expect(!report.jsonLine().contains(password))
        #expect(report.jsonLine().contains("\"password\":\"filled\""))
        #expect(report.textLine().contains("The submit button was tapped."))
        #expect(report.textLine().contains("does not mean the server accepted the login."))
    }

    @Test("a checkbox is tapped, and a second checkbox after a reload is tapped once more")
    func checkboxThenSubmit() async throws {
        let script = script(buttonEnabled: true)
        script.phases = [.ready(square), .passed]
        let report = try await run(script, mode: .auto)
        #expect(script.performs == 1)
        #expect(script.taps.count == 1)
        #expect(report.turnstile == .tapped)

        let reload = script
        reload.phases = [.ready(square), .ready(square)]
        reload.phaseIndex = 0
        reload.performs = 0
        reload.taps = []
        reload.typed = []
        reload.index = 0
        let again = try await run(reload, mode: .auto)
        #expect(reload.performs == 2)
        #expect(again.turnstile == .tapped)
        #expect(reload.taps.count == 1)
    }

    @Test("a visual challenge taps nothing further")
    func challengeStops() async {
        let script = script(buttonEnabled: true)
        script.phases = [.visualChallenge]
        await #expect(throws: CLIError.self) { try await self.run(script, mode: .auto) }
        #expect(script.typed == [username, password])
        #expect(script.performs == 0)
        #expect(script.taps.isEmpty)
    }

    @Test("a profile for another app types nothing")
    func profileMismatch() async {
        let script = script(buttonEnabled: true)
        let profile = LoginProfile(appID: "com.other.app")
        await #expect(throws: CLIError.self) { try await self.run(script, mode: .auto, profile: profile) }
        #expect(script.typed.isEmpty)
        #expect(script.taps.isEmpty)
    }

    @Test("a disabled submit button is not tapped")
    func disabledSubmit() async {
        let script = script(buttonEnabled: false)
        await #expect(throws: CLIError.self) { try await self.run(script, mode: .off, timeout: 0) }
        #expect(script.sleeps == 0)
        #expect(script.taps.isEmpty)
        #expect(script.performs == 0)
    }

    @Test("an off-screen input assistant does not block the submit tap")
    func assistantDoesNotBlockSubmit() async throws {
        let script = script(buttonEnabled: true, assistant: true)
        script.phases = [.passed]
        let report = try await run(script, mode: .auto)
        #expect(script.taps.count == 1)
        #expect(script.performs == 0)
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
        let report = try await run(script, mode: .auto)
        #expect(script.hides == 1)
        #expect(script.typed == [username, password])
        #expect(report.turnstile == .passed)
    }

    @Test("a keyboard with no safe point does not reach Turnstile or submit")
    func keyboardCoversSubmit() async {
        let script = script(buttonEnabled: true, keyboard: true)
        await #expect(throws: CLIError.self) { try await self.run(script, mode: .auto) }
        #expect(script.taps.isEmpty)
        #expect(script.performs == 0)
        #expect(script.phaseIndex == 0)
    }

    private var square: TurnstileTarget {
        TurnstileTarget(frame: UIFrame(x: 18, y: 400, width: 30, height: 30), logoOnRight: true)
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

    private func run(_ script: LoginScript, mode: LoginTurnstileMode, profile: LoginProfile? = nil, timeout: TimeInterval = 15) async throws -> LoginReport {
        let credential = try #require(LoginCredential(username: username, password: password))
        return try await LoginFlow.run(
            app: "com.example.app",
            key: "dev",
            credential: credential,
            profile: profile,
            turnstile: mode,
            timeout: timeout,
            services: script.services
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
    var performs = 0
    var sleeps = 0
    var hides = 0
    var advanceOnHide = false
    var time: TimeInterval = 0

    init(trees: [UITree]) {
        self.trees = trees
    }

    func read() -> UITree { trees[min(index, trees.count - 1)] }

    func type(_ text: String, _: UINode) {
        typed.append(text)
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
            tap: { point, _ in self.taps.append(point) },
            readTurnstile: {
                let phase = self.phases[min(self.phaseIndex, self.phases.count - 1)]
                self.phaseIndex += 1
                return phase
            },
            performTurnstile: {
                self.performs += 1
                return TurnstileReport(outcome: .tapped)
            },
            hideKeyboard: { self.hide() },
            clock: PollClock(
                now: { self.time },
                sleep: { duration in
                    self.sleeps += 1
                    let parts = duration.components
                    self.time += Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                }
            )
        )
    }
}
