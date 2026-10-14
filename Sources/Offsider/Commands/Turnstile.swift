import ArgumentParser
import Foundation
import OffsiderCore

struct Turnstile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "turnstile",
        abstract: "Read the state of a Cloudflare Turnstile widget. It never taps the widget.",
        discussion: """
        Prints one state: checkbox, verifying, passed, challenge or absent, and exits 0 (6 when several \
        checkboxes are on screen). It finds a cf-chl-widget container, or a checkbox labelled Verify you are \
        human. On iOS the web view leaves the checkbox out of the tree, so the command reads points in the \
        short web view. --id limits the search to one element, such as the app's wrapper around the widget.

        Offsider never ticks Turnstile. A checkbox or a challenge is for a person: hand the device to them, \
        then carry on once this command reads passed.
        """
    )

    @Option(name: .customLong("id"), help: "Only look inside the element with this id, such as the app's wrapper around the widget.")
    var elementID: String?

    /// Kept for one release so scripts that pass it still run; the command always only reads.
    @Flag(name: .customLong("status"), help: .hidden)
    var status = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--id must not be empty.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
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
    }

    /// One read, no input: the tree first, then on iOS points in the web view.
    @MainActor
    func readStatus(on route: DeviceRouter.Route, onPrepared: @Sendable () -> Void = {}) async throws -> TurnstileStatus {
        try await route.backend.prepare()
        onPrepared()
        let tree = try await route.backend.accessibilityTree(for: route.device)
        return try await Self.status(in: tree, on: route, scopeID: elementID)
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
        if phase == .absent || phase == .checking {
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
