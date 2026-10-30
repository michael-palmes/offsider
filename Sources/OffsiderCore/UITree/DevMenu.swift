import Foundation

/// Optional capability: opening a React Native debug build's dev menu by shake on an iOS simulator; Android sends the menu key as input.
@MainActor
public protocol ReactNativeDevMenuOpening: DeviceBackend {
    func openDevMenu(_ id: DeviceID) async throws
}

/// The Expo dev menu and React Native's own, read from the tree by their item labels.
public enum DevMenu {
    public enum Item: String, CaseIterable, Sendable {
        case reload
        case home
        case inspector
        case perfMonitor = "perf-monitor"
        case fastRefresh = "fast-refresh"
        case debugger
        case close

        /// Labels the item has in the Expo dev menu and in React Native's, exact after trimming. On Android the Expo
        /// menu's buttons read "<icon> <label>", such as "Home Go home", so a button also matches on a trailing label.
        public var labels: [String] {
            switch self {
            case .reload: return ["Reload"]
            case .home: return ["Go home", "Go Home", "Go to home"]
            case .inspector: return ["Toggle element inspector", "Toggle Element Inspector", "Element inspector", "Show Element Inspector", "Hide Element Inspector", "Toggle Inspector"]
            case .perfMonitor: return ["Toggle performance monitor", "Performance monitor", "Show Perf Monitor", "Hide Perf Monitor", "Perf Monitor"]
            case .fastRefresh: return ["Fast refresh", "Fast Refresh", "Enable Fast Refresh", "Disable Fast Refresh"]
            case .debugger: return ["Open JS debugger", "Open DevTools", "Open React Native DevTools", "Open Debugger"]
            case .close: return ["Close", "Cancel", "Dismiss"]
            }
        }

        /// Items that switch something and may leave the menu open.
        public var isToggle: Bool {
            [.inspector, .perfMonitor, .fastRefresh].contains(self)
        }
    }

    public struct Entry: Equatable, Sendable {
        public var label: String
        public var role: UIRole
        public var frame: UIFrame?
        /// An item the app registered: with expo-dev-menu's `registerDevMenuItems`, or React Native's `DevSettings.addMenuItem`.
        public var custom = false
    }

    public struct State: Equatable, Sendable {
        /// `expo` when the menu has Expo's Go home, else `react-native`.
        public var menu: String
        public var items: [Entry]
    }

    /// The title React Native's own dev menu shows on Android, which has no close control.
    static let reactNativeTitle = "React Native Dev Menu"

    /// Items only a dev menu lists, unlike Reload and Close, which an app screen may have too.
    static let menuOnlyItems: [Item] = [.home, .inspector, .perfMonitor, .fastRefresh, .debugger]

    /// The heading the Expo menu draws above an app's `registerDevMenuItems` buttons, on iOS and Android.
    static let expoCustomHeading = "CUSTOM MENU ITEMS"

    /// React Native's last built-in row on Android: Settings, or Fast Refresh when its newer performance monitor drops Settings.
    static let reactNativeLastRows: Set<String> = ["Settings", "Enable Fast Refresh", "Disable Fast Refresh"]

    /// The open menu: Reload beside two menu-only items (Expo's custom heading counts, as app items can push the tools off screen) or under React Native's title.
    public static func read(_ tree: UITree) -> State? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let titled = nodes.contains { trimmedLabel($0) == reactNativeTitle }
        let hasReload = nodes.contains { matchedLabel($0, Item.reload.labels) != nil }
        let menuItems = menuOnlyItems.filter { item in nodes.contains { matchedLabel($0, item.labels) != nil } }
        let headed = nodes.contains(where: isCustomHeading)
        guard hasReload, titled || menuItems.count + (headed ? 1 : 0) >= 2 else { return nil }
        let hasHome = menuItems.contains(.home)
        let items = Item.allCases.compactMap { item -> (Int, Entry)? in
            guard let (index, node, text) = best(item.labels, in: nodes) else { return nil }
            return (index, Entry(label: text, role: node.role, frame: node.frame))
        }
        let custom = customItems(in: tree).map { ($0.index, Entry(label: $0.label, role: $0.node.role, frame: $0.node.frame, custom: true)) }
        return State(menu: hasHome ? "expo" : "react-native", items: (items + custom).sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// The node for `item`, or for an exact `label`; the close control also by its `xmark` id.
    public static func node(for item: Item?, label: String?, in tree: UITree) -> UINode? {
        match(for: item, label: label, in: tree)?.node
    }

    /// The node to tap for `item` or `label`, with the menu label it was found by; a label the app registered is the menu's, never a button behind it.
    /// A match from the menu's Reload on is the menu's or drawn over it. One listed earlier may be the app behind, so `tree.front`, when read, must say a touch reaches it.
    public static func match(for item: Item?, label: String?, in tree: UITree) -> (node: UINode, label: String)? {
        if let label, let custom = customItems(in: tree).first(where: { $0.label == label && $0.node.frame != nil }) {
            return (custom.node, custom.label)
        }
        let flat = tree.roots.flatMap { $0.flattened() }
        if item == .close, let xmark = flat.last(where: { $0.id == "xmark" && $0.frame != nil }) {
            return (xmark, trimmedLabel(xmark) ?? "Close")
        }
        let wanted = label.map { [$0] } ?? item?.labels ?? []
        let start = menuStart(in: flat)
        let own = flat[start...].filter { $0.frame != nil }
        if let (_, match, text) = best(wanted, in: own) {
            if match.role.isActionable || match.role == .switch { return (match, text) }
            return (rowSwitch(beside: match, in: own) ?? match, text)
        }
        let earlier = flat[..<start].indices.filter { flat[$0].frame != nil && tree.front?.misses(at: $0) != true }.map { flat[$0] }
        let matches = earlier.compactMap { node in matchedLabel(node, wanted).map { (node, $0) } }
        return (matches.last { $0.0.role.isActionable } ?? matches.last).map { (node: $0.0, label: $0.1) }
    }

    /// The pre-order indexes `match` needs the front's word on: `item` or `label`'s matches, when all of them are listed before the menu.
    public static func unsureMatches(for item: Item?, label: String?, in tree: UITree) -> [Int] {
        if let label, customItems(in: tree).contains(where: { $0.label == label }) { return [] }
        let flat = tree.roots.flatMap { $0.flattened() }
        if item == .close, flat.contains(where: { $0.id == "xmark" }) { return [] }
        let wanted = label.map { [$0] } ?? item?.labels ?? []
        let start = menuStart(in: flat)
        guard !flat[start...].contains(where: { matchedLabel($0, wanted) != nil }) else { return [] }
        return flat[..<start].indices.filter { matchedLabel(flat[$0], wanted) != nil }
    }

    /// True when a tap on `node` at `point` presses nothing: it is no control, and none of the menu's lies under the point.
    public static func pressesNothing(_ node: UINode, at point: UIPoint, in tree: UITree) -> Bool {
        guard !node.isActionable else { return false }
        let flat = tree.roots.flatMap { $0.flattened() }
        return !flat[menuStart(in: flat)...].contains { $0.isActionable && $0.frame?.contains(point) == true }
    }

    /// Where the menu begins in pre-order: its Reload, listed after any an app behind it has, since the menu is drawn over the app. The button is taken over the text inside it.
    private static func menuStart(in flat: [UINode]) -> Int {
        let reloads = flat.indices.filter { matchedLabel(flat[$0], Item.reload.labels) != nil }
        guard let last = reloads.last else { return 0 }
        return reloads.first { flat[$0].role.isActionable && flat[$0].flattened().contains { $0.isSameElement(as: flat[last]) } } ?? last
    }

    /// The first actionable node carrying one of `labels`, else the first node at all, with its pre-order index and the label it matched.
    private static func best(_ labels: [String], in nodes: [UINode]) -> (index: Int, node: UINode, label: String)? {
        let matches = nodes.enumerated().compactMap { index, node in matchedLabel(node, labels).map { (index, node, $0) } }
        return matches.first { $0.1.role.isActionable || $0.1.role == .switch } ?? matches.first
    }

    /// The label of `labels` the node shows: its whole label, or for a button the end of "<icon> <label>".
    static func matchedLabel(_ node: UINode, _ labels: [String]) -> String? {
        guard let text = trimmedLabel(node) else { return nil }
        if let exact = labels.first(where: { $0 == text }) { return exact }
        guard node.role.isActionable else { return nil }
        return labels.first { text.hasSuffix(" " + $0) }
    }

    private static func trimmedLabel(_ node: UINode) -> String? {
        node.label?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The innermost unlabelled switch on a text label's row, as the Expo menu draws Fast refresh.
    private static func rowSwitch(beside label: UINode, in nodes: [UINode]) -> UINode? {
        guard let text = label.frame else { return nil }
        let midY = text.y + text.height / 2
        return nodes
            .filter { node in
                guard node.role == .switch, let frame = node.frame else { return false }
                return frame.y <= midY && midY <= frame.y + frame.height && frame.x >= text.x + text.width
            }
            .min { ($0.frame?.width ?? 0) * ($0.frame?.height ?? 0) < ($1.frame?.width ?? 0) * ($1.frame?.height ?? 0) }
    }

    /// The items an app registered, with their pre-order indices: Expo's buttons under its custom heading, or the rows React Native's Android menu appends.
    static func customItems(in tree: UITree) -> [(index: Int, node: UINode, label: String)] {
        let nodes = tree.roots.flatMap { $0.flattened() }
        var ends: [Int] = []
        func visit(_ node: UINode) {
            let index = ends.count
            ends.append(index + 1)
            node.children.forEach(visit)
            ends[index] = ends.count
        }
        tree.roots.forEach(visit)
        return expoCustomItems(nodes, ends: ends) + reactNativeCustomItems(nodes, ends: ends)
    }

    /// The buttons after Expo's custom heading, up to the next section's heading (TOOLS) or the end of the heading's container; a button's own texts are skipped.
    private static func expoCustomItems(_ nodes: [UINode], ends: [Int]) -> [(index: Int, node: UINode, label: String)] {
        guard let heading = nodes.firstIndex(where: isCustomHeading) else { return [] }
        let sectionEnd = (0..<heading).last { ends[$0] > heading }.map { ends[$0] } ?? nodes.count
        var found: [(index: Int, node: UINode, label: String)] = []
        var index = heading + 1
        while index < sectionEnd, !isSectionHeading(nodes[index]) {
            if nodes[index].role.isActionable, let label = trimmedLabel(nodes[index]), !label.isEmpty {
                found.append((index, nodes[index], label))
                index = ends[index]
            } else {
                index += 1
            }
        }
        return found
    }

    private static func isCustomHeading(_ node: UINode) -> Bool {
        !node.role.isActionable && trimmedLabel(node)?.uppercased() == expoCustomHeading
    }

    /// An Expo section heading, which the menu draws in capitals on both platforms.
    private static func isSectionHeading(_ node: UINode) -> Bool {
        guard !node.role.isActionable, let text = trimmedLabel(node) else { return false }
        return text == text.uppercased() && text != text.lowercased()
    }

    /// The rows after React Native's last built-in row in the list holding its Reload, where `DevSettings.addMenuItem` puts them.
    private static func reactNativeCustomItems(_ nodes: [UINode], ends: [Int]) -> [(index: Int, node: UINode, label: String)] {
        guard let title = nodes.firstIndex(where: { trimmedLabel($0) == reactNativeTitle }),
              let reload = nodes.indices.first(where: { $0 > title && matchedLabel(nodes[$0], Item.reload.labels) != nil }),
              let list = (0..<reload).last(where: { ends[$0] > reload }),
              let last = (reload..<ends[list]).last(where: { trimmedLabel(nodes[$0]).map { reactNativeLastRows.contains($0) } == true }) else { return [] }
        var found: [(index: Int, node: UINode, label: String)] = []
        var row = ends[last]
        while row < ends[list] {
            if let label = trimmedLabel(nodes[row]), !label.isEmpty { found.append((row, nodes[row], label)) }
            row = ends[row]
        }
        return found
    }

    /// Which developer tools show: the element inspector's panel (its Inspect and Touchables tabs) and the performance monitor (`UI` and `JS` frame rates, which iOS draws as a `RAM` cell beside `UI` and `JS` columns).
    public static func tools(in tree: UITree) -> (inspector: Bool, perfMonitor: Bool) {
        let texts = tree.roots.flatMap { $0.flattened() }.flatMap { [$0.label, $0.value] }.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let inspector = texts.contains("Inspect") && texts.contains("Touchables")
        let fps = texts.contains { $0.range(of: #"^(UI|JS)[: ]+[0-9.]+ ?fps"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let columns = texts.contains("UI") && texts.contains("JS") && texts.contains { $0.range(of: #"^RAM [0-9.]+ ?MB$"#, options: .regularExpression) != nil }
        return (inspector, fps || columns)
    }

    public static func jsonLine(_ state: State) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("menu", .string(state.menu)),
            ("items", .array(state.items.map { entry in
                .object([("label", .string(entry.label)), ("role", .string(entry.role.rawValue))] + (entry.custom ? [("custom", .bool(true))] : []))
            })),
        ]).rendered(compact: true)
    }

    /// `rn devmenu <item> --json`: the menu that was open, the item asked for (null for `--label`) and the label tapped.
    public static func choiceJSONLine(menu: String, item: Item?, label: String) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("menu", .string(menu)),
            ("item", item.map { .string($0.rawValue) } ?? .null),
            ("label", .string(label)),
            ("closed", .bool(true)),
        ]).rendered(compact: true)
    }

    public static func toolsJSONLine(inspector: String, perfMonitor: String) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("inspector", .string(inspector)),
            ("perfMonitor", .string(perfMonitor)),
        ]).rendered(compact: true)
    }
}
