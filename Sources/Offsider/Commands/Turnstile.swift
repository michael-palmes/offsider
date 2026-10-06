import ArgumentParser
import Foundation
import OffsiderCore

struct Turnstile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "turnstile",
        abstract: "Tap the checkbox square of a Cloudflare Turnstile widget and wait until it passes",
        discussion: """
        The checkbox's accessibility frame includes the words beside the square, so tap on that label \
        lands on the words. This command taps the square, a few points off its centre, and waits until \
        the widget reads Success.

        It finds a cf-chl-widget container, or a checkbox labelled Verify you are human. On iOS the web \
        view leaves that checkbox out of the tree: the command reads a point in the short web view and, \
        when the widget has not already passed, taps the square where the green check sits. --id limits \
        the search to one element, such as the app's wrapper around the widget. A visual challenge fails, \
        because a checkbox tap cannot complete an image grid. Exits 0 when the widget passes, 5 when the \
        checkbox is still there at --timeout, and 2 when no widget is on screen.

        This does not bypass Turnstile. It only taps the checkbox. The widget passes only when Cloudflare \
        accepts the device. The command never mints or submits a token, and a checkbox that stays put, or \
        a visual challenge, means this device was not accepted.

        --status reads the widget once and taps nothing: checkbox, verifying, passed, challenge or absent, \
        always exit 0 (6 when several checkboxes are on screen).
        """
    )

    @Option(name: .customLong("id"), help: "Only look inside the element with this id, such as the app's wrapper around the widget.")
    var elementID: String?

    @Flag(name: .customLong("status"), help: "Read the widget's state once and tap nothing: checkbox, verifying, passed, challenge or absent.")
    var status = false

    @Option(name: .customLong("timeout"), help: ArgumentHelp("Give up after this many seconds, from 1 to 60, and exit 5 (default 15). Covers finding the checkbox and waiting for it to pass.", valueName: "seconds"))
    var timeoutOption: Double?

    @Option(name: .customLong("poll-interval"), help: ArgumentHelp("Seconds between reads, from 0.05 to 5.", valueName: "seconds"))
    var pollInterval: Double = 0.25

    @Option(name: .customLong("jitter"), help: ArgumentHelp("How far the tap may sit from the square's centre, in points (dp on Android), from 0 to 8 (default 3). Kept inside the square.", valueName: "points"))
    var jitterOption: Double?

    @Option(help: ArgumentHelp("Repeat the same offset. Omit it for a different point each run.", valueName: "n"))
    var seed: Int?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let defaultTimeout: Double = 15

    var timeout: Double { timeoutOption ?? Self.defaultTimeout }
    var jitter: Double { jitterOption ?? TurnstileWidget.defaultJitter }

    func validate() throws {
        if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--id must not be empty.")
        }
        if status {
            for (name, isSet) in [("--jitter", jitterOption != nil), ("--seed", seed != nil), ("--timeout", timeoutOption != nil)] where isSet {
                throw ValidationError("--status reads the widget without a tap, so it does not take \(name).")
            }
        }
        guard timeout.isFinite, (1...60).contains(timeout) else {
            throw ValidationError("--timeout must be from 1 to 60 seconds; got \(timeout).")
        }
        guard pollInterval.isFinite, (0.05...5).contains(pollInterval) else {
            throw ValidationError("--poll-interval must be from 0.05 to 5 seconds; got \(pollInterval).")
        }
        guard jitter.isFinite, (0...TurnstileWidget.maximumJitter).contains(jitter) else {
            throw ValidationError("--jitter must be from 0 to \(Int(TurnstileWidget.maximumJitter)) points; got \(jitter).")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        if status {
            // An Android tree read locks the device, as `wait` does; iOS reads never lock.
            let locking = DeviceIDClassifier.classify(deviceOption.id).platform == .android
            let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: locking)
            let report = try await watchdog.guarding(setupThen: 0, device: deviceOption.id) { ready in
                try await readStatus(on: route, onPrepared: ready)
            }
            if json {
                print(report.jsonLine())
                print(report.textLine(), to: &standardError)
            } else {
                print(report.textLine())
            }
            return
        }
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog)
        let report = try await watchdog.guarding(setupThen: timeout, device: deviceOption.id) { ready in
            try await perform(on: route, logger: logger, onPrepared: ready)
        }
        if json {
            print(report.jsonLine())
            print(report.textLine(), to: &standardError)
        } else {
            print(report.textLine())
        }
    }

    /// One read, no input: the tree first, then on iOS points in the web view.
    @MainActor
    func readStatus(on route: DeviceRouter.Route, onPrepared: @Sendable () -> Void = {}) async throws -> TurnstileStatus {
        try await route.backend.prepare()
        onPrepared()
        let tree = try await route.backend.accessibilityTree(for: route.device)
        var phase = TurnstileWidget.phase(in: tree.roots, viewport: tree.viewport, scopeID: elementID)
        var source = TurnstileStatus.Source.tree
        if phase == .absent || phase == .checking {
            let shell = await shellPhase(in: tree, on: route)
            if shell != .absent {
                phase = shell
                source = .webViewPoints
            }
        }
        guard let status = TurnstileStatus(phase: phase, source: source) else {
            throw Self.ambiguous(phase, device: route.device)
        }
        return status
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

    /// Finds the widget, taps the square once, and waits for Success.
    @MainActor
    func perform(
        on route: DeviceRouter.Route,
        logger: OffsiderLogger,
        onPrepared: @Sendable () -> Void = {}
    ) async throws -> TurnstileReport {
        try await route.backend.prepare()
        onPrepared()
        let deadline = Date().addingTimeInterval(timeout)
        var tapped: UIPoint?
        var sawWidget = false
        var last = TurnstilePhase.absent
        var generator = makeGenerator()

        while true {
            var justTapped = false
            let tree = try await route.backend.accessibilityTree(for: route.device)
            var phase = TurnstileWidget.phase(in: tree.roots, viewport: tree.viewport, scopeID: elementID)
            if phase == .absent || phase == .checking {
                let shell = await shellPhase(in: tree, on: route)
                if shell != .absent { phase = shell }
            }
            last = phase
            switch phase {
            case .passed:
                return TurnstileReport(outcome: tapped == nil ? .alreadyPassed : .tapped, point: tapped)
            case .ready(let target):
                sawWidget = true
                if tapped == nil {
                    let point = TurnstileWidget.aim(target, offset: Self.offset(maxJitter: jitter, generator: &generator), maxJitter: jitter)
                    let physical = try await route.backend.deviceCoordinates(for: [(x: point.x, y: point.y)], tree: tree, on: route.device)[0]
                    logger.info().log("Tapping Turnstile at (\(point.x), \(point.y))")
                    try await route.backend.performTracked(.tapAt(x: physical.x, y: physical.y), on: route.device)
                    tapped = point
                    justTapped = true
                }
            case .visualChallenge:
                throw CLIError(
                    errorDescription: "The Turnstile widget is showing a visual challenge. A tap on the checkbox cannot complete it.",
                    reason: .turnstileChallenge,
                    hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
                )
            case .ambiguous:
                throw Self.ambiguous(phase, device: route.device)
            case .checking:
                sawWidget = true
            case .absent:
                break
            }

            // A tap always gets one more read, even at the deadline.
            guard Date() < deadline || justTapped else { break }
            try await Task.sleep(for: .seconds(pollInterval))
        }

        if let tapped {
            let place = "at (\(Self.format(tapped.x)), \(Self.format(tapped.y)))"
            let detail: String
            if case .ready = last {
                detail = "The Turnstile checkbox is still on screen \(Self.seconds(timeout)) after the tap \(place)."
            } else if case .absent = last {
                detail = "The Turnstile widget left the screen after the tap \(place) before it passed."
            } else {
                detail = "The Turnstile widget was still checking \(Self.seconds(timeout)) after the tap \(place)."
            }
            throw CLIError(
                errorDescription: detail,
                reason: .conditionNotMet,
                hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
            )
        }
        if sawWidget {
            throw CLIError(
                errorDescription: "The Turnstile widget was still checking after \(Self.seconds(timeout)), and it showed no checkbox.",
                reason: .conditionNotMet,
                hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
            )
        }
        throw CLIError(
            errorDescription: "No Cloudflare Turnstile widget is on screen.",
            reason: .selectorNotFound,
            hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
        )
    }

    /// iOS keeps the checkbox out of the tree, so an app wrapper reads as checking. A point in the web view tells Success from a checkbox.
    private func shellPhase(in tree: UITree, on route: DeviceRouter.Route) async -> TurnstilePhase {
        let shells = TurnstileWidget.iosShells(in: tree.roots, viewport: tree.viewport, scopeID: elementID)
        var samples: [(frame: UIFrame, status: TurnstileReading, logo: TurnstileReading)] = []
        for shell in shells {
            let points = TurnstileWidget.probePoints(in: shell)
            let status = await reading(at: points.status, on: route)
            let logo = await reading(at: points.logo, on: route)
            samples.append((frame: shell, status: status, logo: logo))
        }
        return TurnstileWidget.phase(of: samples)
    }

    private func reading(at point: UIPoint, on route: DeviceRouter.Route) async -> TurnstileReading {
        do {
            let tree = try await route.backend.accessibilityTree(for: route.device, point: point)
            return TurnstileWidget.reading(in: tree.roots)
        } catch {
            return .unrelated
        }
    }

    private func makeGenerator() -> SeededRandom {
        if let seed { return SeededRandom(seed: seed) }
        var system = SystemRandomNumberGenerator()
        return SeededRandom(seed: Int(truncatingIfNeeded: system.next()))
    }

    private static func offset(maxJitter: Double, generator: inout SeededRandom) -> UIPoint {
        guard maxJitter > 0 else { return UIPoint(x: 0, y: 0) }
        return UIPoint(
            x: Double.random(in: -maxJitter...maxJitter, using: &generator),
            y: Double.random(in: -maxJitter...maxJitter, using: &generator)
        )
    }

    private static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
    }

    private static func seconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
        return "\(text) s"
    }
}

/// A fixed sequence, so `--seed` repeats the same tap.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        let value = UInt64(bitPattern: Int64(seed))
        state = value == 0 ? 0x9E37_79B9_7F4A_7C15 : value
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
