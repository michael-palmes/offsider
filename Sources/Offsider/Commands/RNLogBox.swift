import ArgumentParser
import Foundation
import OffsiderCore

struct RNLogBox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logbox",
        abstract: "Read, open or clear React Native's LogBox toasts and inspector in a debug build.",
        subcommands: [RNLogBoxStatus.self, RNLogBoxOpen.self, RNLogBoxDismiss.self]
    )

    /// No toast numbered `index`: exit 2, with the toasts on screen as the candidates.
    static func noToast(_ index: Int, in state: LogBoxState, device: String) -> CLIError {
        let have = state.toasts.isEmpty ? "there are none on screen" : "there \(state.toasts.count == 1 ? "is 1" : "are \(state.toasts.count)")"
        return CLIError(
            errorDescription: "No LogBox toast \(index): toasts count from 1 at the bottom, and \(have).",
            reason: .selectorNotFound,
            hint: "offsider rn logbox status --device \(device)",
            candidates: state.toasts.map { FailureCandidate(id: nil, label: LogBoxState.shown($0.message, redacts: true), role: "logbox", frame: $0.frame, onScreen: true, index: $0.index) }
        )
    }
}

struct RNLogBoxStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read LogBox's toasts and inspector from the screen without tapping; always exits 0.",
        discussion: """
        Lists each toast bottom first, numbered from 1 as `open --index` and `dismiss --index` take them, with its \
        message after the `!` or count, and its log count when above 1. Messages are redacted as `logs` redacts them \
        unless --no-redact.
        """
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout: logs, toasts (index, count, message, frame) and inspector.")
    var json = false

    @Flag(name: .customLong("no-redact"), help: "Show passwords, tokens, keys, cookies, JWTs and email addresses in messages.")
    var noRedact = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        let logger = OffsiderLogger()
        let locking = DeviceIDClassifier.classify(deviceOption.id).platform == .android
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger, locking: locking)
        try await route.backend.prepare()
        let state = LogBoxState(tree: try await route.backend.accessibilityTree(for: route.device))
        print(json ? state.jsonLine(redacts: !noRedact) : state.text(redacts: !noRedact))
    }
}

struct RNLogBoxOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open the LogBox inspector on one toast, to read its whole log with describe-ui.",
        discussion: """
        Taps toast --index's body (1, the bottom one, by default) and waits up to 5 s for the inspector. An inspector \
        that is already open is reported without a tap. Exits 2 when there is no such toast and 5 when the inspector \
        does not open. Read the log with describe-ui, then close it with `rn logbox dismiss` or `tap --label Minimize`.

        Example:
          offsider rn logbox open --index 2 --device DEVICE_ID
        """
    )

    @Option(help: ArgumentHelp("The toast to open, counted from 1 at the bottom as status lists them.", valueName: "n"))
    var index = 1

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout: index, message, log and of.")
    var json = false

    @Flag(name: .customLong("no-redact"), help: "Show passwords, tokens, keys, cookies, JWTs and email addresses in the message.")
    var noRedact = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let inspectorWait: TimeInterval = 5
    static let poll: Duration = .milliseconds(300)

    typealias Opened = LogBoxOpening

    func validate() throws {
        guard index >= 1 else { throw ValidationError("--index counts toasts from 1 at the bottom; got \(index).") }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let opened = try await open(on: route)
        print(json ? opened.jsonLine(redacts: !noRedact) : opened.textLine(redacts: !noRedact))
    }

    @MainActor
    func open(on route: DeviceRouter.Route, clock: PollClock = .live) async throws -> Opened {
        try await route.backend.prepare()
        var state = LogBoxState(tree: try await route.backend.accessibilityTree(for: route.device))
        if let inspector = state.inspector { return Opened(toast: nil, inspector: inspector) }
        guard let toast = state.toast(index) else { throw RNLogBox.noToast(index, in: state, device: route.device.rawValue) }
        let point = try await route.backend.deviceCoordinates(for: [(x: toast.bodyPoint.x, y: toast.bodyPoint.y)], tree: nil, on: route.device)[0]
        try await route.backend.performTracked(.tapAt(x: point.x, y: point.y), on: route.device)
        let deadline = clock.now() + Self.inspectorWait
        repeat {
            try await clock.sleep(Self.poll)
            state = LogBoxState(tree: try await route.backend.accessibilityTree(for: route.device))
            if let inspector = state.inspector { return Opened(toast: toast, inspector: inspector) }
        } while clock.now() < deadline
        throw CLIError(
            errorDescription: "Tapped LogBox toast \(index), but the inspector did not open within \(Int(Self.inspectorWait)) s.",
            reason: .notVerified,
            hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
        )
    }
}

struct RNLogBoxDismiss: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Clear every LogBox log on screen: each toast's clear button, else through the inspector's Dismiss.",
        discussion: """
        Taps each toast's clear button, bottom first, and checks that its logs went. When a tap leaves the toast, \
        it opens the inspector by tapping the toast and taps Dismiss once per log. An open inspector is dismissed first. \
        --index clears only that toast, counted from 1 at the bottom as status lists them (exit 2 when there is none). \
        Exits 0 when no log is left (or none was there) and 5 (not_verified) when some remain.

        Examples:
          offsider rn logbox dismiss --device DEVICE_ID
          offsider rn logbox dismiss --index 2 --device DEVICE_ID
        """
    )

    @Option(help: ArgumentHelp("Clear only this toast, counted from 1 at the bottom.", valueName: "n"))
    var index: Int?

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
        if let index, index < 1 {
            throw ValidationError("--index counts toasts from 1 at the bottom; got \(index).")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let outcome = try await dismiss(on: route)
        let line = outcome.cleared == 0 && outcome.remaining == 0 && index == nil
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
        if let index {
            return try await dismissOnly(index, from: state, route: route, clock: clock, deadline: deadline)
        }
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

    /// Clears toast `index` alone: its clear button, else its inspector with one Dismiss per log it counts.
    @MainActor
    private func dismissOnly(_ index: Int, from start: LogBoxState, route: DeviceRouter.Route, clock: PollClock, deadline: TimeInterval) async throws -> Outcome {
        guard start.inspector == nil else {
            throw CLIError(
                errorDescription: "The LogBox inspector is open, so its toasts are hidden. Close it with `tap --label Minimize`, then dismiss toast \(index); or clear every log with `rn logbox dismiss`.",
                reason: .stateNotReached,
                hint: "offsider tap --label Minimize --device \(route.device.rawValue)"
            )
        }
        guard let toast = start.toast(index) else { throw RNLogBox.noToast(index, in: start, device: route.device.rawValue) }
        try await tap(toast.dismissPoint, route: route)
        try await clock.sleep(Self.settle)
        var state = try await read(route)
        if state.logs <= start.logs - toast.count {
            return Outcome(cleared: start.logs - state.logs, remaining: 0, method: .dismissButton)
        }
        try await tap(toast.bodyPoint, route: route)
        let opened = clock.now() + Self.inspectorWait
        repeat {
            try await clock.sleep(Self.settle)
            state = try await read(route)
        } while state.inspector == nil && clock.now() < opened
        guard state.inspector != nil else { return Outcome(cleared: 0, remaining: toast.count, method: .none) }
        state = try await dismissInspector(state, presses: toast.count, route: route, clock: clock, deadline: deadline)
        let left = state.inspector != nil ? max(state.inspector?.of ?? 1, 1) : max(0, state.logs - (start.logs - toast.count))
        return Outcome(cleared: max(toast.count - left, 0), remaining: min(left, toast.count), method: .inspector)
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
