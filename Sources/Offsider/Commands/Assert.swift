import ArgumentParser
import Foundation
import OffsiderCore

struct Assert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assert",
        abstract: "Check once that an element is on screen (optionally with a value) or gone; exits 5 when it is not",
        discussion: """
        Reads the accessibility tree once. Only on-screen matches count unless --allow-offscreen; several matches still pass. \
        To wait for the state instead, use offsider wait with the same selector. Exits 1 (logbox_inspector_open) when \
        React Native's LogBox inspector hides the app on Android.
        """
    )

    @OptionGroup
    var selector: ElementSelectorOptions

    @Flag(name: .customLong("gone"), help: "Pass when no matching element is on screen.")
    var gone = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    func validate() throws {
        try selector.validateCount(allowingSeveral: false)
        guard selector.query != nil else {
            throw ValidationError("Provide --id, --label, --label-contains or --value to choose the element to check.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        // An Android tree read locks the device, so the claim (and any --wait-lock) comes before the watchdog's bound.
        let locking = DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: locking)
        let outcome = try await Console.current.progress("Checking \(subject)") {
            try await watchdog.guarding(setupThen: 0, device: deviceOption.id) { ready in
                try await evaluate(on: route, logger: logger, probesOnMiss: true, onPrepared: ready)
            }
        }
        let mask = (try? await AmbientMasks.treeMask()) ?? .none
        try Wait.report(
            outcome, success: successLine(outcome), failure: failureLine(outcome), json: json, checked: selector, mask: mask, person: personOutcome
        )
    }

    /// One read on `route` without printing; a batch step or a test reports the outcome itself. `tree` replaces the device's tree read; `probesOnMiss` reads the screen's centre once when the check fails.
    @MainActor
    func evaluate(
        on route: DeviceRouter.Route, logger: OffsiderLogger, tree: Wait.TreeSource? = nil, probesOnMiss: Bool = false, onPrepared: @Sendable () -> Void = {}
    ) async throws -> WaitOutcome {
        guard let query = selector.query else {
            throw CLIError(errorDescription: "Unexpected state: no element query.", reason: .internalError)
        }
        appOption.apply(to: route)
        try await route.backend.prepare()
        onPrepared()
        var sources = Wait.sources(on: route, tree: tree)
        if probesOnMiss {
            sources.probe = Wait.presentationProbe(on: route)
        }
        return try await WaitLoop.run(
            .element(probe: selector.probe(for: query), gone: gone, explain: SelectorQuery.explain(query)),
            timeout: 0,
            interval: 0,
            sources: sources
        )
    }

    /// `✓ --id 'count' is on screen with value '3'` or `✓ --id 'banner' is gone`.
    func successLine(_ outcome: WaitOutcome) -> String {
        "✓ \(subject) is \(gone ? "gone" : selector.presentState)"
    }

    /// `✗ Assertion failed: --id 'count' has value '2', expected '3'.`, or for a miss `... was not found (nearest: ...).`
    func failureLine(_ outcome: WaitOutcome) -> String {
        let nearest = outcome.nearMiss.map { " (nearest: \($0.summary))" } ?? ""
        return "✗ Assertion failed: \(subject) \(Self.predicate(outcome.reason))\(nearest)."
    }

    /// A person's ✅ naming the state that held, or ❌ with what was there instead and the nearest element; `shown` is already redacted.
    func personOutcome(_ shown: WaitOutcome, note: String?) -> Outcome {
        guard shown.met else {
            return .failed("\(subject) \(Self.predicate(shown.reason))", details: shown.nearMiss.map { ["Nearest  \($0.summary)"] } ?? [])
        }
        return .done("\(subject) is \(gone ? "gone" : selector.presentState)", details: note.map { [$0] } ?? [])
    }

    private var subject: String {
        selector.query?.selectorDescription ?? ""
    }

    /// Turns a loop reason such as "not found" into the end of a sentence: "was not found".
    static func predicate(_ reason: String) -> String {
        if reason == "not found" || reason.hasPrefix("not found;") { return "was \(reason)" }
        if reason.hasPrefix("off screen") || reason.hasPrefix("still") { return "is \(reason)" }
        return reason
    }
}
