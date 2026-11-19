import ArgumentParser
import Foundation
import OffsiderCore

struct Keyboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hide the on-screen keyboard and say whether it went away.",
        discussion: """
        `hide` sends only the keyboard's own way out: on iOS its hide key (an iPad has one) or Done in the bar on top \
        of the keys, on Android Back while docked keys are up. It never presses Return, which can submit a form. \
        It then reads the screen for up to 1.5 s and reports `hidden`; with no keyboard up it reports `absent` and \
        sends nothing. Exit 1 (state_not_reached) when the keyboard has no way out of its own, as an iPhone's has \
        without an app's Done bar, or stays up.

        --tap-outside also tries up to three taps on empty space clear of the keys and of every text field, as \
        `login` does. Leave it off over a sheet or dialog that closes when its backdrop is tapped.

        Examples:
          offsider keyboard hide --device DEVICE_ID
          offsider keyboard hide --tap-outside --json --device DEVICE_ID
        """
    )

    enum Action: String, ExpressibleByArgument, CaseIterable {
        case hide
    }

    @Argument(help: "hide.")
    var action: Action

    @Flag(name: .customLong("tap-outside"), help: "With no hide key or Done bar, or when it did not work, tap empty space clear of the keys and fields, up to three times.")
    var tapOutside = false

    @OptionGroup
    var jsonOption: InputJSONOption

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    /// How long the keys may take to slide away, and how often the screen is read meanwhile.
    static let settle: Duration = .milliseconds(1500)
    static let poll: Duration = .milliseconds(250)

    func run() async throws {
        try await InputOutput.reporting(command: "keyboard", target: "hide", json: jsonOption.json) { details in
            let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
            await appOption.apply(to: route)
            try await route.backend.prepare()
            _ = try await route.backend.requireBootedDevice(route.device)
            let outcome = try await Self.hide(
                tapOutside: tapOutside, device: deviceOption.id,
                read: { try await route.backend.accessibilityTree(for: route.device) },
                ownWayOut: { tree in try await LoginCommand.hideKeyboard(in: tree, on: route) },
                tap: { point, tree in
                    let physical = try await route.backend.deviceCoordinates(for: [(x: point.x, y: point.y)], tree: tree, on: route.device)[0]
                    try await route.backend.performTracked(.tapAt(x: physical.x, y: physical.y), on: route.device)
                }
            )
            details.value = outcome.rawValue
            switch outcome {
            case .absent: Console.current.show(InputPersonView.receipt("No keyboard is up", agent: "No keyboard is up; nothing sent\n"))
            case .hidden: Console.current.show(InputPersonView.receipt("Keyboard hidden", agent: "Keyboard hidden\n"))
            }
        }
    }

    enum Outcome: String {
        case absent
        case hidden
    }

    /// The keyboard's own way out, then with `tapOutside` taps on empty space, reading after each until the keyboard is gone.
    @MainActor
    static func hide(
        tapOutside: Bool,
        device: String,
        read: () async throws -> UITree,
        ownWayOut: (UITree) async throws -> Void,
        tap: (UIPoint, UITree) async throws -> Void,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Outcome {
        var tree = try await read()
        let step = KeyboardHide.step(in: tree)
        if step == .absent { return .absent }
        func settled() async throws -> UITree {
            var waited: Duration = .zero
            while true {
                let next = try await read()
                if !KeyboardHide.isUp(next) || waited >= settle { return next }
                try await sleep(poll)
                waited += poll
            }
        }
        if step != .noWayOut {
            try await ownWayOut(tree)
            tree = try await settled()
            if !KeyboardHide.isUp(tree) { return .hidden }
        }
        guard tapOutside else {
            let hint = "offsider keyboard hide --tap-outside --device \(device)"
            throw CLIError(
                errorDescription: step == .noWayOut
                    ? "This keyboard has no hide key or Done bar, so nothing was sent. Tap a spot outside the field, or pass --tap-outside to try empty space above the keys."
                    : "The keyboard is still up after its own way out. Tap a spot outside the field, or pass --tap-outside to try empty space above the keys.",
                reason: .stateNotReached, hint: hint
            )
        }
        // The way out already tried is the first point the search would offer.
        var avoided: [UIPoint] = []
        if case .control(let point) = step { avoided.append(point) }
        var taps = 0
        while taps < KeyboardDismiss.attempts, let point = KeyboardHide.outsidePoint(in: tree, tried: avoided) {
            try await tap(point, tree)
            avoided.append(point)
            taps += 1
            tree = try await settled()
            if !KeyboardHide.isUp(tree) { return .hidden }
        }
        throw CLIError(
            errorDescription: taps == 0
                ? "The keyboard is still up: no empty space clear of the keys and fields is left to tap. Close it in the app."
                : "The keyboard is still up after \(taps) tap\(taps == 1 ? "" : "s") on empty space. Close it in the app.",
            reason: .stateNotReached, hint: CommandScope.current.describeHint(device: device)
        )
    }
}
