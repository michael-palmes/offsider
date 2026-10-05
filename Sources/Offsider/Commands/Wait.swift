import ArgumentParser
import Foundation
import OffsiderCore

extension SettleSource: ExpressibleByArgument {}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait until an element is on screen or gone, the screen settles, a region changes or stays still, or a fixed time passes",
        discussion: """
        Choose one condition: a selector (--id, --label or --value, with --gone to wait for it to leave), --settled, \
        --region with --changed or --stable, or --seconds. Selectors count only on-screen matches unless --allow-offscreen. \
        --region watches pixels in points as describe-ui prints them, for content the accessibility tree cannot see such as charts \
        or web views. Exits 0 when the condition is met and 5 when --timeout passes first; --settled exits 1 when the \
        accessibility tree was never readable, where --settle-by screen still works.
        """
    )

    @OptionGroup
    var selector: ElementSelectorOptions

    @Flag(name: .customLong("gone"), help: "Wait until no matching element is on screen.")
    var gone = false

    @Flag(name: .customLong("settled"), help: "Wait until nothing has changed for --quiet-ms.")
    var settled = false

    @Option(name: .customLong("settle-by"), help: "What --settled watches (default tree).")
    var settleBy: SettleSource?

    @Option(help: ArgumentHelp("Watch this rectangle's pixels, in points as describe-ui prints them. Needs --changed or --stable.", valueName: "x,y,w,h"))
    var region: String?

    @Flag(name: .customLong("changed"), help: "With --region, wait until the region differs from its first capture by more than --threshold.")
    var changed = false

    @Flag(name: .customLong("stable"), help: "With --region, wait until the region has not changed for --quiet-ms.")
    var stable = false

    @Option(name: .customLong("quiet-ms"), help: ArgumentHelp("How long nothing may change for --settled or --region --stable, from 100 to 10000 ms (default 500).", valueName: "ms"))
    var quietMs: Int?

    @Option(help: ArgumentHelp("With --region, the fraction of tiles that may change and still count as unchanged (0 to 1, default 0).", valueName: "0-1"))
    var threshold: Double?

    @Option(help: ArgumentHelp("Wait this long, from 0 to 300 seconds, then exit 0. Ignores --timeout.", valueName: "seconds"))
    var seconds: Double?

    @Option(help: ArgumentHelp("Give up after this many seconds, from 0 to 300, and exit 5.", valueName: "seconds"))
    var timeout: Double = 10

    @Option(name: .customLong("poll-interval"), help: ArgumentHelp("Seconds between reads, from 0.05 to 5.", valueName: "seconds"))
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    static let defaultQuietMs = 500

    func validate() throws {
        if (changed || stable) && region == nil {
            throw ValidationError("--changed and --stable need --region.")
        }
        let families = [selector.query != nil, settled, region != nil, seconds != nil].filter { $0 }.count
        if families == 0 {
            throw ValidationError("Choose one of a selector (--id, --label or --value), --settled, --region or --seconds.")
        }
        if families > 1 {
            throw ValidationError("Choose only one of a selector, --settled, --region or --seconds.")
        }
        if gone && selector.query == nil {
            throw ValidationError("--gone needs --id, --label or --value.")
        }
        if settleBy != nil && !settled {
            throw ValidationError("--settle-by applies to --settled only.")
        }
        if let region {
            do {
                _ = try PointRegion.parse(region)
            } catch let error as ScreenRegionError {
                throw ValidationError(error.message)
            }
            if changed == stable {
                throw ValidationError(changed ? "Use only one of --changed or --stable." : "--region needs --changed or --stable.")
            }
        }
        if let threshold {
            guard region != nil else { throw ValidationError("--threshold applies to --region only.") }
            guard (0...1).contains(threshold) else { throw ValidationError("--threshold must be from 0 to 1; got \(threshold).") }
        }
        if let quietMs {
            guard settled || stable else { throw ValidationError("--quiet-ms applies to --settled and --region --stable only.") }
            guard (100...10_000).contains(quietMs) else { throw ValidationError("--quiet-ms must be from 100 to 10000; got \(quietMs).") }
        }
        if let seconds, !(0...300).contains(seconds) {
            throw ValidationError("--seconds must be from 0 to 300; got \(seconds).")
        }
        guard (0...300).contains(timeout) else {
            throw ValidationError("--timeout must be from 0 to 300 seconds; got \(timeout).")
        }
        guard (0.05...5).contains(pollInterval) else {
            throw ValidationError("--poll-interval must be from 0.05 to 5 seconds; got \(pollInterval).")
        }
        if (settled || stable) && quiet > timeout {
            throw ValidationError("--quiet-ms is longer than --timeout, so the wait could never succeed. Raise --timeout or lower --quiet-ms.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        // An Android tree read locks the device, so the claim (and any --wait-lock) comes before the watchdog's bound.
        let locking = readsTree && DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: locking)
        let outcome = try await watchdog.guarding(setupThen: watchdogBound, device: deviceOption.id) { ready in
            try await evaluate(on: route, logger: logger, onPrepared: ready)
        }
        try Self.report(outcome, success: successLine(outcome), failure: failureLine(outcome), json: json)
    }

    var readsTree: Bool {
        selector.query != nil || (settled && (settleBy ?? .tree) == .tree)
    }

    /// The longest this wait may legitimately take before the watchdog's grace.
    var watchdogBound: TimeInterval { seconds ?? timeout }

    /// Waits on `route` without printing; a batch step or a test reports the outcome itself. `tree` replaces the device's tree reads.
    @MainActor
    func evaluate(
        on route: DeviceRouter.Route,
        logger: OffsiderLogger,
        tree: TreeSource? = nil,
        clock: PollClock = .live,
        onPrepared: @Sendable () -> Void = {}
    ) async throws -> WaitOutcome {
        appOption.apply(to: route)
        try await route.backend.prepare()
        onPrepared()
        let sources = try await liveSources(on: route, tree: tree, clock: clock)
        logger.info().log("Waiting for \(target)")
        return try await WaitLoop.run(condition, timeout: timeout, interval: pollInterval, sources: sources)
    }

    var condition: WaitCondition {
        if let query = selector.query {
            return .element(probe: selector.probe(for: query), gone: gone)
        }
        if settled {
            return .settled(by: settleBy ?? .tree, quiet: quiet)
        }
        if region != nil {
            return .region(mode: stable ? .stable : .changed, quiet: quiet, threshold: threshold ?? 0)
        }
        return .duration(seconds ?? 0)
    }

    /// `✓ --id 'save' is on screen after 1.2 s`, `✓ Screen settled after 0.9 s` or `✓ Waited 2 s`.
    func successLine(_ outcome: WaitOutcome) -> String {
        let after = "after \(WaitLoop.seconds(outcome.elapsed))"
        if let query = selector.query {
            return "✓ \(query.selectorDescription) is \(gone ? "gone" : selector.presentState) \(after)"
        }
        if settled { return "✓ Screen settled \(after)" }
        if region != nil { return stable ? "✓ Region stable \(after)" : "✓ Region changed \(after)" }
        return "✓ Waited \(WaitLoop.seconds(outcome.elapsed))"
    }

    /// `✗ Timed out after 10 s waiting for --id 'save' (last: off screen at (20, 10700) 350x44).`
    func failureLine(_ outcome: WaitOutcome) -> String {
        "✗ Timed out after \(WaitLoop.seconds(timeout)) waiting for \(target) (last: \(outcome.reason))."
    }

    private var target: String {
        if let query = selector.query {
            if gone { return "\(query.selectorDescription) to be gone" }
            return selector.hasValue.map { "\(query.selectorDescription) with value '\($0)'" } ?? query.selectorDescription
        }
        if settled { return "the screen to settle" }
        if region != nil { return stable ? "the region to stay still" : "the region to change" }
        return WaitLoop.seconds(seconds ?? 0)
    }

    private var quiet: TimeInterval {
        Double(quietMs ?? Self.defaultQuietMs) / 1000
    }

    typealias TreeSource = @MainActor () async throws -> UITree

    @MainActor
    private func liveSources(on route: DeviceRouter.Route, tree: TreeSource?, clock: PollClock) async throws -> WaitSources {
        let backend = route.backend
        let device = route.device
        if let region {
            let request = ScreenshotRequest(region: try PointRegion.parse(region))
            return Self.sources(on: route, tree: tree, clock: clock) {
                let capture = try await ScreenCapture.capture(backend, device: device)
                return try Self.fingerprint(try ScreenCapture.render(capture, request: request))
            }
        }
        guard settled, settleBy ?? .tree != .tree else {
            return Self.sources(on: route, tree: tree, clock: clock)
        }
        let bands = await backend.volatileScreenBands(for: device)
        return Self.sources(on: route, tree: tree, clock: clock) {
            let capture = try await ScreenCapture.capture(backend, device: device)
            let rendered = try ScreenCapture.render(capture, request: ScreenshotRequest())
            let exclusion = ScreenCapture.bandPixels(rendered, capture: capture, bands: bands)
            return try Self.fingerprint(rendered, excludingTop: exclusion.top, bottom: exclusion.bottom)
        }
    }

    /// The device's tree (or `tree`) on real time unless `clock` says otherwise; `fingerprint` defaults to a failure for conditions that never read the screen.
    @MainActor
    static func sources(
        on route: DeviceRouter.Route,
        tree: TreeSource? = nil,
        clock: PollClock = .live,
        fingerprint: @escaping @MainActor () async throws -> ImageFingerprint = { throw CLIError(errorDescription: "This condition does not read the screen.", reason: .internalError) }
    ) -> WaitSources {
        WaitSources(
            tree: tree ?? { try await route.backend.accessibilityTree(for: route.device) },
            fingerprint: fingerprint,
            sleep: clock.sleep,
            now: clock.now
        )
    }

    private static func fingerprint(_ rendered: RenderedScreenshot, excludingTop top: Int = 0, bottom: Int = 0) throws -> ImageFingerprint {
        guard let fingerprint = ImageFingerprint(image: rendered.image, excludingTopPixels: top, excludingBottomPixels: bottom) else {
            throw ImageFailure(detail: "could not read the screenshot's pixels")
        }
        return fingerprint
    }

    /// Prints the outcome (the JSON report on stdout with `json`, human text on stderr) and exits 5 when it was not met.
    static func report(_ outcome: WaitOutcome, success: String, failure: String, json: Bool) throws {
        let line = outcome.met ? success : failure
        if json {
            print(WaitReport(outcome).jsonLine())
            print(line, to: &standardError)
        } else if outcome.met {
            print(line)
        } else {
            print(line, to: &standardError)
        }
        if !outcome.met {
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
    }
}
