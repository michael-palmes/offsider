import ArgumentParser
import Foundation
import OffsiderCore

struct Turnstile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "turnstile",
        abstract: "Read the state of a Cloudflare Turnstile widget. It never taps the widget.",
        discussion: """
        Prints one state: checkbox, verifying, passed, challenge, absent or unknown, and exits 0 (6 when several \
        checkboxes are on screen). It finds a cf-chl-widget container, or a checkbox labelled Verify you are \
        human. On iOS the web view leaves the checkbox out of the tree, so the command reads points in the \
        short web view. --id limits the search to one element, such as the app's wrapper around the widget. \
        unknown means an element named for Turnstile is on screen with no widget in it: the widget failed to \
        run, or runs invisibly.

        Offsider never ticks Turnstile. A checkbox or a challenge is for a person: ask them, and --wait carries \
        on the moment it passes, so nobody has to reply. It only reads, and exits 5 if the time runs out first. \
        On a phone, another app in front or the lock screen counts as not yet done, and nothing is read from it; \
        if it is still there when the time runs out, that failure is the answer.
        """
    )

    /// How long the wait a refusal suggests runs: long enough for someone busy in another session.
    static let suggestedWait = 600
    private static let waitInterval: Duration = .seconds(1)

    @Option(name: .customLong("id"), help: "Only look inside the element with this id, such as the app's wrapper around the widget.")
    var elementID: String?

    @Option(name: .customLong("wait"), help: ArgumentHelp("Keep reading for up to this many seconds, from 0 to \(Wait.maximumSeconds), until the widget passes or leaves the screen. It still never taps; exit 5 if the time runs out.", valueName: "seconds"))
    var waitSeconds: TimeInterval?

    /// Kept for one release so scripts that pass it still run; the command always only reads.
    @Flag(name: .customLong("status"), help: .hidden)
    var status = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    func validate() throws {
        if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--id must not be empty.")
        }
        if let waitSeconds, !(0...Double(Wait.maximumSeconds)).contains(waitSeconds) {
            throw ValidationError("--wait must be from 0 to \(Wait.maximumSeconds) seconds; got \(waitSeconds).")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        // An Android tree read locks the device, as `wait` does; iOS reads never lock.
        let locking = DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: locking)
        await appOption.apply(to: route)
        let console = Console.current
        let report = try await console.progress(waitSeconds == nil ? "Reading Turnstile" : "Waiting for Turnstile") {
            try await watchdog.guarding(setupThen: waitSeconds ?? 0, device: deviceOption.id) { ready in
                try await readStatus(on: route, onPrepared: ready)
            }
        }
        if json {
            console.data(report.jsonLine() + "\n")
            console.data(report.textLine() + "\n", to: .err)
        } else {
            console.show(InputPersonView.turnstile(report))
        }
    }

    /// One read, or with --wait reads until a person's step is over, no input: the tree first, then on iOS points in the web view.
    @MainActor
    func readStatus(on route: DeviceRouter.Route, clock: PollClock = .live, onPrepared: @Sendable () -> Void = {}) async throws -> TurnstileStatus {
        try await route.backend.prepare()
        onPrepared()
        let readOnce = {
            let tree = try await route.backend.accessibilityTree(for: route.device)
            return try await Self.status(in: tree, on: route, scopeID: elementID)
        }
        guard let waitSeconds else { return try await readOnce() }
        let device = route.device.rawValue
        let status = try await Self.waitForPerson(seconds: waitSeconds, clock: clock, onOtherApp: { Wait.noteOtherApp(limit: waitSeconds, device: device) }, read: readOnce)
        guard status.state.awaitsPerson else { return status }
        await route.noteNameForAsk()
        throw Self.stepStillOpen(status.state, seconds: waitSeconds, app: appOption.bundleID)
    }

    /// Reads until `passed`, or until a widget stays gone for two reads in a row, so a reload mid-tick does not end the wait; else the last read at the deadline.
    /// A phone's other app or sleeping screen may be the person on their way, so it holds the wait, and only stands as the answer if still there at the deadline.
    @MainActor
    static func waitForPerson(seconds: TimeInterval, clock: PollClock, onOtherApp: () -> Void = {}, read: () async throws -> TurnstileStatus) async throws -> TurnstileStatus {
        let deadline = clock.now() + seconds
        var last: TurnstileStatus?
        var gone: TurnstileStatus.State?
        var held: Error?
        var failure: Error?
        var notedOtherApp = false
        while true {
            do {
                let status = try await read()
                if status.state == .passed || (!status.state.awaitsPerson && gone == status.state) {
                    return status
                }
                last = status
                gone = status.state.awaitsPerson ? nil : status.state
                held = nil
            } catch where error.isTransientFailure {
                gone = nil
                held = nil
                failure = error
            } catch where error.isOtherAppInFront || (error as? any OffsiderFailure)?.reason == .deviceLocked {
                gone = nil
                held = error
                if error.isOtherAppInFront, seconds > 0, !notedOtherApp {
                    notedOtherApp = true
                    onOtherApp()
                }
            }
            let remaining = deadline - clock.now()
            guard remaining > 0 else { break }
            try await clock.sleep(min(waitInterval, .milliseconds(Int((remaining * 1000).rounded()))))
        }
        if let held { throw held }
        if let last { return last }
        throw failure ?? CLIError(errorDescription: "Turnstile could not be read within \(String(format: "%g", seconds)) s.", reason: .treeReadFailed)
    }

    /// The command a refusal suggests; a phone needs its app named on every command.
    static func waitCommand(app: String? = nil) -> String {
        "offsider turnstile --wait \(suggestedWait) --device <DEVICE_ID>" + (app.map { " --app \($0)" } ?? "")
    }

    /// Says what is still open, so an agent can tell the user plainly and carry on with what needs no sign-in.
    static func stepStillOpen(_ state: TurnstileStatus.State, seconds: TimeInterval, app: String?) -> CLIError {
        let after = "after \(String(format: "%g", seconds)) s"
        let what: String
        let ask: String
        switch state {
        case .challenge:
            what = "The Cloudflare Turnstile challenge is still on screen \(after), so nobody has solved it."
            ask = PersonAsk.solveTurnstile
        case .verifying:
            what = "Cloudflare Turnstile was still checking \(after)."
            ask = PersonAsk.finishTurnstile
        default:
            what = "The Cloudflare Turnstile checkbox is still on screen \(after), so nobody has ticked it."
            ask = PersonAsk.tickTurnstile
        }
        return CLIError(errorDescription: "\(what) Nothing was sent.", reason: .conditionNotMet, hint: waitCommand(app: app), ask: ask)
    }

    /// The widget's state in `tree`, reading web-view points on iOS when the tree alone says absent or checking.
    @MainActor
    static func status(in tree: UITree, on route: DeviceRouter.Route, scopeID: String?) async throws -> TurnstileStatus {
        let (phase, source) = await read(tree, on: route, scopeID: scopeID)
        guard let status = TurnstileStatus(phase: phase, source: source) else {
            throw ambiguous(phase, device: route.device)
        }
        return status
    }

    /// The widget's phase in `tree`, as `login` reads it before typing, before submit and after.
    @MainActor
    static func phase(in tree: UITree, on route: DeviceRouter.Route, scopeID: String? = nil) async -> TurnstilePhase {
        await read(tree, on: route, scopeID: scopeID).phase
    }

    @MainActor
    private static func read(_ tree: UITree, on route: DeviceRouter.Route, scopeID: String?) async -> (phase: TurnstilePhase, source: TurnstileStatus.Source) {
        let phase = TurnstileWidget.phase(in: tree.roots, viewport: tree.viewport, scopeID: scopeID)
        if phase == .absent || phase == .checking || phase == .noWidget {
            let shell = await shellPhase(in: tree, on: route, scopeID: scopeID)
            if shell != .absent { return (shell, .webViewPoints) }
        }
        return (phase, .tree)
    }

    private static func ambiguous(_ phase: TurnstilePhase, device: DeviceID) -> CLIError {
        let count: Int
        if case .ambiguous(let found) = phase { count = found } else { count = 2 }
        return CLIError(
            errorDescription: "\(count) Turnstile checkboxes are on screen. Pass --id to choose the wrapper that holds the one you want.",
            reason: .selectorAmbiguous,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }

    /// iOS keeps the checkbox out of the tree, so an app wrapper reads as checking. A point in the web view tells Success from a checkbox.
    @MainActor
    private static func shellPhase(in tree: UITree, on route: DeviceRouter.Route, scopeID: String?) async -> TurnstilePhase {
        let shells = TurnstileWidget.iosShells(in: tree.roots, viewport: tree.viewport, scopeID: scopeID)
        var samples: [(frame: UIFrame, status: TurnstileReading, logo: TurnstileReading)] = []
        for shell in shells {
            let points = TurnstileWidget.probePoints(in: shell)
            let status = await reading(at: points.status, on: route)
            let logo = await reading(at: points.logo, on: route)
            samples.append((frame: shell, status: status, logo: logo))
        }
        return TurnstileWidget.phase(of: samples)
    }

    @MainActor
    private static func reading(at point: UIPoint, on route: DeviceRouter.Route) async -> TurnstileReading {
        do {
            let tree = try await route.backend.accessibilityTree(for: route.device, point: point)
            return TurnstileWidget.reading(in: tree.roots)
        } catch {
            return .unrelated
        }
    }
}
