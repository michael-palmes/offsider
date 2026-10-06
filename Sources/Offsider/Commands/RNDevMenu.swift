import ArgumentParser
import Foundation
import OffsiderCore

extension DevMenu.Item: ExpressibleByArgument {}

/// Shared by `rn devmenu` and `rn tools off`: open the menu, tap one item, and wait for the menu to close.
@MainActor
struct DevMenuDriver {
    let route: DeviceRouter.Route
    let clock: PollClock

    static let openWait: TimeInterval = 5
    static let closeWait: TimeInterval = 3
    static let poll: Duration = .milliseconds(300)

    func read() async throws -> UITree {
        try await route.backend.accessibilityTree(for: route.device)
    }

    /// The menu, opening it first; a menu that never shows is `state_not_reached`, as in a Release build.
    func open() async throws -> (DevMenu.State, UITree) {
        let tree = try await read()
        if let state = DevMenu.read(tree) { return (state, tree) }
        guard let opener = route.backend as? any ReactNativeDevMenuOpening else {
            throw CLIError(
                errorDescription: "Offsider cannot open the dev menu on \(route.device.rawValue). On a physical iPhone, open it with the app's own gesture, such as `touch --fingers 2 --hold 1000`.",
                reason: .notSupported
            )
        }
        try await opener.openDevMenu(route.device)
        let deadline = clock.now() + Self.openWait
        repeat {
            try await clock.sleep(Self.poll)
            let tree = try await read()
            if let state = DevMenu.read(tree) { return (state, tree) }
        } while clock.now() < deadline
        throw CLIError(
            errorDescription: "The React Native dev menu did not open on \(route.device.rawValue) within \(Int(Self.openWait)) s. Release builds have none; check this is a debug build.",
            reason: .stateNotReached,
            hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
        )
    }

    /// Taps the item, closes the menu if a switch left it open, and returns once it is gone.
    func choose(_ item: DevMenu.Item?, label: String?, state: DevMenu.State, tree: UITree) async throws {
        guard let node = DevMenu.node(for: item, label: label, in: tree), let frame = node.frame else {
            let name = label.map { "--label '\($0)'" } ?? item?.rawValue ?? "item"
            throw CLIError(
                errorDescription: "The \(state.menu) dev menu has no \(name). Its items: \(state.items.map(\.label).joined(separator: ", ")).",
                reason: .selectorNotFound,
                hint: "offsider rn devmenu --device \(route.device.rawValue)",
                candidates: state.items.map { FailureCandidate(id: nil, label: $0.label, role: $0.role.rawValue, frame: $0.frame, onScreen: true) }
            )
        }
        try await tap(frame.center, tree: tree)
        if try await closed(leaving: state.menu) { return }
        if item?.isToggle == true || label != nil, let close = DevMenu.node(for: .close, label: nil, in: try await read()), let closeFrame = close.frame {
            try await tap(closeFrame.center, tree: nil)
            if try await closed(leaving: state.menu) { return }
        }
        throw CLIError(
            errorDescription: "Tapped \(node.label ?? item?.rawValue ?? "the item"), but the dev menu is still open.",
            reason: .notVerified,
            hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
        )
    }

    /// True once `menu` is gone: no menu shows, or the item opened the other one, as Expo's "Open React Native dev menu" does.
    private func closed(leaving menu: String) async throws -> Bool {
        let deadline = clock.now() + Self.closeWait
        repeat {
            try await clock.sleep(Self.poll)
            if let tree = try? await read(), DevMenu.read(tree)?.menu != menu { return true }
        } while clock.now() < deadline
        return false
    }

    private func tap(_ point: UIPoint, tree: UITree?) async throws {
        let physical = try await route.backend.deviceCoordinates(for: [(x: point.x, y: point.y)], tree: tree, on: route.device)[0]
        try await route.backend.performTracked(.tapAt(x: physical.x, y: physical.y), on: route.device)
    }
}

struct RNDevMenu: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devmenu",
        abstract: "Open a React Native debug build's dev menu, list its items, or choose one.",
        discussion: """
        Opens the Expo dev menu (or React Native's) by shake on an iOS simulator and the menu key on Android. \
        Without an item it prints the items and leaves the menu open. With one (reload, home, inspector, \
        perf-monitor, fast-refresh, debugger, close) or --label, it taps it and waits until the menu closes, \
        closing it after a switch. Exits 2 when the menu has no such item (the items are the candidates), 1 when \
        the menu never opens (a Release build has none) and 5 when it stays open.

        Examples:
          offsider rn devmenu --device DEVICE_ID
          offsider rn devmenu reload --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The item to choose.", valueName: "reload|home|inspector|perf-monitor|fast-refresh|debugger|close"))
    var item: DevMenu.Item?

    @Option(help: ArgumentHelp("Choose the item with this exact label instead.", valueName: "text"))
    var label: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        if item != nil && label != nil {
            throw ValidationError("Pass an item or --label, not both.")
        }
        if let label, label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--label must not be empty.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let state = try await perform(on: route, clock: .live)
        if let state {
            print(json ? DevMenu.jsonLine(state) : "\(state.menu) dev menu: " + state.items.map(\.label).joined(separator: ", "))
        } else {
            print("✓ Chose \(label ?? item?.rawValue ?? "") and the dev menu closed")
        }
    }

    /// The open menu's state when no item is asked for; nil after choosing one.
    @MainActor
    func perform(on route: DeviceRouter.Route, clock: PollClock) async throws -> DevMenu.State? {
        try await route.backend.prepare()
        let driver = DevMenuDriver(route: route, clock: clock)
        let (state, tree) = try await driver.open()
        guard item != nil || label != nil else { return state }
        try await driver.choose(item, label: label, state: state, tree: tree)
        return nil
    }
}

struct RNTools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Developer tools in a React Native debug build.",
        subcommands: [RNToolsOff.self]
    )
}

struct RNToolsOff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: "Turn off the element inspector and the performance monitor when they show, through the dev menu.",
        discussion: """
        Reads the screen for the inspector's panel and the performance monitor's frame rates, and for each one \
        that shows, opens the dev menu, chooses its item and checks it went. Prints off or turned-off for each. \
        A screen it cannot read is an error rather than a blind toggle.
        """
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let (inspector, perf) = try await turnOff(on: route, clock: .live)
        print(json ? DevMenu.toolsJSONLine(inspector: inspector, perfMonitor: perf) : "Element inspector: \(inspector); performance monitor: \(perf)")
    }

    @MainActor
    func turnOff(on route: DeviceRouter.Route, clock: PollClock) async throws -> (inspector: String, perfMonitor: String) {
        try await route.backend.prepare()
        let driver = DevMenuDriver(route: route, clock: clock)
        let tree: UITree
        do {
            tree = try await driver.read()
        } catch {
            throw CLIError(
                errorDescription: "Could not read the screen of \(route.device.rawValue), so Offsider cannot tell whether the inspector or the performance monitor shows, and will not toggle them blind.",
                reason: .notSupported
            )
        }
        let shown = DevMenu.tools(in: tree)
        var result = (inspector: "off", perfMonitor: "off")
        for (item, isOn) in [(DevMenu.Item.inspector, shown.inspector), (.perfMonitor, shown.perfMonitor)] where isOn {
            let (state, menuTree) = try await driver.open()
            try await driver.choose(item, label: nil, state: state, tree: menuTree)
            let after = DevMenu.tools(in: try await driver.read())
            let stillOn = item == .inspector ? after.inspector : after.perfMonitor
            guard !stillOn else {
                throw CLIError(errorDescription: "The \(item == .inspector ? "element inspector" : "performance monitor") still shows after choosing it in the dev menu.", reason: .notVerified)
            }
            if item == .inspector { result.inspector = "turned-off" } else { result.perfMonitor = "turned-off" }
        }
        return result
    }
}
