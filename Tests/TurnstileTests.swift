import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Turnstile")
struct TurnstileTests {
    private let screen = UIFrame(x: 0, y: 0, width: 411, height: 923)

    private func node(
        role: UIRole, id: String? = nil, label: String? = nil, value: String? = nil, frame: UIFrame? = nil, children: [UINode] = []
    ) -> UINode {
        UINode(role: role, id: id, label: label, value: value, frame: frame, native: .android(AndroidNativeAttributes()), children: children)
    }

    /// The login widget measured on the Pixel 9: the checkbox frame includes the words, and the square is at its leading edge.
    private func checkboxWidget() -> UINode {
        let widget = UIFrame(x: 24, y: 369.14, width: 364.95, height: 65.9)
        let checkbox = UIFrame(x: 32, y: 388.95, width: 163.81, height: 25.14)
        let logo = UIFrame(x: 305.9, y: 380.95, width: 73.9, height: 30.86)
        return node(role: .group, id: "turnstile-widget", frame: widget, children: [
            node(role: .group, id: "cf-chl-widget-5mta5", frame: widget, children: [
                node(role: .group, label: "Checking your Browser…", frame: widget, children: [
                    node(role: .checkbox, label: "Verify you are human", frame: checkbox),
                    node(role: .button, label: "Cloudflare, opens in a new tab", frame: logo),
                ]),
            ]),
        ])
    }

    private func roots(_ children: [UINode]) -> [UINode] {
        [node(role: .application, label: "App", frame: screen, children: children)]
    }

    @Test("a checkbox reads as ready with its frame, the words included")
    func checkboxIsReady() {
        let phase = TurnstileWidget.phase(in: roots([checkboxWidget()]), viewport: screen)
        #expect(phase == .ready(TurnstileTarget(frame: UIFrame(x: 32, y: 388.95, width: 163.81, height: 25.14))))
    }

    @Test("Success is already passed, and a tall widget with no checkbox is a visual challenge")
    func successAndChallenge() {
        let passed = node(role: .group, id: "cf-chl-widget-9jc94", frame: UIFrame(x: 24, y: 431, width: 365, height: 66), children: [
            node(role: .group, id: "a1b2c3", label: "Success!", frame: UIFrame(x: 32, y: 448, width: 93, height: 31)),
            node(role: .text, label: "For testing only. If seen, report to site owner", frame: UIFrame(x: 24, y: 482, width: 365, height: 15)),
        ])
        #expect(TurnstileWidget.phase(in: roots([passed]), viewport: screen) == .passed)

        let grid = node(role: .group, id: "cf-chl-widget-grid", frame: UIFrame(x: 24, y: 300, width: 365, height: 280), children: [
            node(role: .text, label: "Select all squares with a bus", frame: UIFrame(x: 24, y: 300, width: 365, height: 40)),
        ])
        #expect(TurnstileWidget.phase(in: roots([grid]), viewport: screen) == .visualChallenge)
    }

    @Test("a widget that is still checking, and a screen with no widget")
    func checkingAndAbsent() {
        let checking = node(role: .group, id: "cf-chl-widget-wait", frame: UIFrame(x: 24, y: 369, width: 365, height: 66), children: [
            node(role: .group, label: "Checking your Browser…", frame: UIFrame(x: 24, y: 369, width: 365, height: 66)),
        ])
        #expect(TurnstileWidget.phase(in: roots([checking]), viewport: screen) == .checking)
        #expect(TurnstileWidget.phase(in: roots([node(role: .button, label: "Log in", frame: UIFrame(x: 16, y: 791, width: 379, height: 44))]), viewport: screen) == .absent)
    }

    @Test("two checkboxes are ambiguous, and --id keeps the one inside that wrapper")
    func scopeAndAmbiguity() {
        let first = node(role: .group, id: "login", frame: UIFrame(x: 0, y: 0, width: 400, height: 400), children: [checkboxWidget()])
        let second = node(role: .group, id: "other", frame: UIFrame(x: 0, y: 500, width: 400, height: 200), children: [
            node(role: .group, id: "cf-chl-widget-other", frame: UIFrame(x: 24, y: 520, width: 300, height: 66), children: [
                node(role: .checkbox, label: "Verify you are human", frame: UIFrame(x: 32, y: 540, width: 160, height: 25)),
            ]),
        ])
        #expect(TurnstileWidget.phase(in: roots([first, second]), viewport: screen) == .ambiguous(2))
        guard case .ready = TurnstileWidget.phase(in: roots([first, second]), viewport: screen, scopeID: "login") else {
            Issue.record("the login wrapper should hold one checkbox")
            return
        }
    }

    @Test("a checkbox with the prompt is found when the container id is missing")
    func fallbackPrompt() {
        let box = node(role: .checkbox, label: "Verify you are human", frame: UIFrame(x: 32, y: 389, width: 164, height: 25))
        #expect(TurnstileWidget.phase(in: roots([box]), viewport: screen) == .ready(TurnstileTarget(frame: UIFrame(x: 32, y: 389, width: 164, height: 25))))
    }

    @Test("without a checkbox, Success or checking words beside the Cloudflare logo are the widget")
    func fallbackSuccessAndChecking() {
        let logo = node(role: .button, label: "Cloudflare, opens in a new tab", frame: UIFrame(x: 306, y: 381, width: 74, height: 31))
        let success = node(role: .text, label: "Success!", frame: UIFrame(x: 69, y: 389, width: 59, height: 19))
        let verifying = node(role: .text, label: "Verifying...", frame: UIFrame(x: 69, y: 389, width: 70, height: 19))
        #expect(TurnstileWidget.phase(in: roots([success, logo]), viewport: screen) == .passed)
        #expect(TurnstileWidget.phase(in: roots([verifying, logo]), viewport: screen) == .checking)
        #expect(TurnstileWidget.phase(in: roots([success]), viewport: screen) == .absent)
    }

    @Test("a tall app wrapper that is still loading is checking, not a visual challenge")
    func tallWrapperIsNotAChallenge() {
        let wrapper = node(role: .group, id: "turnstile-widget", frame: UIFrame(x: 16, y: 300, width: 380, height: 220))
        #expect(TurnstileWidget.phase(in: roots([wrapper]), viewport: screen) == .checking)
        let expanded = node(role: .group, id: "cf-chl-widget-big", frame: UIFrame(x: 16, y: 300, width: 380, height: 420))
        #expect(TurnstileWidget.phase(in: roots([expanded]), viewport: screen) == .visualChallenge)
    }

    @Test("an iOS web view inside a turnstile-widget wrapper is probed by point reads and sends nothing")
    @MainActor
    func iosWrapperIsProbedNotTapped() async throws {
        let shell = UIFrame(x: 16, y: 375, width: 370, height: 80)
        let children = [
            node(role: .group, frame: shell),
            node(role: .link, label: "Cloudflare, opens in a new tab", frame: UIFrame(x: 296, y: 395, width: 73, height: 26)),
            node(role: .slider, label: "Vertical scroll bar, 2 pages", frame: UIFrame(x: 353, y: 375, width: 30, height: 80)),
        ]
        let wrapper = node(role: .group, id: "turnstile-widget", frame: shell, children: [node(role: .scrollView, frame: shell, children: children)])
        let page = UITree(platform: .ios, device: "fake-device", roots: roots([wrapper]))
        let backend = FakeDeviceBackend(trees: [page])
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "fake-device", platform: .ios))

        let status = try await Turnstile.parse(["--device", "x"]).readStatus(on: route)

        #expect(status.state == .checkbox)
        #expect(status.source == .webViewPoints)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a Turnstile web view with its widget hidden at no height is no widget, not absent")
    func webViewWithNoWidget() {
        let viewport = UIFrame(x: 0, y: 0, width: 393, height: 852)
        let hidden = FakeUI.node(.group, id: "turnstile-widget", frame: FakeUI.frame(20, 400, 300, 0))
        let view = FakeUI.node(.group, id: "signin-turnstile", frame: FakeUI.frame(20, 400, 300, 70), children: [hidden])
        #expect(TurnstileWidget.phase(in: [view], viewport: viewport) == .noWidget)
        #expect(TurnstileStatus(phase: .noWidget, source: .tree)?.state == .unknown)
        #expect(TurnstileStatus(phase: .noWidget, source: .tree)?.textLine().hasPrefix("Turnstile: unknown. ") == true)
        #expect(TurnstileStatus(phase: .noWidget, source: .tree)?.jsonLine() == #"{"version":1,"state":"unknown","source":"tree","frame":null}"#)
    }

    @Test("login past a web view with no widget says so, in its text and JSON")
    func loginReportsUnknown() {
        let report = LoginReport(app: "com.example.app", key: "default", turnstile: .unknown, submitLabel: "Sign in")
        #expect(report.textLine().hasSuffix(TurnstileStatus.unknownNote))
        #expect(report.jsonLine().contains(#""turnstile":"unknown""#))
        #expect(!LoginReport(app: "com.example.app", key: "default", turnstile: .absent, submitLabel: "Sign in").textLine().contains("Turnstile"))
    }

    @Test("a hidden or off-screen web view, or a screen that never names Turnstile, stays absent")
    func noWebViewStaysAbsent() {
        let viewport = UIFrame(x: 0, y: 0, width: 393, height: 852)
        let hidden = FakeUI.node(.group, id: "turnstile-widget", frame: FakeUI.frame(20, 400, 300, 0))
        let parked = FakeUI.node(.group, id: "signin-turnstile", frame: FakeUI.frame(20, 2000, 300, 70))
        let other = FakeUI.node(.button, id: "submit", frame: FakeUI.frame(20, 400, 300, 44))
        #expect(TurnstileWidget.phase(in: [hidden, parked, other], viewport: viewport) == .absent)
    }

    @Test("a widget inside the web view is read as before")
    func webViewWithWidget() {
        let viewport = UIFrame(x: 0, y: 0, width: 393, height: 852)
        let box = FakeUI.node(.checkbox, label: "Verify you are human", frame: FakeUI.frame(30, 410, 200, 30))
        let view = FakeUI.node(.group, id: "signin-turnstile", frame: FakeUI.frame(20, 400, 300, 70), children: [box])
        guard case .ready = TurnstileWidget.phase(in: [view], viewport: viewport) else {
            Issue.record("expected the checkbox")
            return
        }
    }

    @Test("an off-screen widget is ignored")
    func offScreenIgnored() {
        let parked = node(role: .group, id: "cf-chl-widget-old", frame: UIFrame(x: 24, y: 2000, width: 365, height: 66), children: [
            node(role: .checkbox, label: "Verify you are human", frame: UIFrame(x: 32, y: 2020, width: 164, height: 25)),
        ])
        #expect(TurnstileWidget.phase(in: roots([parked]), viewport: screen) == .absent)
    }

    /// The web view measured on a simulator. The green check was a 30pt circle centred at (47.8, 415.5).
    private func iosWebView() -> UINode {
        let shell = UIFrame(x: 16, y: 375, width: 370, height: 80)
        return node(role: .scrollView, frame: shell, children: [
            node(role: .group, frame: shell),
            node(role: .slider, label: "Vertical scroll bar, 2 pages", value: "0%", frame: UIFrame(x: 353, y: 375, width: 30, height: 80)),
        ])
    }

    @Test("an iOS web view is not in the tree, and its checkbox frame is the green check")
    func iosWebViewFindsTheGreenCheck() {
        let shell = iosWebView()
        let page = node(role: .scrollView, frame: UIFrame(x: 0, y: 0, width: 402, height: 722), children: [
            node(role: .slider, label: "Vertical scroll bar, 1 page", frame: UIFrame(x: 369, y: 62, width: 30, height: 660)),
        ])
        #expect(TurnstileWidget.phase(in: roots([page, shell]), viewport: screen) == .absent)

        let shells = TurnstileWidget.iosShells(in: roots([page, shell]), viewport: screen)
        #expect(shells.count == 1)
        let frame = shells[0]
        let centre = TurnstileWidget.iosTarget(frame).frame.center
        #expect(abs(centre.x - 48) < 0.01)
        #expect(abs(centre.y - 415) < 0.01)

        let probes = TurnstileWidget.probePoints(in: frame)
        #expect(abs(probes.status.x - 96) < 0.01)
        #expect(abs(probes.logo.x - 332) < 0.01)
    }

    @Test("an iOS point read uses the value")
    func iosPointRead() {
        let shell = UIFrame(x: 16, y: 375, width: 370, height: 80)
        let success = node(role: .text, label: "", value: "Success!", frame: UIFrame(x: 69, y: 406, width: 59, height: 19))
        let verifying = node(role: .text, value: "Verifying...", frame: UIFrame(x: 69, y: 406, width: 70, height: 19))
        let logo = node(role: .link, label: "Cloudflare, opens in a new tab", frame: UIFrame(x: 296, y: 395, width: 73, height: 26))
        let prompt = node(role: .text, value: "Verify you are human", frame: UIFrame(x: 69, y: 406, width: 140, height: 19))

        #expect(TurnstileWidget.reading(in: [success]) == .passed)
        #expect(TurnstileWidget.reading(in: [verifying]) == .checking)
        #expect(TurnstileWidget.reading(in: [logo]) == .logo)
        #expect(TurnstileWidget.reading(in: [prompt]) == .prompt)
        #expect(TurnstileWidget.phase(shell: shell, status: .passed, logo: .logo) == .passed)
        #expect(TurnstileWidget.phase(shell: shell, status: .checking, logo: .logo) == .checking)
        #expect(TurnstileWidget.phase(shell: shell, status: .prompt, logo: .logo) == .ready(TurnstileWidget.iosTarget(shell)))
        #expect(TurnstileWidget.phase(shell: shell, status: .unrelated, logo: .unrelated) == .absent)
        let parked = node(role: .scrollView, frame: UIFrame(x: 16, y: 2000, width: 370, height: 80), children: [
            node(role: .slider, label: "Vertical scroll bar, 2 pages", frame: UIFrame(x: 353, y: 2000, width: 30, height: 80)),
        ])
        #expect(TurnstileWidget.iosShells(in: roots([parked]), viewport: screen).isEmpty)
    }

    @Test("the removed tap options exit 64 and say turnstile only reads", arguments: ["--timeout", "--poll-interval", "--jitter", "--seed"])
    func removedOptionsAreUsageErrors(option: String) {
        let hint = ArgumentHints.hint(for: ["turnstile", option, "2", "--device", "emulator-5554"])
        #expect(hint == ArgumentHints.Hint(message: "turnstile no longer taps; it reads the widget's state. A checkbox or challenge is for a person: --wait <seconds> carries on when it passes.", isLegacy: false))
        #expect(FailureReason.usage.exitCode.rawValue == 64)
        #expect(throws: (any Error).self) { try Turnstile.parse([option, "2", "--device", "emulator-5554"]) }
    }

    @Test("login --turnstile is gone and exits 64 with the hand-back rule")
    func loginTurnstileOptionIsGone() {
        let hint = ArgumentHints.hint(for: ["login", "dev", "--turnstile", "off", "--device", "emulator-5554"])
        #expect(hint?.isLegacy == false)
        #expect(hint?.message.contains("turnstile_required") == true)
        #expect(throws: (any Error).self) { try LoginCommand.parse(["dev", "--turnstile", "off", "--device", "emulator-5554"]) }
    }

    @Test("--status still parses for one release, and an empty --id is a usage error")
    func statusAndID() throws {
        #expect(try Turnstile.parse(["--status", "--device", "emulator-5558"]).status)
        #expect(parseMessage(["--id", " "]).contains("--id must not be empty"))
    }

    private func parseMessage(_ arguments: [String]) -> String {
        do {
            _ = try Turnstile.parse(["--device", "emulator-5558"] + arguments)
            return ""
        } catch {
            return String(describing: error)
        }
    }

    @Test("--status maps each phase to a state, keeps the checkbox frame, and leaves ambiguous to exit 6")
    func statusMapping() {
        let frame = UIFrame(x: 32, y: 388.95, width: 163.81, height: 25.14)
        let checkbox = TurnstileStatus(phase: .ready(TurnstileTarget(frame: frame)), source: .tree)
        #expect(checkbox == TurnstileStatus(state: .checkbox, source: .tree, frame: frame))
        #expect(checkbox?.textLine() == "Turnstile: checkbox at (32, 388.95) 163.81x25.14")
        #expect(checkbox?.jsonLine() == #"{"version":1,"state":"checkbox","source":"tree","frame":{"x":32,"y":388.95,"width":163.81,"height":25.14}}"#)
        #expect(TurnstileStatus(phase: .checking, source: .webViewPoints)?.state == .verifying)
        #expect(TurnstileStatus(phase: .passed, source: .tree)?.jsonLine() == #"{"version":1,"state":"passed","source":"tree","frame":null}"#)
        #expect(TurnstileStatus(phase: .visualChallenge, source: .tree)?.state == .challenge)
        #expect(TurnstileStatus(phase: .absent, source: .tree)?.textLine() == "Turnstile: absent")
        #expect(TurnstileStatus(phase: .ambiguous(2), source: .tree) == nil)
    }

    @Test("--status reads a checkbox and sends no input")
    @MainActor
    func statusSendsNothing() async throws {
        let backend = FakeDeviceBackend(trees: [UITree(platform: .android, device: "emulator-5554", roots: roots([checkboxWidget()]))])
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))

        let status = try await Turnstile.parse(["--status", "--device", "emulator-5554"]).readStatus(on: route)

        #expect(status.state == .checkbox)
        #expect(backend.session.calls.isEmpty)
        #expect(backend.openedSessions.isEmpty)
    }

    @Test("a visual challenge reads as challenge, exits 0 and sends nothing")
    @MainActor
    func challengeIsOnlyRead() async throws {
        let grid = node(role: .group, id: "cf-chl-widget-grid", frame: UIFrame(x: 24, y: 300, width: 365, height: 280), children: [
            node(role: .text, label: "Select all squares with a bus", frame: UIFrame(x: 24, y: 300, width: 365, height: 40)),
        ])
        let backend = FakeDeviceBackend(trees: [UITree(platform: .android, device: "emulator-5554", roots: roots([grid]))])
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))
        let status = try await Turnstile.parse(["--device", "emulator-5554"]).readStatus(on: route)
        #expect(status.state == .challenge)
        #expect(backend.session.calls.isEmpty)
        #expect(backend.openedSessions.isEmpty)
    }

    private func status(_ state: TurnstileStatus.State) -> TurnstileStatus {
        TurnstileStatus(state: state, source: .tree)
    }

    /// Serves `states` in order, holding the last, on a clock that only sleeps move.
    @MainActor
    private func waiting(_ states: [TurnstileStatus.State], seconds: TimeInterval = 60) async throws -> (status: TurnstileStatus, reads: Int, clock: ScriptedClock) {
        let clock = ScriptedClock()
        var reads = 0
        let result = try await Turnstile.waitForPerson(seconds: seconds, clock: clock.poll) {
            defer { reads += 1 }
            return status(states[min(reads, states.count - 1)])
        }
        return (result, reads, clock)
    }

    @Test("--wait keeps reading through the person's step and returns the moment it passes")
    @MainActor
    func waitReturnsOnPassed() async throws {
        let result = try await waiting([.checkbox, .checkbox, .verifying, .challenge, .passed])
        #expect(result.status.state == .passed)
        #expect(result.reads == 5)
        #expect(result.clock.now == 4)
    }

    @Test("--wait on a screen with no widget ends, but a reload mid-tick does not", arguments: [TurnstileStatus.State.absent, .unknown])
    @MainActor
    func waitNeedsTheWidgetGoneTwice(gone: TurnstileStatus.State) async throws {
        let settled = try await waiting([.checkbox, gone, gone])
        #expect(settled.status.state == gone)
        #expect(settled.reads == 3)

        let reloaded = try await waiting([.checkbox, gone, .checkbox, .passed])
        #expect(reloaded.status.state == .passed)
    }

    @Test("--wait hands back the open step at the deadline, and reads no further")
    @MainActor
    func waitStopsAtTheDeadline() async throws {
        let result = try await waiting([.checkbox], seconds: 3)
        #expect(result.status.state == .checkbox)
        #expect(result.status.state.awaitsPerson)
        #expect(result.reads == 4)
        #expect(result.clock.now == 3)
    }

    @Test("--wait 0 reads once and gives a settled state as it is")
    @MainActor
    func waitZeroReadsOnce() async throws {
        let result = try await waiting([.absent], seconds: 0)
        #expect(result.status.state == .absent)
        #expect(result.reads == 1)
    }

    private struct ReadBlip: TransientFailure, Error {
        var isTransient: Bool { true }
    }

    @Test("--wait rides out a read that fails for a moment, and gives up only when none ever worked")
    @MainActor
    func waitRidesOutTransientFailures() async throws {
        let clock = ScriptedClock()
        var reads = 0
        let recovered = try await Turnstile.waitForPerson(seconds: 60, clock: clock.poll) {
            reads += 1
            if reads == 1 { throw ReadBlip() }
            return status(.passed)
        }
        #expect(recovered.state == .passed)
        await #expect(throws: ReadBlip.self) {
            _ = try await Turnstile.waitForPerson(seconds: 2, clock: clock.poll) { throw ReadBlip() }
        }
    }

    @Test("a read that fails at the deadline still says the step is open")
    @MainActor
    func waitKeepsTheOpenStepThroughABlip() async throws {
        let clock = ScriptedClock()
        var reads = 0
        let result = try await Turnstile.waitForPerson(seconds: 1, clock: clock.poll) {
            reads += 1
            if reads > 1 { throw ReadBlip() }
            return status(.checkbox)
        }
        #expect(result.state == .checkbox)
    }

    private struct OtherAppInFront: OtherAppFailure {
        var isOtherAppInFront: Bool { true }
    }

    private func inTheWay(otherApp: Bool) -> Error {
        otherApp ? OtherAppInFront() : CLIError(errorDescription: "Locked.", reason: .deviceLocked)
    }

    @Test("a phone's other app or lock screen holds the wait until the tick", arguments: [true, false])
    @MainActor
    func waitRidesOutThePersonOnTheirWay(otherApp: Bool) async throws {
        let clock = ScriptedClock()
        var reads = 0
        let result = try await Turnstile.waitForPerson(seconds: 60, clock: clock.poll) {
            reads += 1
            if reads == 2 { throw inTheWay(otherApp: otherApp) }
            return status(reads == 1 ? .checkbox : .passed)
        }
        #expect(result.state == .passed)
        #expect(reads == 3)
    }

    @Test("a phone's other app or lock screen still there at the deadline is the answer, not a tick nobody did", arguments: [true, false])
    @MainActor
    func waitReportsWhatIsStillInTheWay(otherApp: Bool) async throws {
        let clock = ScriptedClock()
        var reads = 0
        let error = try #require(await #expect(throws: (any Error).self) {
            _ = try await Turnstile.waitForPerson(seconds: 2, clock: clock.poll) {
                reads += 1
                if reads > 1 { throw inTheWay(otherApp: otherApp) }
                return status(.checkbox)
            }
        })
        #expect(error.isOtherAppInFront == otherApp)
        #expect(otherApp || (error as? CLIError)?.reason == .deviceLocked)
    }

    @Test("another app holding the wait up is said once, and a lock screen or a single read says nothing")
    @MainActor
    func waitNotesAnotherAppOnce() async throws {
        var notes = 0
        var reads = 0
        _ = try await Turnstile.waitForPerson(seconds: 60, clock: ScriptedClock().poll, onOtherApp: { notes += 1 }) {
            reads += 1
            if reads <= 2 { throw inTheWay(otherApp: true) }
            if reads == 3 { return status(.checkbox) }
            if reads == 4 { throw inTheWay(otherApp: true) }
            return status(.passed)
        }
        #expect(notes == 1)

        notes = 0
        reads = 0
        _ = try await Turnstile.waitForPerson(seconds: 60, clock: ScriptedClock().poll, onOtherApp: { notes += 1 }) {
            reads += 1
            if reads == 1 { throw inTheWay(otherApp: false) }
            return status(.passed)
        }
        #expect(notes == 0)

        await #expect(throws: (any Error).self) {
            _ = try await Turnstile.waitForPerson(seconds: 0, clock: ScriptedClock().poll, onOtherApp: { notes += 1 }) { throw inTheWay(otherApp: true) }
        }
        #expect(notes == 0)
    }

    @Test("--wait stops at once on a failure that will not clear, such as an app the phone never allows", arguments: [
        CLIError.deviceNotFound(id: "emulator-5554"),
        CLIError(errorDescription: "Not among the apps allowed.", reason: .appNotAllowed),
    ])
    @MainActor
    func waitStopsOnFatalFailure(failure: CLIError) async throws {
        let clock = ScriptedClock()
        var reads = 0
        await #expect(throws: CLIError.self) {
            _ = try await Turnstile.waitForPerson(seconds: 60, clock: clock.poll) {
                reads += 1
                throw failure
            }
        }
        #expect(reads == 1)
    }

    @Test("--wait running out exits 5, says nobody did it, and carries the ask and the same wait", arguments: [
        (TurnstileStatus.State.checkbox, "nobody has ticked it", PersonAsk.tickTurnstile),
        (TurnstileStatus.State.challenge, "nobody has solved it", PersonAsk.solveTurnstile),
        (TurnstileStatus.State.verifying, "still checking", PersonAsk.finishTurnstile),
    ])
    func waitRunningOut(state: TurnstileStatus.State, says: String, ask: String) {
        let error = Turnstile.stepStillOpen(state, seconds: 90, app: nil)
        #expect(error.exitCode.rawValue == 5)
        #expect(error.userFacingDescription.contains(says))
        #expect(error.userFacingDescription.contains("after 90 s"))
        #expect(error.userFacingDescription.contains("Nothing was sent."))
        #expect(error.ask == ask)
        #expect(error.hint == "offsider turnstile --wait 600 --device <DEVICE_ID>")
    }

    @Test("a wait on a phone names its app, as every command there must")
    func waitNamesThePhonesApp() {
        #expect(Turnstile.waitCommand(app: "com.example.app") == "offsider turnstile --wait 600 --device <DEVICE_ID> --app com.example.app")
        #expect(Turnstile.stepStillOpen(.checkbox, seconds: 5, app: "com.example.app").hint?.hasSuffix("--app com.example.app") == true)
    }

    @Test("--wait takes 0 to 900 seconds")
    func waitBounds() throws {
        #expect(try Turnstile.parse(["--wait", "0", "--device", "emulator-5558"]).waitSeconds == 0)
        #expect(try Turnstile.parse(["--wait", "900", "--device", "emulator-5558"]).waitSeconds == 900)
        #expect(parseMessage(["--wait", "901"]).contains("--wait must be from 0 to 900"))
        #expect(parseMessage(["--wait=-1"]).contains("--wait must be from 0 to 900"))
    }

    @Test("--wait on a device reads until it passes and sends no input")
    @MainActor
    func waitSendsNothing() async throws {
        let passed = node(role: .group, id: "cf-chl-widget-9jc94", frame: UIFrame(x: 24, y: 431, width: 365, height: 66), children: [
            node(role: .group, id: "a1b2c3", label: "Success!", frame: UIFrame(x: 32, y: 448, width: 93, height: 31)),
        ])
        let backend = FakeDeviceBackend(trees: [
            UITree(platform: .android, device: "emulator-5554", roots: roots([checkboxWidget()])),
            UITree(platform: .android, device: "emulator-5554", roots: roots([passed])),
        ])
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))
        let command = try Turnstile.parse(["--wait", "30", "--device", "emulator-5554"])

        let status = try await command.readStatus(on: route, clock: ScriptedClock().poll)

        #expect(status.state == .passed)
        #expect(backend.treeReads == 2)
        #expect(backend.session.calls.isEmpty)
        #expect(backend.openedSessions.isEmpty)
    }

    @Test("--wait on a device that nobody ticks exits 5 and sends no input")
    @MainActor
    func waitRunsOutOnDevice() async throws {
        let backend = FakeDeviceBackend(trees: [UITree(platform: .android, device: "emulator-5554", roots: roots([checkboxWidget()]))])
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))
        let command = try Turnstile.parse(["--wait", "2", "--device", "emulator-5554"])

        let error = try #require(await #expect(throws: CLIError.self) { try await command.readStatus(on: route, clock: ScriptedClock().poll) })

        #expect(error.reason == .conditionNotMet)
        #expect(error.ask == PersonAsk.tickTurnstile)
        #expect(backend.session.calls.isEmpty)
    }
}
