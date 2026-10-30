import ArgumentParser
import Foundation
import OffsiderCore

extension SettleSource: ExpressibleByArgument {}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait until an element is on screen or gone, the screen settles, a region changes or stays still, or a fixed time passes",
        discussion: """
        Choose one condition: a selector (--id, --label, --label-contains or --value, with --gone to wait for it to leave), --settled, \
        --region with --changed or --stable, or --seconds, which needs no device. Selectors count only on-screen matches unless \
        --allow-offscreen. --region watches pixels in points as describe-ui prints them, for content the accessibility tree cannot \
        see such as charts or web views. Within 2 s of an input, --settled also waits for that input's effect to show (a read that \
        differs from the screen before it, else 2 s after it, or 1 s when no read from before it was kept), so a delayed push is not \
        missed; an input checked with --verify needs no such wait. After an input that changed the tree on Android, it also waits up \
        to 2 s for the pixels to hold still, so the next capture shows the new screen; --settle-by tree skips that. Exits 0 when the \
        condition is met and 5 when --timeout passes first, naming the nearest element when a selector found nothing, or the flag \
        that leaves out what kept moving for --settled; --settled exits 1 when the accessibility tree was never readable, where \
        --settle-by screen still works. A selector exits 1 (logbox_inspector_open) once React Native's LogBox inspector has hidden \
        the app on Android for 1.5 s, since nothing in the app can match until it closes. On a phone, another app in front counts \
        as not yet met and nothing is read from it; if it is still in front at --timeout, the wait exits 1 (app_not_allowed).
        """
    )

    @OptionGroup
    var selector: ElementSelectorOptions

    @Flag(name: .customLong("gone"), help: "Wait until no matching element is on screen.")
    var gone = false

    @Flag(name: .customLong("any"), help: "With two or more selectors (--id, --label, --label-contains, --value, each repeatable), wait until the first of them is on screen. With one, a plain wait for it.")
    var any = false

    /// `--any` over two or more selectors; with one it is a plain wait, so a list built at run time can hold a single label.
    var waitsForAny: Bool { any && selector.queries.count > 1 }

    @Flag(name: .customLong("settled"), help: "Wait until nothing has changed for --quiet-ms.")
    var settled = false

    @Option(name: .customLong("settle-by"), help: "What --settled watches (default tree).")
    var settleBy: SettleSource?

    @Flag(name: .customLong("ignore-values"), help: "With --settled, label and value changes do not count, so a ticking price or clock cannot keep the screen unsettled; moves and elements added or removed still do.")
    var ignoreValues = false

    @Option(name: .customLong("ignore-id"), parsing: .upToNextOption, help: ArgumentHelp("With --settled, this element and everything under it do not count, so a live chart or carousel cannot keep the screen unsettled. Repeatable.", valueName: "id"))
    var ignoreIDs: [String] = []

    @Option(name: .customLong("ignore-region"), parsing: .upToNextOption, help: ArgumentHelp("With --settled, this rectangle's pixels and the elements at least half inside it and no bigger than it, with everything under them, do not count; points as describe-ui prints them. Repeatable.", valueName: "x,y,w,h"))
    var ignoreRegions: [String] = []

    @Option(name: .customLong("stable-for"), help: ArgumentHelp("With a selector, how long the element must stay on screen (or, with --gone, stay gone) before the wait is met, from 0 to 60000 ms. Default 500 for --gone when --timeout is at least 0.5 s, else 0.", valueName: "ms"))
    var stableForMs: Int?

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

    @Option(help: ArgumentHelp("Wait this long, from 0 to \(Wait.maximumSeconds) seconds, then exit 0. Ignores --timeout.", valueName: "seconds"))
    var seconds: Double?

    @Option(help: ArgumentHelp("Give up after this many seconds, from 0 to \(Wait.maximumSeconds), and exit 5.", valueName: "seconds"))
    var timeout: Double = 10

    @Option(name: .customLong("poll-interval"), help: ArgumentHelp("Seconds between reads, from 0.05 to 5.", valueName: "seconds"))
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: OptionalDeviceLockOption

    @OptionGroup
    var appOption: AppOption

    static let defaultQuietMs = 500
    static let maximumSeconds = 900
    /// How long after the tree last changed the pixels still hold up a wait that follows an input on Android.
    static let drawHold: TimeInterval = 2

    func validate() throws {
        if waitsForAny {
            if gone { throw ValidationError("--any waits for the first selector on screen; it does not take --gone.") }
            if selector.hasValue != nil { throw ValidationError("--any does not take --has-value; use --value as one of the selectors.") }
            if selector.requiredEnabled != nil { throw ValidationError("--any does not take --enabled or --disabled.") }
        } else if selector.mixesLabelSelectors {
            throw ValidationError(SelectorQuery.oneLabelRule)
        } else if selector.queries.count > 1, !selector.isConjunction {
            throw ValidationError("Use only one of --id, --label, --label-contains or --value, narrow one --id with a --label, --label-contains or --value, or pass --any to wait for the first of several.")
        }
        if (changed || stable) && region == nil {
            throw ValidationError("--changed and --stable need --region.")
        }
        let families = [selector.query != nil, settled, region != nil, seconds != nil].filter { $0 }.count
        if families == 0 {
            throw ValidationError("Choose one of a selector (--id, --label, --label-contains or --value), --settled, --region or --seconds.")
        }
        if families > 1 {
            throw ValidationError("Choose only one of a selector, --settled, --region or --seconds.")
        }
        if gone && selector.query == nil {
            throw ValidationError("--gone needs --id, --label, --label-contains or --value.")
        }
        if gone && selector.requiredEnabled != nil {
            throw ValidationError("--gone does not take --enabled or --disabled.")
        }
        if let stableForMs {
            if settled || stable {
                throw ValidationError("--stable-for applies to selector waits; for --settled and --region --stable use --quiet-ms.")
            }
            guard selector.query != nil else {
                throw ValidationError("--stable-for needs --id, --label, --label-contains or --value.")
            }
            guard (0...60_000).contains(stableForMs) else {
                throw ValidationError("--stable-for must be from 0 to 60000 ms; got \(stableForMs).")
            }
            if Double(stableForMs) / 1000 > timeout {
                throw ValidationError("--stable-for is longer than --timeout, so the wait could never succeed. Raise --timeout or lower --stable-for.")
            }
        }
        if settleBy != nil && !settled {
            throw ValidationError("--settle-by applies to --settled only.")
        }
        if !ignoreIDs.isEmpty {
            guard settled else { throw ValidationError("--ignore-id applies to --settled only.") }
            if settleBy == .screen {
                throw ValidationError("--ignore-id reads the accessibility tree, which --settle-by screen does not; use --ignore-region, or --settle-by tree or both.")
            }
        }
        if !ignoreRegions.isEmpty {
            guard settled else { throw ValidationError("--ignore-region applies to --settled only.") }
            do {
                _ = try leaveOut()
            } catch let error as ScreenRegionError {
                throw ValidationError(error.message)
            }
        }
        if ignoreValues {
            guard settled else { throw ValidationError("--ignore-values applies to --settled only.") }
            if settleBy == .screen {
                throw ValidationError("--ignore-values reads the accessibility tree, which --settle-by screen does not; use --settle-by tree or both.")
            }
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
        let cap = Double(Self.maximumSeconds)
        if let seconds, !(0...cap).contains(seconds) {
            throw ValidationError("--seconds must be from 0 to \(Self.maximumSeconds) seconds; got \(seconds).")
        }
        guard (0...cap).contains(timeout) else {
            throw ValidationError("--timeout must be from 0 to \(Self.maximumSeconds) seconds; got \(timeout).")
        }
        guard (0.05...5).contains(pollInterval) else {
            throw ValidationError("--poll-interval must be from 0.05 to 5 seconds; got \(pollInterval).")
        }
        if (settled || stable) && quiet > timeout {
            throw ValidationError("--quiet-ms is longer than --timeout, so the wait could never succeed. Raise --timeout or lower --quiet-ms.")
        }
        // A fixed pause reads nothing, so it is the one wait that needs no device.
        if seconds == nil { try deviceOption.validateDevice() }
    }

    /// `--ignore-id` and `--ignore-region` as the loop takes them.
    func leaveOut() throws -> SettleLeaveOut {
        SettleLeaveOut(ids: Set(ignoreIDs), regions: try ignoreRegions.map { try PointRegion.parse($0, option: "--ignore-region") })
    }

    func run() async throws {
        if seconds != nil {
            let outcome = try await Console.current.progress("Waiting for \(target)") { try await pause() }
            return try Self.report(outcome, success: successLine(outcome), failure: failureLine(outcome), json: json, person: personOutcome)
        }
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        // An Android tree read locks the device, so the claim (and any --wait-lock) comes before the watchdog's bound.
        let locking = readsTree && DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: locking)
        let outcome = try await Console.current.progress("Waiting for \(target)") {
            try await watchdog.guarding(setupThen: watchdogBound, device: deviceOption.id) { ready in
                try await evaluate(on: route, logger: logger, probesOnMiss: true, notesOtherApp: true, onPrepared: ready)
            }
        }
        let mask = (try? await AmbientMasks.treeMask()) ?? .none
        try Self.report(
            outcome, success: successLine(outcome), failure: failureLine(outcome), json: json, checked: selector, mask: mask, person: personOutcome
        )
    }

    var readsTree: Bool {
        selector.query != nil || (settled && (settleBy ?? .tree) == .tree)
    }

    /// The longest this wait may legitimately take before the watchdog's grace.
    var watchdogBound: TimeInterval { seconds ?? timeout }

    /// A fixed pause: it reads nothing and touches no device, even one it names, so it cannot fail or hang.
    @MainActor
    func pause(clock: PollClock = .live) async throws -> WaitOutcome {
        let start = clock.now()
        try await clock.sleep(.milliseconds(Int(((seconds ?? 0) * 1000).rounded())))
        return WaitOutcome(met: true, elapsed: clock.now() - start, reason: "waited")
    }

    /// Waits on `route` without printing; a batch step or a test reports the outcome itself. `tree` replaces the device's tree reads; `probesOnMiss` reads the screen's centre once when a selector is not met; `notesOtherApp` tells the reader once when another app in front holds the wait up.
    @MainActor
    func evaluate(
        on route: DeviceRouter.Route,
        logger: OffsiderLogger,
        tree: TreeSource? = nil,
        clock: PollClock = .live,
        probesOnMiss: Bool = false,
        notesOtherApp: Bool = false,
        onPrepared: @Sendable () -> Void = {}
    ) async throws -> WaitOutcome {
        appOption.apply(to: route)
        try await route.backend.prepare()
        onPrepared()
        let revealed = settled ? await TreeCache.revealedSecrets(for: route.device, backend: route.backend) : nil
        let gate = settled ? await Self.settleGate(for: route, revealed: revealed) : nil
        let condition = condition(gate: gate, platform: route.device.platform)
        var sources = try await liveSources(on: route, condition: condition, tree: tree, clock: clock)
        sources.tree = selector.judging(sources.tree, queries: waitsForAny ? selector.queries : [selector.query].compactMap { $0 }, on: route)
        if let revealed {
            // As the cache stores them, so a change message never prints one and the gate compares like with like.
            let (mask, read) = (TreeValueMask(revealed: revealed), sources.tree)
            sources.tree = { try await read().redacted(mask, scope: .cache) }
        }
        if probesOnMiss {
            sources.probe = Self.presentationProbe(on: route)
        }
        if notesOtherApp {
            let (limit, device) = (WaitLoop.seconds(timeout), route.device.rawValue)
            sources.onOtherApp = {
                Console.current.notice(.note("Another app is in front. Waiting up to \(limit) for yours", agent: "another app is in front on \(device), so nothing is read from it; waiting up to \(limit) for the app under test."))
            }
        }
        logger.info().log("Waiting for \(target)")
        return try await WaitLoop.run(condition, timeout: timeout, interval: pollInterval, sources: sources)
    }

    /// The gate for the device's last input: this process's own when it sent one (a batch step), masked here as the cache's is at exit, else the cached record's.
    @MainActor
    static func settleGate(for route: DeviceRouter.Route, revealed: RevealedSecrets? = nil) async -> SettleGate? {
        let ledger = DeviceActivityLedger.current
        let environment = TreeCacheEnvironment.current
        let now = environment.now()
        if var activity = ledger.activity(for: route.device), activity.lastInputAt != nil {
            var mask = OutputMasks.current.mask
            mask.revealed = revealed
            activity.tree = activity.tree?.redacted(mask, scope: .cache)
            let record = TreeCacheRecord.committing(activity, previous: nil, command: "wait", inputAtEnd: false, bootMarker: nil, now: now)
            return SettleGate.after(record, now: now)
        }
        return SettleGate.after(await TreeCache.load(for: route.device, backend: route.backend, environment: environment), now: now)
    }

    var condition: WaitCondition { condition(gate: nil, platform: .ios) }

    /// `platform` picks the draw hold: Android's tree can change well before its pixels, and an explicit `--settle-by` says what to watch.
    func condition(gate: SettleGate?, platform: DevicePlatform) -> WaitCondition {
        if waitsForAny {
            let queries = selector.queries
            let selectors = queries.enumerated().map { index, query in
                (selector: WaitMatch(by: String(query.kind.dropFirst(2)), text: query.rawValue, position: index + 1, of: queries.count), probe: selector.probe(for: query))
            }
            return .anyElement(selectors, stableFor: stableFor, explain: Self.explainAny(queries))
        }
        if let query = selector.query {
            return .element(probe: selector.probe(for: query), gone: gone, stableFor: stableFor, explain: SelectorQuery.explain(query))
        }
        if settled {
            let holdsDraw = gate != nil && settleBy == nil && platform == .android
            // validate() has parsed the regions.
            return .settled(
                by: settleBy ?? .tree, quiet: quiet, ignoreValues: ignoreValues, gate: gate,
                leaveOut: (try? leaveOut()) ?? .none, drawHold: holdsDraw ? Self.drawHold : nil
            )
        }
        if region != nil {
            return .region(mode: stable ? .stable : .changed, quiet: quiet, threshold: threshold ?? 0)
        }
        return .duration(seconds ?? 0)
    }

    /// `✓ --id 'save' is on screen after 1.2 s`, `✓ Screen settled after 0.9 s` or `✓ Waited 2 s`.
    func successLine(_ outcome: WaitOutcome) -> String {
        let parts = successParts(outcome)
        return "✓ " + [parts.headline, parts.after, parts.selectors.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    /// What was met, how long it took and, for `--any`, which of the selectors it was.
    private func successParts(_ outcome: WaitOutcome) -> (headline: String, after: String?, selectors: String?) {
        let after = "after \(WaitLoop.seconds(outcome.elapsed))"
        if waitsForAny, let matched = outcome.matched {
            return ("--\(matched.by) '\(matched.text)' is \(selector.presentState)", after, "\(matched.position) of \(matched.of) selectors")
        }
        if let query = selector.query {
            return ("\(query.selectorDescription) is \(gone ? "gone" : selector.presentState)", after, nil)
        }
        if settled { return ("Screen settled", after, nil) }
        if region != nil { return (stable ? "Region stable" : "Region changed", after, nil) }
        return ("Waited \(WaitLoop.seconds(outcome.elapsed))", nil, nil)
    }

    /// A person's ✅ with the time, or ❌ with the last reason and the nearest element; `shown` is already redacted.
    func personOutcome(_ shown: WaitOutcome, note: String?) -> Outcome {
        guard shown.met else {
            var details = ["Last     \(shown.reason)"]
            if let nearest = shown.nearMiss { details.append("Nearest  \(nearest.summary)") }
            if settled, !ignoreValues, shown.onlyTextMoved { details.append("Only text kept changing; --ignore-values lets it settle") }
            if let moving = shown.movingPart { details.append("Part of it keeps moving; \(moving.flag) leaves it out") }
            return .failed("Timed out after \(WaitLoop.seconds(timeout)) waiting for \(target)", details: details)
        }
        let parts = successParts(shown)
        let timing = [parts.after, parts.selectors].compactMap { $0 }.joined(separator: " · ")
        return .done(parts.headline, aside: timing.isEmpty ? nil : timing, details: note.map { [$0] } ?? [])
    }

    /// `✗ Timed out after 10 s waiting for --id 'save' (last: off screen at (20, 10700) 350x44).`
    func failureLine(_ outcome: WaitOutcome) -> String {
        let hint: String
        if settled, !ignoreValues, outcome.onlyTextMoved {
            hint = " Only text kept changing, as a live price or clock does; add --ignore-values to let it settle."
        } else if let moving = outcome.movingPart {
            hint = " Part of the screen keeps moving; add \(moving.flag) to leave it out."
        } else {
            hint = ""
        }
        let nearest = outcome.nearMiss.map { "; nearest: \($0.summary)" } ?? ""
        return "✗ Timed out after \(WaitLoop.seconds(timeout)) waiting for \(target) (last: \(outcome.reason)\(nearest)).\(hint)"
    }

    /// Each `--any` selector that matched nothing, with what it came closest to.
    static func explainAny(_ queries: [AccessibilityQuery]) -> (UITree) -> WaitNearMiss? {
        { tree in
            let misses = queries.compactMap { query in AccessibilityTargetResolver.nearMiss(roots: tree.roots, query: query).map { (query, $0) } }
            guard !misses.isEmpty else { return nil }
            return WaitNearMiss(
                summary: misses.map { "\($0.0.selectorDescription): \($0.1.summary)" }.joined(separator: "; "),
                candidates: misses.flatMap(\.1.candidates)
            )
        }
    }

    private var target: String {
        if waitsForAny {
            return "any of " + selector.queries.map(\.selectorDescription).joined(separator: ", ")
        }
        if let query = selector.query {
            if gone { return "\(query.selectorDescription) to be gone" }
            if let wanted = selector.requiredEnabled { return "\(query.selectorDescription) to be \(wanted ? "enabled" : "disabled")" }
            return selector.hasValue.map { "\(query.selectorDescription) with value '\($0)'" } ?? query.selectorDescription
        }
        if settled { return "the screen to settle" }
        if region != nil { return stable ? "the region to stay still" : "the region to change" }
        return WaitLoop.seconds(seconds ?? 0)
    }

    /// A `--gone` wait holds for half a second by default, so a node that flickers out for one read does not count as gone.
    var stableFor: TimeInterval {
        if let stableForMs { return Double(stableForMs) / 1000 }
        return gone && timeout >= Self.defaultGoneDwell ? Self.defaultGoneDwell : 0
    }

    static let defaultGoneDwell: TimeInterval = 0.5

    private var quiet: TimeInterval {
        Double(quietMs ?? Self.defaultQuietMs) / 1000
    }

    typealias TreeSource = @MainActor () async throws -> UITree

    /// The one read at the screen's centre that explains a missed selector, for the standalone command only.
    @MainActor
    static func presentationProbe(on route: DeviceRouter.Route) -> @MainActor (UITree) async -> PresentationFinding? {
        { tree in await PresentationCheck.finding(for: tree, backend: route.backend, device: route.device) }
    }

    @MainActor
    private func liveSources(on route: DeviceRouter.Route, condition: WaitCondition, tree: TreeSource?, clock: PollClock) async throws -> WaitSources {
        let backend = route.backend
        let device = route.device
        if let region {
            let request = ScreenshotRequest(region: try PointRegion.parse(region))
            let tolerance = await backend.volatileScreenBands(for: device).noiseTolerance
            return Self.sources(on: route, tree: tree, clock: clock) {
                let capture = try await ScreenCapture.capture(backend, device: device)
                return try Self.fingerprint(try ScreenCapture.render(capture, request: request), tolerance: tolerance)
            }
        }
        guard case .settled(let source, _, _, _, let leaveOut, let drawHold) = condition, source != .tree || drawHold != nil else {
            return Self.sources(on: route, tree: tree, clock: clock)
        }
        let bands = await backend.volatileScreenBands(for: device)
        let leftOut = LeftOutPixels(leaveOut)
        var sources = Self.sources(on: route, tree: tree, clock: clock) {
            let capture = try leftOut.painted(try await ScreenCapture.capture(backend, device: device))
            let rendered = try ScreenCapture.render(capture, request: ScreenshotRequest())
            let exclusion = ScreenCapture.bandPixels(rendered, capture: capture, bands: bands)
            return try Self.fingerprint(rendered, excludingTop: exclusion.top, bottom: exclusion.bottom, tolerance: bands.noiseTolerance)
        }
        let readTree = sources.tree
        sources.tree = {
            let tree = try await readTree()
            leftOut.note(tree)
            return tree
        }
        return sources
    }

    /// The pixels a `--settled` wait does not count: its rectangles, and everywhere its ids have been, since a moving element's last frame is stale by the time of the capture.
    @MainActor
    private final class LeftOutPixels {
        private let leaveOut: SettleLeaveOut
        private var swept: [String: PointRegion] = [:]

        init(_ leaveOut: SettleLeaveOut) {
            self.leaveOut = leaveOut
        }

        func note(_ tree: UITree) {
            guard !leaveOut.ids.isEmpty else { return }
            for node in tree.roots.flatMap({ $0.flattened() }) {
                guard let id = node.id, leaveOut.ids.contains(id), let frame = node.frame, frame.width > 0, frame.height > 0 else { continue }
                let region = PointRegion(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                swept[id] = swept[id].map { $0.union(region) } ?? region
            }
        }

        func painted(_ capture: CapturedScreen) throws -> CapturedScreen {
            let regions = leaveOut.regions + swept.keys.sorted().compactMap { swept[$0] }
            guard !regions.isEmpty else { return capture }
            do {
                return try ScreenCapture.masking(capture, plan: MaskPlan(regions: regions), tree: nil).capture
            } catch is MaskUnproven {
                throw ImageFailure(detail: "this capture could not be mapped to points, so --ignore-region and --ignore-id cannot leave out its pixels; use --settle-by tree")
            }
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

    /// The outcome with its reason, near miss and matched element's screen text redacted.
    static func shown(_ outcome: WaitOutcome, mask: TreeValueMask = .none) -> WaitOutcome {
        var shown = WaitOutcome(
            met: outcome.met, elapsed: outcome.elapsed, reason: LogRedactor.redactValue(outcome.reason).text,
            match: outcome.match.map { redacted($0, mask: mask) }, matched: outcome.matched
        )
        shown.onlyTextMoved = outcome.onlyTextMoved
        shown.movingPart = outcome.movingPart.flatMap { LogRedactor.redactValue($0.flag).text == $0.flag ? $0 : nil }
        shown.nearMiss = outcome.nearMiss.map { WaitNearMiss(summary: LogRedactor.redactValue($0.summary).text, candidates: $0.candidates) }
        return shown
    }

    /// `; describe-ui shows it redacted` when the check compared a value or label the tree output hides: it decides with the real text.
    static func redactionNote(_ outcome: WaitOutcome, checked: ElementSelectorOptions?, mask: TreeValueMask = .none) -> String {
        guard let checked, checked.hasValue != nil || !checked.elementLabelsContaining.isEmpty else { return "" }
        let hidden: Bool
        if let match = outcome.match {
            let shown = redacted(match, mask: mask)
            hidden = (checked.hasValue != nil && shown.value != match.value)
                || checked.elementLabelsContaining.contains { query in
                    SelectorText.folded(match.label ?? "", contains: query) && !SelectorText.folded(shown.label ?? "", contains: query)
                }
        } else {
            hidden = ([checked.hasValue].compactMap { $0 } + checked.elementLabelsContaining).contains { LogRedactor.redactValue($0).count > 0 }
        }
        return hidden ? " (\(redactedNote))" : ""
    }

    static let redactedNote = "matched on the real text; describe-ui shows it redacted"

    private static func redacted(_ node: UINode, mask: TreeValueMask) -> UINode {
        var single = node
        single.children = []
        return UITree(platform: .ios, device: "", roots: [single]).redacted(mask).roots.first ?? single
    }

    private static func fingerprint(_ rendered: RenderedScreenshot, excludingTop top: Int = 0, bottom: Int = 0, tolerance: Int = 0) throws -> ImageFingerprint {
        guard let fingerprint = ImageFingerprint(image: rendered.image, excludingTopPixels: top, excludingBottomPixels: bottom, tolerance: tolerance) else {
            throw ImageFailure(detail: "could not read the screenshot's pixels")
        }
        return fingerprint
    }

    /// Prints the outcome (the JSON report on stdout with `json`, human text on stderr) and exits 5 when it was not met.
    /// Screen text in it is redacted as `describe-ui` redacts it; `checked` adds a note when the value or label it matched is text the tree output hides.
    /// A person reads `person`'s receipt in place of the `✓` or `✗` line, which an agent and `--json` always read.
    static func report(
        _ outcome: WaitOutcome, success: String, failure: String, json: Bool, checked: ElementSelectorOptions? = nil, mask: TreeValueMask = .none,
        person: ((WaitOutcome, String?) -> Outcome)? = nil, console: Console = .current
    ) throws {
        let note = outcome.met ? redactionNote(outcome, checked: checked, mask: mask) : ""
        let line = outcome.met ? success + note : LogRedactor.redactValue(failure).text
        if json {
            console.data(WaitReport(shown(outcome, mask: mask)).jsonLine() + "\n")
            console.data(line + "\n", to: .err)
        } else if let person, outcome.met {
            let receipt = person(shown(outcome, mask: mask), note.isEmpty ? nil : redactedNote)
            console.show(Page([.person([.outcome(receipt)]), .agent(line + "\n")]))
        } else if let person, console.err.profile == .person {
            let failed = person(shown(outcome, mask: mask), nil)
            let redacted = Outcome(ok: false, headline: LogRedactor.redactValue(failed.headline).text, details: failed.details.map { LogRedactor.redactValue($0).text })
            console.data(PersonRenderer.body([.outcome(redacted)], canvas: console.err.canvas), to: .err)
        } else {
            console.data(line + "\n", to: outcome.met ? .out : .err)
        }
        if !outcome.met {
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
    }
}
