import ArgumentParser
import Foundation
import OffsiderCore
import OffsiderIOSDevice

extension DevMenu.Item: ExpressibleByArgument {}

/// Shared by `rn devmenu`, its batch step and `rn tools off`: open the menu, tap one item, and wait for the menu to close.
@MainActor
struct DevMenuDriver {
    let route: DeviceRouter.Route
    let clock: PollClock
    /// Sends the menu key and taps; a batch step passes its own session so they count as the step's input.
    var send: (@MainActor (InputEvent) async throws -> Void)?

    static let openWait: TimeInterval = 5
    static let closeWait: TimeInterval = 5
    static let poll: Duration = .milliseconds(300)
    static let switchHold: TimeInterval = 0.2

    func read() async throws -> UITree {
        try await route.backend.accessibilityTree(for: route.device)
    }

    /// The menu, opening it first; a menu that never shows is `state_not_reached`, as in a Release build.
    /// `check` runs after the first read, which refuses an app a phone is not allowed for, and before any input.
    func open(check: (() async throws -> Void)? = nil) async throws -> (DevMenu.State, UITree) {
        let tree = try await read()
        try await check?()
        if let state = DevMenu.read(tree) { return (state, tree) }
        if route.device.platform == .android {
            try await perform(.shortButtonPress(.menu))
        } else if let opener = route.backend as? any ReactNativeDevMenuOpening {
            defer { DeviceActivityLedger.current.recordInput(on: route.device) }
            try await DispatchTracker.current.sending { try await opener.openDevMenu(route.device) }
        } else {
            throw CLIError(
                errorDescription: "Offsider cannot open the dev menu on \(route.device.rawValue): a physical iPhone or iPad refuses shake and two-finger touches. Shake the device by hand, or open the menu from the app, then run this again: it uses a menu that is already open.",
                reason: .notSupported,
                hint: "offsider rn devmenu --device \(route.device.rawValue)"
            )
        }
        // A menu sliding in moves its items, so a tap waits for two reads that agree.
        let deadline = clock.now() + Self.openWait
        var seen: (DevMenu.State, UITree)?
        repeat {
            try await clock.sleep(Self.poll)
            let tree = try await read()
            let state = DevMenu.read(tree)
            if let state, state == seen?.0 { return (state, tree) }
            seen = state.map { ($0, tree) }
        } while clock.now() < deadline
        if let seen { return seen }
        let focused = route.device.platform == .android && tree.roots.contains { root in root.flattened().contains { $0.role.isTextInput && $0.state.focused == true } }
        let cause = focused
            ? "A text field has focus, and an Expo dev client then keeps the menu key from its menu: \(Self.focusAdvice) Otherwise check this is a debug build, as Release builds have none."
            : "Release builds have none; check this is a debug build."
        throw CLIError(
            errorDescription: "The React Native dev menu did not open on \(route.device.rawValue) within \(Int(Self.openWait)) s. \(cause)",
            reason: .stateNotReached,
            hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
        )
    }

    /// Without Android's Display over other apps, React Native opens that settings page instead of its performance monitor.
    func requireOverlayPermission() async throws {
        guard route.device.platform == .android,
              let reader = route.backend as? any OverlayPermissionReading,
              let foreground = route.backend as? any ForegroundReading,
              let top = try? await foreground.foreground(on: route.device).top,
              let package = top.split(separator: "/").first.map(String.init),
              (try? await reader.canDrawOverlays(package, on: route.device)) == false else { return }
        throw CLIError(
            errorDescription: "\(package) may not display over other apps, so its performance monitor would open Android's settings instead of showing. Offsider sent nothing. Ask the user to turn on Display over other apps for it (Settings > Apps > Special app access; Samsung calls it Appear on top), then run this again.",
            reason: .personRequired
        )
    }

    /// What to do when a focused text field keeps the menu key from Expo's menu.
    static let focusAdvice = "move focus out of the field, or open Expo's menu with its Tools button, then run this again (it uses a menu that is already open)."

    /// Taps the item, closes the menu if a switch left it open, and returns the label tapped once the menu is gone.
    @discardableResult
    func choose(_ item: DevMenu.Item?, label: String?, state: DevMenu.State, tree opened: UITree) async throws -> String {
        let android = route.device.platform == .android
        var tree = opened
        let unsure = DevMenu.unsureMatches(for: item, label: label, in: tree)
        if !unsure.isEmpty {
            await FrontJudge.read(unsure, in: &tree, backend: route.backend, device: route.device, everyPoint: true)
        }
        guard let (node, tapped) = DevMenu.match(for: item, label: label, in: tree), let frame = node.frame else {
            // React Native's own menu on Android is a dialog with no close control, which Back dismisses.
            if item == .close, android {
                try await perform(.shortButtonPress(.back))
                if try await closed(leaving: state.menu) { return "Back" }
                throw CLIError(errorDescription: "Pressed Back, but the \(state.menu) dev menu is still open.", reason: .notVerified, hint: "offsider describe-ui --summary --device \(route.device.rawValue)")
            }
            let name = label.map { "--label '\($0)'" } ?? item?.rawValue ?? "item"
            let advice = android && state.menu == "react-native"
                ? " If the app is an Expo dev client, the menu key can reach React Native's menu instead of Expo's while a text field has focus: \(Self.focusAdvice)" : ""
            throw CLIError(
                errorDescription: "The \(state.menu) dev menu has no \(name). Its items: \(state.items.map(\.label).joined(separator: ", ")).\(advice)",
                reason: .selectorNotFound,
                hint: "offsider rn devmenu --device \(route.device.rawValue)",
                candidates: state.items.map { entry in FailureCandidate(id: nil, label: entry.label, role: entry.role.rawValue, frame: entry.frame, onScreen: tree.viewport.flatMap { entry.frame?.isVisible(in: $0) }) }
            )
        }
        let point = try visiblePoint(of: node, frame: frame, label: tapped, menu: state.menu, in: tree)
        try await tap(point, tree: tree, hold: node.role == .switch)
        if try await closed(leaving: state.menu) { return tapped }
        // A switch or label can leave the menu open, and a Close tapped while the menu still presents can be ignored.
        if item?.isToggle == true || label != nil || item == .close {
            let fresh = try await read()
            // Closing the menu now would pass for a choice. The items it lists are real, though React Native draws them as plain text.
            if label != nil, !state.items.contains(where: { $0.label == tapped }), DevMenu.pressesNothing(node, at: point, in: tree), DevMenu.read(fresh) == state {
                throw CLIError(
                    errorDescription: "Tapped \(TerminalText.quoted(tapped)), but nothing happened: it is not a control in the \(state.menu) dev menu, which is still open. Its items: \(state.items.map(\.label).joined(separator: ", ")).",
                    reason: .notVerified,
                    hint: "offsider rn devmenu --device \(route.device.rawValue)"
                )
            }
            if let close = DevMenu.node(for: .close, label: nil, in: fresh), let closeFrame = close.frame {
                try await tap(closeFrame.center, tree: nil)
                if try await closed(leaving: state.menu) { return tapped }
            } else if android, DevMenu.read(fresh)?.menu == state.menu {
                try await perform(.shortButtonPress(.back))
                if try await closed(leaving: state.menu) { return tapped }
            }
        }
        throw CLIError(
            errorDescription: "Tapped \(node.label.map { TerminalText.quoted($0) } ?? item?.rawValue ?? "the item"), but the dev menu is still open.",
            reason: .notVerified,
            hint: "offsider describe-ui --summary --device \(route.device.rawValue)"
        )
    }

    /// Where the item shows, as `tap` finds it; past the screen or the menu's scroll view a tap lands nowhere and the Close fallback would pass for a choice.
    private func visiblePoint(of node: UINode, frame: UIFrame, label: String, menu: String, in tree: UITree) throws -> UIPoint {
        guard let viewport = tree.viewport else { return frame.center }
        do {
            let point = try AccessibilityTargetResolver.visiblePoint(
                (x: frame.center.x, y: frame.center.y), of: node, frame: frame, viewport: viewport, roots: tree.roots, selector: label
            )
            return UIPoint(x: point.x, y: point.y)
        } catch let error as ElementResolutionError where error.isOffScreen {
            let band = Self.scrollBand(for: error, of: node, in: tree.roots, viewport: viewport)
            let below = frame.center.y >= band.center.y
            let swipe = Self.scrollSwipe(up: below, in: band)
            let place = below ? "below the fold of" : "above the top of"
            throw CLIError(
                errorDescription: "\(TerminalText.quoted(label)) is off screen, \(place) the \(menu) dev menu, so nothing was tapped. Swipe the menu \(below ? "up" : "down") until it shows, then choose it again with `rn devmenu`, which uses the menu that is already open.",
                reason: .targetOffScreen,
                hint: "offsider swipe --start-x \(swipe.x) --start-y \(swipe.from) --end-x \(swipe.x) --end-y \(swipe.to) --device \(route.device.rawValue)",
                candidates: [FailureCandidate(id: node.id, label: label, role: node.role.rawValue, frame: frame, onScreen: false)]
            )
        }
    }

    /// What the screen shows of the scroll view or list that hides `node`, else the screen when under a quarter of it shows, too little to swipe in.
    private static func scrollBand(for error: ElementResolutionError, of node: UINode, in roots: [UINode], viewport: UIFrame) -> UIFrame {
        let shown: UIFrame?
        if case .beyondScrollView(_, _, let visible, _) = error {
            shown = visible
        } else {
            let scroller = AccessibilityTargetResolver.ancestorsOf(node, in: roots).last { [.scrollView, .list].contains($0.role) && $0.hasPositiveFrame }
            shown = scroller?.frame?.intersection(viewport)
        }
        guard let shown, shown.height >= viewport.height / 4 else { return viewport }
        return shown
    }

    /// A vertical swipe over 70% of `band`'s height, a quarter in from its left edge, clear of the switches on the right.
    private static func scrollSwipe(up: Bool, in band: UIFrame) -> (x: Int, from: Int, to: Int) {
        let low = Int((band.y + band.height * 0.85).rounded()), high = Int((band.y + band.height * 0.15).rounded())
        return (Int((band.x + band.width / 4).rounded()), up ? low : high, up ? high : low)
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

    /// A switch in the iOS Expo menu ignores a quick tap, so it gets a held touch.
    private func tap(_ point: UIPoint, tree: UITree?, hold: Bool = false) async throws {
        let physical = try await route.backend.deviceCoordinates(for: [(x: point.x, y: point.y)], tree: tree, on: route.device)[0]
        guard hold else {
            try await perform(.tapAt(x: physical.x, y: physical.y))
            return
        }
        defer { DeviceActivityLedger.current.recordInput(on: route.device) }
        try await DispatchTracker.current.sending {
            try await route.backend.sendDetachedTouch([.down(x: physical.x, y: physical.y), .hold(Self.switchHold), .up(x: physical.x, y: physical.y)], to: route.device)
        }
    }

    private func perform(_ event: InputEvent) async throws {
        if let send {
            try await send(event)
        } else {
            try await route.backend.performTracked(event, on: route.device)
        }
    }
}

struct RNDevMenu: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devmenu",
        abstract: "Open a React Native debug build's dev menu, list its items, or choose one.",
        discussion: """
        Opens the Expo dev menu (or React Native's) by shake on an iOS simulator and the menu key \
        (KEYCODE_MENU, as `button menu` sends it) on Android emulators and phones. \
        Without an item it prints the items, marking custom those the app registered, and leaves the menu open. With one (reload, home, inspector, \
        perf-monitor, fast-refresh, debugger, close) or --label, it taps it and waits until the menu closes, \
        closing it after a switch. React Native's own menu on Android has no close control, so there `close` \
        presses Back and checks the menu went. Exits 2 when the menu has no such item, as for a label only the app behind it shows \
        (the items are the candidates), or the item is off screen (nothing is tapped; the hint is the swipe that scrolls the menu to it), 1 when \
        the menu never opens (a Release build has none) and 5 when it stays open, as after a --label on something that is no control, such as a \
        section heading. On Android, `perf-monitor` first \
        checks the app may display over other apps and exits 1 with `person_required` when it may not. On Android an Expo dev client \
        keeps the menu key from its menu while a text field has focus, and the error then says so: move focus \
        out of the field, or open Expo's menu with its Tools button, then run this again. In batch, `rn devmenu` is \
        an input step that needs an item or --label.

        Examples:
          offsider rn devmenu --device DEVICE_ID
          offsider rn devmenu reload --device DEVICE_ID
          offsider batch --device DEVICE_ID --step "rn devmenu reload" --step "wait --id home-screen --timeout 20"
        """
    )

    @Argument(help: ArgumentHelp("The item to choose.", valueName: "reload|home|inspector|perf-monitor|fast-refresh|debugger|close"))
    var item: DevMenu.Item?

    @Option(help: ArgumentHelp("Choose the item with this exact label instead.", valueName: "text"))
    var label: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; after choosing an item, human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    /// The open menu when no item is asked for, else the item chosen from it.
    enum Outcome: Equatable {
        case listed(DevMenu.State)
        case chose(menu: String, item: DevMenu.Item?, label: String)

        func jsonLine() -> String {
            switch self {
            case .listed(let state): return DevMenu.jsonLine(state)
            case .chose(let menu, let item, let label): return DevMenu.choiceJSONLine(menu: menu, item: item, label: label)
            }
        }

        func textLine() -> String {
            switch self {
            case .listed(let state):
                let line = "\(state.menu) dev menu: " + state.items.filter { !$0.custom }.map(\.label).joined(separator: ", ")
                let custom = state.items.filter(\.custom).map(\.label)
                return custom.isEmpty ? line : line + "; custom: " + custom.joined(separator: ", ")
            case .chose(_, _, let label): return "✓ Chose \(label) and the dev menu closed"
            }
        }

        /// The items for a person, or a receipt for the one chosen; an agent's line as it was.
        var page: Page {
            switch self {
            case .listed(let state):
                return InputPersonView.devMenu(state, agent: textLine())
            case .chose(_, _, let label):
                return InputPersonView.receipt("Chose \(TerminalText.field(label, profile: .person))", details: ["The dev menu closed"], agent: textLine() + "\n")
            }
        }
    }

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
        await appOption.apply(to: route)
        let console = Console.current
        let choosing = item != nil || label != nil
        let outcome = try await console.progress(choosing ? "Choosing from the dev menu" : "Opening the dev menu") { try await perform(on: route, clock: .live) }
        guard json else { return console.show(outcome.page) }
        console.data(outcome.jsonLine() + "\n")
        if case .chose = outcome { console.data(outcome.textLine() + "\n", to: .err) }
    }

    @MainActor
    func perform(on route: DeviceRouter.Route, clock: PollClock, send: (@MainActor (InputEvent) async throws -> Void)? = nil) async throws -> Outcome {
        try await route.backend.prepare()
        let driver = DevMenuDriver(route: route, clock: clock, send: send)
        let perfMonitor = item == .perfMonitor || label.map { label in DevMenu.Item.perfMonitor.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } } == true
        let check: (() async throws -> Void)? = perfMonitor ? { try await driver.requireOverlayPermission() } : nil
        let (state, tree) = try await driver.open(check: check)
        guard item != nil || label != nil else { return .listed(state) }
        let tapped = try await driver.choose(item, label: label, state: state, tree: tree)
        return .chose(menu: state.menu, item: item, label: tapped)
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

    @OptionGroup
    var appOption: AppOption

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        await appOption.apply(to: route)
        let console = Console.current
        let (inspector, perf) = try await console.progress("Checking the dev tools") { try await turnOff(on: route, clock: .live) }
        guard !json else { return console.data(DevMenu.toolsJSONLine(inspector: inspector, perfMonitor: perf) + "\n") }
        console.show(Self.page(inspector: inspector, perfMonitor: perf))
    }

    /// `Dev tools off` for a person, naming what was turned off; an agent's `Element inspector: off; …` line as it was.
    static func page(inspector: String, perfMonitor: String) -> Page {
        let turned = [("element inspector", inspector), ("performance monitor", perfMonitor)].filter { $0.1 == "turned-off" }.map(\.0)
        let details = turned.isEmpty ? ["Neither the inspector nor the performance monitor was showing"] : ["Turned off the " + turned.joined(separator: " and the ")]
        return InputPersonView.receipt("Dev tools off", details: details, agent: "Element inspector: \(inspector); performance monitor: \(perfMonitor)\n")
    }

    @MainActor
    func turnOff(on route: DeviceRouter.Route, clock: PollClock) async throws -> (inspector: String, perfMonitor: String) {
        try await route.backend.prepare()
        let driver = DevMenuDriver(route: route, clock: clock)
        let tree: UITree
        do {
            tree = try await driver.read()
        } catch let error as IOSDeviceError where error.reason == .usage || error.reason == .appNotAllowed {
            throw error
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
