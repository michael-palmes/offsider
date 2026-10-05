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

    @Test("the tap lands on the checkbox square, not the centre of its label")
    func aimHitsTheSquare() throws {
        let phase = TurnstileWidget.phase(in: roots([checkboxWidget()]), viewport: screen)
        guard case .ready(let target) = phase else {
            Issue.record("expected a checkbox, got \(phase)")
            return
        }
        let point = TurnstileWidget.aim(target)
        let centre = target.frame.center

        #expect(abs(point.x - 44.57) < 0.01)
        #expect(abs(point.y - 401.52) < 0.01)
        #expect(abs(point.x - centre.x) > 60)
    }

    @Test("a large offset stays on the square")
    func jitterStaysOnTheSquare() throws {
        let frame = UIFrame(x: 32, y: 388.95, width: 163.81, height: 25.14)
        let target = TurnstileTarget(frame: frame, logoOnRight: true)
        let point = TurnstileWidget.aim(target, offset: UIPoint(x: 100, y: -100), maxJitter: 8)

        #expect(point.x > frame.x)
        #expect(point.x < frame.x + frame.height)
        #expect(point.y > frame.y)
        #expect(point.y < frame.y + frame.height)
        #expect(point.x < 80)
    }

    @Test("a logo on the left puts the square on the trailing edge")
    func rightToLeftSquare() {
        let frame = UIFrame(x: 200, y: 400, width: 160, height: 25)
        let point = TurnstileWidget.aim(TurnstileTarget(frame: frame, logoOnRight: false))
        #expect(abs(point.x - 347.5) < 0.01)
        #expect(abs(point.y - 412.5) < 0.01)
    }

    @Test("Success is already passed, and a tall widget with no checkbox is a visual challenge")
    func successAndChallenge() {
        let passed = node(role: .group, id: "cf-chl-widget-9jc94", frame: UIFrame(x: 24, y: 431, width: 365, height: 66), children: [
            node(role: .group, id: "tnTQi5", label: "Success!", frame: UIFrame(x: 32, y: 448, width: 93, height: 31)),
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
        guard case .ready(let target) = TurnstileWidget.phase(in: roots([box]), viewport: screen) else {
            Issue.record("expected the prompt checkbox")
            return
        }
        #expect(target.logoOnRight)
        #expect(TurnstileWidget.aim(target).x < 60)
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

    @Test("an iOS web view inside a turnstile-widget wrapper is probed and tapped")
    @MainActor
    func iosWrapperIsProbedAndTapped() async throws {
        let shell = UIFrame(x: 16, y: 375, width: 370, height: 80)
        func page(status: UINode?) -> UITree {
            let children = [
                node(role: .group, frame: shell),
                node(role: .link, label: "Cloudflare, opens in a new tab", frame: UIFrame(x: 296, y: 395, width: 73, height: 26)),
                node(role: .slider, label: "Vertical scroll bar, 2 pages", frame: UIFrame(x: 353, y: 375, width: 30, height: 80)),
            ] + [status].compactMap { $0 }
            let wrapper = node(role: .group, id: "turnstile-widget", frame: shell, children: [
                node(role: .scrollView, frame: shell, children: children),
            ])
            return UITree(platform: .ios, device: "fake-device", roots: roots([wrapper]))
        }
        let passed = node(role: .text, value: "Success!", frame: UIFrame(x: 69, y: 406, width: 59, height: 19))
        let backend = FakeDeviceBackend(trees: [page(status: nil), page(status: passed)], advanceTreeOnInput: true)
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "fake-device", platform: .ios))

        let report = try await Turnstile.parse(["--device", "x", "--jitter", "0", "--timeout", "2", "--poll-interval", "0.05"])
            .perform(on: route, logger: OffsiderLogger())

        #expect(report.outcome == .tapped)
        #expect(backend.session.calls == [.perform(.tapAt(x: 48, y: 415))])
    }

    @Test("an off-screen widget is ignored")
    func offScreenIgnored() {
        let parked = node(role: .group, id: "cf-chl-widget-old", frame: UIFrame(x: 24, y: 2000, width: 365, height: 66), children: [
            node(role: .checkbox, label: "Verify you are human", frame: UIFrame(x: 32, y: 2020, width: 164, height: 25)),
        ])
        #expect(TurnstileWidget.phase(in: roots([parked]), viewport: screen) == .absent)
    }

    /// The web view measured on Swyftx RN iPhone. The green check was a 30pt circle centred at (47.8, 415.5).
    private func iosWebView() -> UINode {
        let shell = UIFrame(x: 16, y: 375, width: 370, height: 80)
        return node(role: .scrollView, frame: shell, children: [
            node(role: .group, frame: shell),
            node(role: .slider, label: "Vertical scroll bar, 2 pages", value: "0%", frame: UIFrame(x: 353, y: 375, width: 30, height: 80)),
        ])
    }

    @Test("an iOS web view is not in the tree, and the tap is the green check")
    func iosWebViewAimsAtTheGreenCheck() {
        let shell = iosWebView()
        let page = node(role: .scrollView, frame: UIFrame(x: 0, y: 0, width: 402, height: 722), children: [
            node(role: .slider, label: "Vertical scroll bar, 1 page", frame: UIFrame(x: 369, y: 62, width: 30, height: 660)),
        ])
        #expect(TurnstileWidget.phase(in: roots([page, shell]), viewport: screen) == .absent)

        let shells = TurnstileWidget.iosShells(in: roots([page, shell]), viewport: screen)
        #expect(shells.count == 1)
        let frame = shells[0]
        let point = TurnstileWidget.aim(TurnstileWidget.iosTarget(frame))
        #expect(abs(point.x - 48) < 0.01)
        #expect(abs(point.y - 415) < 0.01)

        let probes = TurnstileWidget.probePoints(in: frame)
        #expect(abs(probes.status.x - 96) < 0.01)
        #expect(abs(probes.logo.x - 332) < 0.01)

        let wide = TurnstileWidget.aim(TurnstileWidget.iosTarget(frame), offset: UIPoint(x: 100, y: -100), maxJitter: 8)
        #expect(wide.x > 33 && wide.x < 63)
        #expect(wide.y > 400 && wide.y < 430)
    }

    @Test("an iOS point read uses the value, and Success is not tapped")
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
        guard case .ready(let target) = TurnstileWidget.phase(shell: shell, status: .prompt, logo: .logo) else {
            Issue.record("a prompt should be ready to tap")
            return
        }
        #expect(abs(TurnstileWidget.aim(target).x - 48) < 0.01)
        #expect(TurnstileWidget.phase(shell: shell, status: .unrelated, logo: .unrelated) == .absent)
        let parked = node(role: .scrollView, frame: UIFrame(x: 16, y: 2000, width: 370, height: 80), children: [
            node(role: .slider, label: "Vertical scroll bar, 2 pages", frame: UIFrame(x: 353, y: 2000, width: 30, height: 80)),
        ])
        #expect(TurnstileWidget.iosShells(in: roots([parked]), viewport: screen).isEmpty)
    }

    @Test("the report names a tap and an already-passed widget")
    func report() {
        let tapped = TurnstileReport(outcome: .tapped, point: UIPoint(x: 44.57, y: 401.52))
        #expect(tapped.textLine() == "✓ Turnstile passed after a tap at (44.57, 401.52)")
        #expect(tapped.jsonLine().contains("\"outcome\":\"tapped\""))
        #expect(tapped.jsonLine().contains("\"x\":44.57"))

        let passed = TurnstileReport(outcome: .alreadyPassed)
        #expect(passed.textLine() == "✓ Turnstile already passed")
        #expect(passed.jsonLine().contains("\"point\":null"))
    }

    @Test("jitter outside 0 to 8 and an empty --id are usage errors")
    func rejectsBadOptions() throws {
        #expect(parseMessage(["--jitter", "9"]).contains("--jitter must be from 0 to 8"))
        #expect(parseMessage(["--timeout", "61"]).contains("--timeout must be from 1 to 60"))
        #expect(parseMessage(["--timeout", "0"]).contains("--timeout must be from 1 to 60"))
        #expect(parseMessage(["--id", " "]).contains("--id must not be empty"))
        #expect(try Turnstile.parse(["--device", "emulator-5558", "--seed", "1"]).seed == 1)
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
        let checkbox = TurnstileStatus(phase: .ready(TurnstileTarget(frame: frame, logoOnRight: true)), source: .tree)
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

    @Test("--status refuses the tap options", arguments: ["--jitter", "--seed", "--timeout"])
    func statusRefusesTapOptions(option: String) {
        let error = #expect(throws: (any Error).self) { try Turnstile.parse(["--status", option, "2", "--device", "emulator-5554"]) }
        #expect(error.map { Turnstile.exitCode(for: $0).rawValue } == 64)
        #expect(error.map { Turnstile.message(for: $0).contains("does not take \(option)") } == true)
    }

    @Test("a visual challenge fails with turnstile_challenge, exit 1, and sends nothing")
    @MainActor
    func challengeReason() async throws {
        let grid = node(role: .group, id: "cf-chl-widget-grid", frame: UIFrame(x: 24, y: 300, width: 365, height: 280), children: [
            node(role: .text, label: "Select all squares with a bus", frame: UIFrame(x: 24, y: 300, width: 365, height: 40)),
        ])
        let backend = FakeDeviceBackend(trees: [UITree(platform: .android, device: "emulator-5554", roots: roots([grid]))])
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))
        let error = await #expect(throws: CLIError.self) {
            try await Turnstile.parse(["--device", "emulator-5554"]).perform(on: route, logger: OffsiderLogger())
        }
        #expect(error?.reason == .turnstileChallenge)
        #expect(FailureReason.turnstileChallenge.exitCode == .failure)
        #expect(backend.session.calls.isEmpty)
    }
}
