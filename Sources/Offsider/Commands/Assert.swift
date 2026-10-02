import ArgumentParser
import Foundation
import OffsiderCore

struct Assert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assert",
        abstract: "Check once that an element is on screen (optionally with a value) or gone; exits 5 when it is not",
        discussion: """
        Reads the accessibility tree once. Only on-screen matches count unless --allow-offscreen; several matches still pass. \
        To wait for the state instead, use offsider wait with the same selector.
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

    func validate() throws {
        guard selector.query != nil else {
            throw ValidationError("Provide --id, --label or --value to choose the element to check.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let outcome = try await DeviceWatchdog().guarding(bound: 0, device: deviceOption.id) {
            let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
            return try await evaluate(on: route, logger: logger)
        }
        try Wait.report(outcome, success: successLine(outcome), failure: failureLine(outcome), json: json)
    }

    /// One read on `route` without printing; a batch step or a test reports the outcome itself. `tree` replaces the device's tree read.
    @MainActor
    func evaluate(on route: DeviceRouter.Route, logger: OffsiderLogger, tree: Wait.TreeSource? = nil) async throws -> WaitOutcome {
        guard let query = selector.query else {
            throw CLIError(errorDescription: "Unexpected state: no element query.")
        }
        try await route.backend.prepare()
        return try await WaitLoop.run(
            .element(probe: selector.probe(for: query), gone: gone),
            timeout: 0,
            interval: 0,
            sources: Wait.sources(on: route, tree: tree)
        )
    }

    /// `✓ --id 'count' is on screen with value '3'` or `✓ --id 'banner' is gone`.
    func successLine(_ outcome: WaitOutcome) -> String {
        "✓ \(subject) is \(gone ? "gone" : selector.presentState)"
    }

    /// `✗ Assertion failed: --id 'count' has value '2', expected '3'.`
    func failureLine(_ outcome: WaitOutcome) -> String {
        "✗ Assertion failed: \(subject) \(Self.predicate(outcome.reason))."
    }

    private var subject: String {
        selector.query?.selectorDescription ?? ""
    }

    /// Turns a loop reason such as "not found" into the end of a sentence: "was not found".
    static func predicate(_ reason: String) -> String {
        if reason == "not found" { return "was not found" }
        if reason.hasPrefix("off screen") || reason.hasPrefix("still") { return "is \(reason)" }
        return reason
    }
}
