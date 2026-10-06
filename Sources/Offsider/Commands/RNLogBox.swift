import ArgumentParser
import Foundation
import OffsiderCore

struct RNLogBox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logbox",
        abstract: "Read or clear React Native's LogBox toasts and inspector in a debug build.",
        subcommands: [RNLogBoxStatus.self, RNLogBoxDismiss.self]
    )
}

struct RNLogBoxStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read LogBox's toasts and inspector from the screen without tapping; always exits 0."
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        let logger = OffsiderLogger()
        let locking = DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger, locking: locking)
        try await route.backend.prepare()
        let state = LogBoxState(tree: try await route.backend.accessibilityTree(for: route.device))
        print(json ? state.jsonLine() : state.textLine())
    }
}

struct RNLogBoxDismiss: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Clear every LogBox log on screen: each toast's clear button, else through the inspector's Dismiss.",
        discussion: """
        Taps each toast's clear button, bottom first, and checks that its logs went. When a tap leaves the toast, \
        it opens the inspector by tapping the toast and taps Dismiss once per log. An open inspector is dismissed first. \
        Exits 0 when no log is left (or none was there) and 5 (not_verified) when some remain.

        Example:
          offsider rn logbox dismiss --device DEVICE_ID
        """
    )

    @Option(help: ArgumentHelp("Give up after this many seconds, from 1 to 60.", valueName: "seconds"))
    var timeout: Double = 15

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout: cleared, remaining and method.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    typealias Method = LogBoxDismissal.Method
    typealias Outcome = LogBoxDismissal

    static let settle: Duration = .milliseconds(500)
    static let inspectorWait: TimeInterval = 5

    func validate() throws {
        guard timeout.isFinite, (1...60).contains(timeout) else {
            throw ValidationError("--timeout must be from 1 to 60 seconds; got \(timeout).")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let outcome = try await dismiss(on: route)
        let line = outcome.cleared == 0 && outcome.remaining == 0
            ? "No LogBox logs on screen"
            : outcome.remaining == 0
                ? "✓ Cleared \(outcome.cleared) LogBox log\(outcome.cleared == 1 ? "" : "s") (\(outcome.method.rawValue))"
                : "✗ \(outcome.remaining) LogBox log\(outcome.remaining == 1 ? " is" : "s are") still on screen after clearing \(outcome.cleared)."
        if json {
            print(outcome.jsonLine())
            print(line, to: &standardError)
        } else if outcome.remaining == 0 {
            print(line)
        } else {
            print(line, to: &standardError)
        }
        if outcome.remaining > 0 {
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
    }

    /// Clears the inspector, then each toast bottom first; `clock` lets tests run without real waits.
    @MainActor
    func dismiss(on route: DeviceRouter.Route, clock: PollClock = .live) async throws -> Outcome {
        try await route.backend.prepare()
        let deadline = clock.now() + timeout
        var state = try await read(route)
        let initial = max(state.logs, state.inspector?.of ?? 0)
        guard !state.isEmpty else { return Outcome(cleared: 0, remaining: 0, method: .none) }
        var method = Method.none

        if state.inspector != nil {
            state = try await dismissInspector(state, presses: (state.inspector?.of ?? 1) + 2, route: route, clock: clock, deadline: deadline)
            method = .inspector
        }
        while let toast = state.toasts.first, clock.now() < deadline {
            let before = state.logs
            try await tap(toast.dismissPoint, route: route)
            try await clock.sleep(Self.settle)
            state = try await read(route)
            if state.logs <= before - toast.count {
                if method == .none { method = .dismissButton }
                continue
            }
            try await tap(toast.bodyPoint, route: route)
            let opened = clock.now() + Self.inspectorWait
            repeat {
                try await clock.sleep(Self.settle)
                state = try await read(route)
            } while state.inspector == nil && clock.now() < opened
            guard state.inspector != nil else { break }
            state = try await dismissInspector(state, presses: toast.count + 2, route: route, clock: clock, deadline: deadline)
            method = .inspector
            if state.inspector != nil { break }
        }
        let remaining = max(state.logs, state.inspector?.of ?? (state.inspector != nil ? 1 : 0))
        return Outcome(cleared: max(initial - remaining, 0), remaining: remaining, method: method)
    }

    @MainActor
    private func dismissInspector(_ start: LogBoxState, presses: Int, route: DeviceRouter.Route, clock: PollClock, deadline: TimeInterval) async throws -> LogBoxState {
        var state = start
        var left = presses
        while left > 0, let inspector = state.inspector, clock.now() < deadline {
            guard let button = inspector.dismiss else {
                throw CLIError(
                    errorDescription: "The LogBox inspector is open but its Dismiss button is not in the tree.",
                    reason: .notSupported,
                    hint: "offsider tap --label Dismiss --device \(route.device.rawValue)"
                )
            }
            try await tap(button.center, route: route)
            try await clock.sleep(Self.settle)
            state = try await read(route)
            left -= 1
        }
        return state
    }

    @MainActor
    private func read(_ route: DeviceRouter.Route) async throws -> LogBoxState {
        LogBoxState(tree: try await route.backend.accessibilityTree(for: route.device))
    }

    @MainActor
    private func tap(_ point: UIPoint, route: DeviceRouter.Route) async throws {
        let physical = try await route.backend.deviceCoordinates(for: [(x: point.x, y: point.y)], tree: nil, on: route.device)[0]
        try await route.backend.performTracked(.tapAt(x: physical.x, y: physical.y), on: route.device)
    }
}
